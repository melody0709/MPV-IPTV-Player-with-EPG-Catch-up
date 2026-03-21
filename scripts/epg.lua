--[[
    mpv + uosc 5.12 IPTV 脚本 V1.4
  重构：三级滑动菜单结构 - 分组 > 频道 > EPG回看
]]

local mp = require 'mp'
local utils = require 'mp.utils'
local opt = require 'mp.options'

local options = {
    epg_download_url = "",
    epg_cache_refresh_start = "00:04",
    epg_cache_refresh_interval_hours = 7
}
opt.read_options(options)

local state = {
    m3u_path = "",
    epg_url = "",
    groups = {},
    group_names = {},
    epg_data = {},
    is_loaded = false,
    current_channel = nil,
    history_file = "epg_history.json",
    channel_history = {},
    auto_playing = false,  -- 标记是否正在自动播放历史频道
    -- 当前回看上下文（用于续播）
    -- 结构: {live_url, catchup_template, start_utc, last_end_utc, retry_count}
    current_catchup = nil,
    catchup_timer = nil   -- 预判续播定时器
}

local build_main_menu
local build_channel_epg_items
local channel_search_romanization = nil
local channel_search_cache = {}

-- ==================== 工具函数（保持原样） ====================

-- 去除字符串前后空白字符
local function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$")
end

local function utf8_char_bytes(str, index)
    local char_byte = str:byte(index)
    local max_bytes = #str - index + 1
    if char_byte < 0xC0 then
        return math.min(max_bytes, 1)
    elseif char_byte < 0xE0 then
        return math.min(max_bytes, 2)
    elseif char_byte < 0xF0 then
        return math.min(max_bytes, 3)
    elseif char_byte < 0xF8 then
        return math.min(max_bytes, 4)
    end
    return math.min(max_bytes, 1)
end

local function utf8_iter(str)
    local byte_start = 1
    return function()
        local start_index = byte_start
        if #str < start_index then return nil end
        local byte_count = utf8_char_bytes(str, start_index)
        byte_start = start_index + byte_count
        return start_index, str:sub(start_index, start_index + byte_count - 1)
    end
end

local function load_channel_search_romanization()
    if channel_search_romanization ~= nil then
        return channel_search_romanization or nil
    end

    local char_conv_path = mp.command_native({"expand-path", "~~home/scripts/uosc/char-conv/zh.json"})
    if not char_conv_path or char_conv_path == "" then
        channel_search_romanization = false
        return nil
    end

    local file = io.open(char_conv_path, "r")
    if not file then
        channel_search_romanization = false
        return nil
    end

    local json_content = file:read("*a")
    file:close()

    local success, data = pcall(utils.parse_json, json_content)
    if not success or type(data) ~= "table" then
        channel_search_romanization = false
        return nil
    end

    local romanization = {}
    for roman, chars in pairs(data) do
        for _, char in utf8_iter(chars) do
            romanization[char] = roman
        end
    end

    channel_search_romanization = romanization
    return channel_search_romanization
end

local function build_channel_search_terms(name)
    if channel_search_cache[name] then
        return channel_search_cache[name]
    end

    local normalized_name = (name or ""):lower()
    local romanization = load_channel_search_romanization()
    local cjk_units = {}
    local ascii_buffer = {}
    local full_sequences = {
        forward = {},
        backward = {},
    }
    local initial_sequences = {
        forward = {},
        backward = {},
    }

    local function append_ascii_token()
        if #ascii_buffer == 0 then return end
        local token = table.concat(ascii_buffer)
        full_sequences.forward[#full_sequences.forward + 1] = token
        full_sequences.backward[#full_sequences.backward + 1] = token
        initial_sequences.forward[#initial_sequences.forward + 1] = token
        initial_sequences.backward[#initial_sequences.backward + 1] = token
        ascii_buffer = {}
    end

    local function append_cjk_tokens(units)
        if #units == 0 then return end

        local function append_grouped_tokens(target_full, target_initials, reverse)
            local start_index = reverse and #units or 1
            local step = reverse and -2 or 2

            while reverse and start_index > 0 or (not reverse and start_index <= #units) do
                local end_index
                if reverse then
                    end_index = start_index
                    start_index = math.max(1, start_index - 1)
                else
                    end_index = math.min(#units, start_index + 1)
                end

                local group_start = reverse and start_index or (end_index - ((end_index - start_index >= 1) and 1 or 0))
                if reverse then
                    group_start = start_index
                else
                    group_start = end_index - ((end_index - start_index >= 1) and 1 or 0)
                end

                local roman_parts = {}
                local initial_parts = {}
                for idx = group_start, end_index do
                    local syllable = units[idx]
                    roman_parts[#roman_parts + 1] = syllable
                    initial_parts[#initial_parts + 1] = syllable:sub(1, 1)
                end
                table.insert(target_full, 1, table.concat(roman_parts))
                table.insert(target_initials, 1, table.concat(initial_parts))

                if reverse then
                    start_index = start_index - 2
                else
                    start_index = start_index + 2
                end
            end
        end

        local forward_full = {}
        local forward_initials = {}
        local index = 1
        while index <= #units do
            local end_index = math.min(#units, index + 1)
            local roman_parts = {}
            local initial_parts = {}
            for idx = index, end_index do
                roman_parts[#roman_parts + 1] = units[idx]
                initial_parts[#initial_parts + 1] = units[idx]:sub(1, 1)
            end
            forward_full[#forward_full + 1] = table.concat(roman_parts)
            forward_initials[#forward_initials + 1] = table.concat(initial_parts)
            index = index + 2
        end

        local backward_full = {}
        local backward_initials = {}
        local reverse_groups = {}
        local reverse_initials_groups = {}
        local reverse_index = #units
        while reverse_index >= 1 do
            local start_index = math.max(1, reverse_index - 1)
            local roman_parts = {}
            local initial_parts = {}
            for idx = start_index, reverse_index do
                roman_parts[#roman_parts + 1] = units[idx]
                initial_parts[#initial_parts + 1] = units[idx]:sub(1, 1)
            end
            table.insert(reverse_groups, 1, table.concat(roman_parts))
            table.insert(reverse_initials_groups, 1, table.concat(initial_parts))
            reverse_index = start_index - 1
        end
        backward_full = reverse_groups
        backward_initials = reverse_initials_groups

        for _, token in ipairs(forward_full) do
            full_sequences.forward[#full_sequences.forward + 1] = token
        end
        for _, token in ipairs(forward_initials) do
            initial_sequences.forward[#initial_sequences.forward + 1] = token
        end
        for _, token in ipairs(backward_full) do
            full_sequences.backward[#full_sequences.backward + 1] = token
        end
        for _, token in ipairs(backward_initials) do
            initial_sequences.backward[#initial_sequences.backward + 1] = token
        end
    end

    local function flush_buffers()
        append_ascii_token()
        if #cjk_units > 0 then
            append_cjk_tokens(cjk_units)
            cjk_units = {}
        end
    end

    for _, char in utf8_iter(normalized_name) do
        local mapped = romanization and romanization[char] or nil
        if mapped then
            append_ascii_token()
            cjk_units[#cjk_units + 1] = mapped:lower()
        elseif char:match("[a-z0-9]") then
            if #cjk_units > 0 then
                append_cjk_tokens(cjk_units)
                cjk_units = {}
            end
            ascii_buffer[#ascii_buffer + 1] = char
        else
            flush_buffers()
        end
    end
    flush_buffers()

    local search_terms = {
        name = normalized_name,
        full_sequences = {full_sequences.forward, full_sequences.backward},
        initial_sequences = {initial_sequences.forward, initial_sequences.backward},
    }
    channel_search_cache[name] = search_terms
    return search_terms
end

local function token_sequences_match_query(token_sequences, query)
    if not token_sequences then
        return false
    end

    for _, token_sequence in ipairs(token_sequences) do
        if token_sequence and #token_sequence > 0 then
            for start_index = 1, #token_sequence do
                local candidate = table.concat(token_sequence, "", start_index)
                if candidate:find(query, 1, true) == 1 then
                    return true
                end
            end
        end
    end

    return false
end

local function channel_name_matches_query(name, query)
    local normalized_query = trim(query or ""):lower()
    if normalized_query == "" then
        return false
    end

    local search_terms = build_channel_search_terms(name)
    if search_terms.name:find(normalized_query, 1, true) then
        return true
    end
    if token_sequences_match_query(search_terms.full_sequences, normalized_query) then
        return true
    end
    if token_sequences_match_query(search_terms.initial_sequences, normalized_query) then
        return true
    end
    return false
end

-- ==================== EPG 缓存相关函数 ====================

-- 获取缓存目录路径
local function get_cache_dir()
    local success, expanded_path = pcall(function()
        return mp.command_native({"expand-path", "~~home/cache/"})
    end)
    if success and expanded_path and expanded_path ~= "" and expanded_path ~= "~~home/cache/" then
        return expanded_path:gsub("[\\/]+$", "")
    end
    -- 备选：使用 Windows 临时目录
    local is_windows = package.config:sub(1,1) == '\\'
    if is_windows then
        local temp_dir = os.getenv("TEMP") or os.getenv("TMP")
        if temp_dir then
            return temp_dir
        end
    end
    return nil
end

-- 简单字符串哈希函数（djb2算法 - Lua 5.1 兼容版）
local function simple_hash(str)
    local hash = 5381
    for i = 1, #str do
        -- 使用乘法代替位运算: hash << 5 等价于 hash * 32
        hash = (hash * 32 + hash) + str:byte(i)
        -- 限制为32位整数（模拟 & 0xFFFFFFFF）
        hash = hash % 4294967296
    end
    -- 转为16进制字符串
    return string.format("%08x", hash)
end

-- 获取 EPG 缓存文件路径
local function get_epg_cache_path()
    if state.epg_url == "" then return nil end
    local cache_dir = get_cache_dir()
    if not cache_dir then return nil end
    local url_hash = simple_hash(state.epg_url)
    return utils.join_path(cache_dir, "epg_" .. url_hash .. ".xml")
end

local function get_legacy_cycle_start()
    local now = os.time()
    local now_table = os.date("*t", now)
    local current_minutes = now_table.hour * 60 + now_table.min
    
    -- 周期起始时间（分钟）：00:02=2, 07:02=422, 14:02=842, 21:02=1262
    local cycle_starts = {2, 422, 842, 1262}
    local cycle_start_hour = {0, 7, 14, 21}
    
    -- 找到当前所在的周期
    local current_cycle_idx = 1
    for i = 2, #cycle_starts do
        if current_minutes >= cycle_starts[i] then
            current_cycle_idx = i
        else
            break
        end
    end
    
    -- 构建当前周期起始时间
    local start_table = {
        year = now_table.year,
        month = now_table.month,
        day = now_table.day,
        hour = cycle_start_hour[current_cycle_idx],
        min = 2,
        sec = 0
    }
    
    return os.time(start_table)
end

local function parse_refresh_time(value)
    local hour_str, minute_str = tostring(value or ""):match("^(%d%d?):(%d%d)$")
    if not hour_str or not minute_str then
        return nil
    end

    local hour = tonumber(hour_str)
    local minute = tonumber(minute_str)
    if not hour or not minute or hour < 0 or hour > 23 or minute < 0 or minute > 59 then
        return nil
    end

    return hour, minute
end

local function get_configured_refresh_schedule()
    local start_hour, start_minute = parse_refresh_time(options.epg_cache_refresh_start)
    local interval_hours = tonumber(options.epg_cache_refresh_interval_hours)
    if not start_hour or not interval_hours or interval_hours <= 0 or interval_hours >= 24 then
        return nil
    end

    interval_hours = math.floor(interval_hours)
    local refresh_minutes = {}
    local current_minutes = start_hour * 60 + start_minute
    while current_minutes < 24 * 60 do
        refresh_minutes[#refresh_minutes + 1] = current_minutes
        current_minutes = current_minutes + interval_hours * 60
    end

    if #refresh_minutes == 0 then
        return nil
    end

    return {
        start_hour = start_hour,
        start_minute = start_minute,
        interval_hours = interval_hours,
        refresh_minutes = refresh_minutes,
    }
end

local function get_current_cycle_refresh_time(schedule)
    if not schedule then
        return nil
    end

    local now = os.time()
    local now_table = os.date("*t", now)
    local current_minutes = now_table.hour * 60 + now_table.min
    local selected_minutes = schedule.refresh_minutes[1]
    local use_previous_day = current_minutes < selected_minutes

    if not use_previous_day then
        for i = 2, #schedule.refresh_minutes do
            if current_minutes >= schedule.refresh_minutes[i] then
                selected_minutes = schedule.refresh_minutes[i]
            else
                break
            end
        end
    else
        selected_minutes = schedule.refresh_minutes[#schedule.refresh_minutes]
    end

    local refresh_table = {
        year = now_table.year,
        month = now_table.month,
        day = now_table.day,
        hour = math.floor(selected_minutes / 60),
        min = selected_minutes % 60,
        sec = 0,
    }

    local refresh_time = os.time(refresh_table)
    if use_previous_day then
        refresh_time = refresh_time - 24 * 60 * 60
    end

    return refresh_time, selected_minutes
end

local function is_cache_valid(cache_path)
    local file = io.open(cache_path, "r")
    if not file then
        mp.msg.info("缓存文件不存在: " .. cache_path)
        return false
    end
    file:close()
    
    -- 获取文件修改时间
    local file_info = utils.file_info(cache_path)
    if not file_info or not file_info.mtime then
        mp.msg.info("无法获取缓存文件信息: " .. cache_path)
        return false
    end
    
    local cache_mtime = file_info.mtime
    local now = os.time()

    local valid_after
    local schedule = get_configured_refresh_schedule()
    if schedule then
        valid_after = get_current_cycle_refresh_time(schedule)
        mp.msg.verbose(string.format("缓存时间检查(配置): 缓存修改=%s, 当前周期刷新点=%s, 当前=%s, 配置=%s / %d小时",
            os.date("%Y-%m-%d %H:%M:%S", cache_mtime),
            os.date("%Y-%m-%d %H:%M:%S", valid_after),
            os.date("%Y-%m-%d %H:%M:%S", now),
            options.epg_cache_refresh_start,
            schedule.interval_hours))
    else
        local cycle_start = get_legacy_cycle_start()
        valid_after = cycle_start + 120
        mp.msg.warn("EPG 刷新配置无效，已回退到旧的固定时段规则")
        mp.msg.verbose(string.format("缓存时间检查(旧规则): 缓存修改=%s, 周期起始=%s, 有效时间=%s, 当前=%s",
            os.date("%Y-%m-%d %H:%M:%S", cache_mtime),
            os.date("%Y-%m-%d %H:%M:%S", cycle_start),
            os.date("%Y-%m-%d %H:%M:%S", valid_after),
            os.date("%Y-%m-%d %H:%M:%S", now)))
    end

    if cache_mtime >= valid_after then
        mp.msg.info("缓存有效: 修改时间 " .. os.date("%H:%M:%S", cache_mtime) .. 
                    " 晚于当前周期有效时间 " .. os.date("%H:%M:%S", valid_after))
        return true
    else
        mp.msg.info("缓存过期: 修改时间 " .. os.date("%H:%M:%S", cache_mtime) .. 
                    " 早于当前周期有效时间 " .. os.date("%H:%M:%S", valid_after))
        return false
    end
end

-- 保存 EPG 数据到缓存
local function save_epg_cache(cache_path, data)
    if not cache_path or not data then return end
    local file, err = io.open(cache_path, "wb")
    if file then
        file:write(data)
        file:close()
        mp.msg.info("EPG 缓存已保存: " .. cache_path .. " (" .. #data .. " 字节)")
    else
        mp.msg.warn("无法保存 EPG 缓存: " .. tostring(err))
    end
end

-- 获取历史记录文件路径
-- 使用 mpv 配置目录下的 cache 子目录，如果不存在则使用 Windows 临时目录
local function get_history_file_path()
    -- 使用 expand-path 命令获取 ~~home/cache/ (mpv 配置目录下的 cache)
    local success, expanded_path = pcall(function()
        return mp.command_native({"expand-path", "~~home/cache/"})
    end)
    if success and expanded_path and expanded_path ~= "" and expanded_path ~= "~~home/cache/" then
        local cache_dir = expanded_path:gsub("[\\/]+$", "")
        local history_path = utils.join_path(cache_dir, state.history_file)
        mp.msg.info("历史记录路径: " .. history_path)
        return history_path
    end

    -- 备选：使用 Windows 临时目录
    local is_windows = package.config:sub(1,1) == '\\'
    if is_windows then
        local temp_dir = os.getenv("TEMP") or os.getenv("TMP")
        if temp_dir then
            local history_path = utils.join_path(temp_dir, "mpv_epg_" .. state.history_file)
            mp.msg.info("历史记录路径 (临时目录): " .. history_path)
            return history_path
        end
    end

    -- 最终备选：当前工作目录
    mp.msg.warn("无法确定合适的目录，使用当前目录")
    return state.history_file
end

-- 读取频道历史记录
local function load_channel_history()
    local history_path = get_history_file_path()
    mp.msg.info("尝试加载历史记录文件: " .. history_path)

    local dir = history_path:match("^(.*)[\\/]")
    if dir then
        mp.msg.info("目标目录: " .. dir)
    end

    local file = io.open(history_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        mp.msg.info("历史记录文件大小: " .. #content .. " 字节")
        local success, data = pcall(utils.parse_json, content)
        if success and type(data) == "table" then
            state.channel_history = data
            local count = 0
            for k, v in pairs(data) do count = count + 1 end
            mp.msg.info("频道历史记录已加载，共 " .. count .. " 个 m3u 文件的记录")
        else
            mp.msg.warn("频道历史记录文件格式错误: " .. tostring(data))
            state.channel_history = {}
        end
    else
        state.channel_history = {}
        mp.msg.info("未找到历史记录文件，将创建新文件: " .. history_path)
    end
end

-- 保存频道历史记录
local function save_channel_history()
    local history_path = get_history_file_path()
    mp.msg.info("尝试保存历史记录到: " .. history_path)

    local file, err = io.open(history_path, "w")
    if file then
        local content = utils.format_json(state.channel_history)
        file:write(content)
        file:close()
        mp.msg.info("频道历史记录已保存成功: " .. history_path)
    else
        mp.msg.error("无法保存频道历史记录: " .. tostring(err))
        mp.msg.error("目标路径: " .. history_path)
    end
end

-- 获取 m3u 文件的唯一标识（使用文件路径的哈希）
local function get_m3u_key(m3u_path)
    -- 使用文件路径作为键，规范化路径格式
    local normalized_path = m3u_path:gsub("\\", "/"):gsub("^file://", "")
    return normalized_path
end

-- 保存当前播放的频道到历史记录
local function save_current_channel_to_history()
    if not state.m3u_path or state.m3u_path == "" then return end
    if not state.current_channel or not state.current_channel.url then return end

    local m3u_key = get_m3u_key(state.m3u_path)
    state.channel_history[m3u_key] = {
        url = state.current_channel.url,
        name = state.current_channel.name,
        group = state.current_channel.group,
        timestamp = os.time()
    }
    save_channel_history()
    mp.msg.info("已保存频道到历史记录: " .. state.current_channel.name)
end

-- 从历史记录加载上次播放的频道
local function load_last_channel_from_history()
    if not state.m3u_path or state.m3u_path == "" then return nil end

    local m3u_key = get_m3u_key(state.m3u_path)
    local history = state.channel_history[m3u_key]

    if history and history.url then
        mp.msg.info("从历史记录加载频道: " .. (history.name or "未知"))
        return history
    end

    return nil
end

local function xmltv_to_utc(time_str)
    local y, m, d, h, min, s, sign, offset_h, offset_m = time_str:match("^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d) ([%+%-])(%d%d)(%d%d)")
    if not y then return "" end
    local t = os.time{year=y, month=m, day=d, hour=h, min=min, sec=s}
    local now = os.time()
    local local_offset = os.difftime(os.time(os.date("*t", now)), os.time(os.date("!*t", now)))
    t = t + local_offset 
    local xml_offset = (tonumber(offset_h) * 3600) + (tonumber(offset_m) * 60)
    if sign == "+" then t = t - xml_offset else t = t + xml_offset end
    return os.date("!%Y%m%d%H%M%S", t)
end

local function current_utc_string()
    return os.date("!%Y%m%d%H%M%S")
end

-- 【修改】回看节目延迟 2 分钟才标记为可回看，避免节目刚开播时立即进入导致闪退
local function catchup_ready_utc_string()
    return os.date("!%Y%m%d%H%M%S", os.time() - 120)
end

-- 将 YYYYMMDDHHmmss UTC字符串转为 Unix 时间戳
local function utc_str_to_timestamp(s)
    if not s or #s < 14 then return nil end
    local y  = tonumber(s:sub(1,4))
    local mo = tonumber(s:sub(5,6))
    local d  = tonumber(s:sub(7,8))
    local h  = tonumber(s:sub(9,10))
    local mi = tonumber(s:sub(11,12))
    local sc = tonumber(s:sub(13,14))
    if not (y and mo and d and h and mi and sc) then return nil end
    -- os.time{} 把参数当本地时间解释，返回UTC时间戳
    -- 输入是UTC时间，所以需要加上本地偏移量，抵消 os.time 的本地化处理
    local now = os.time()
    local local_offset = os.difftime(
        os.time(os.date("*t", now)),
        os.time(os.date("!*t", now))
    )
    return os.time{year=y, month=mo, day=d, hour=h, min=mi, sec=sc} + local_offset
end

-- 计算续播 end_utc：min(start_utc + 5h, now - 2min)
local function calc_resume_end_utc(start_utc)
    local start_ts = utc_str_to_timestamp(start_utc)
    if not start_ts then
        mp.msg.warn("calc_resume_end_utc: utc_str_to_timestamp 返回 nil，start_utc=" .. tostring(start_utc))
        return nil
    end
    local end_ts = start_ts + 5 * 3600   -- 固定 start+5h，服务器接受未来时间
    local result = os.date("!%Y%m%d%H%M%S", end_ts)
    mp.msg.info(string.format("calc_resume_end_utc: start=%s result=%s", start_utc, result))
    return result
end

-- 通用的时间参数替换函数，支持多种格式
local function replace_catchup_time_params(catchup_url, start_utc, end_utc)
    -- 1. 标准回看模板（OK影视等）：${utc:yyyyMMddHHmmss} 和 ${utcend:yyyyMMddHHmmss}
    catchup_url = catchup_url:gsub("%${(utc):yyyyMMddHHmmss%}", start_utc)
    catchup_url = catchup_url:gsub("%${(utcend):yyyyMMddHHmmss%}", end_utc)
    
    -- 2. KU9回看模板（酷9最新版）：${(b)yyyyMMddHHmmss|UTC} 和 ${(e)yyyyMMddHHmmss|UTC}
    catchup_url = catchup_url:gsub("%${%(b%)yyyyMMddHHmmss|UTC%}", start_utc)
    catchup_url = catchup_url:gsub("%${%(e%)yyyyMMddHHmmss|UTC%}", end_utc)
    
    -- 3. APTV回看模板：${(b)yyyyMMddHHmmss:utc} 和 ${(e)yyyyMMddHHmmss:utc}
    catchup_url = catchup_url:gsub("%${%(b%)yyyyMMddHHmmss:utc%}", start_utc)
    catchup_url = catchup_url:gsub("%${%(e%)yyyyMMddHHmmss:utc%}", end_utc)
    
    return catchup_url
end

local function format_display_date(time_str)
    local y, m, d, h, min = time_str:match("^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)")
    if not y then return "" end
    local target_time = os.time{year=y, month=m, day=d, hour=h, min=min, sec=0}
    local today_start = os.time{year=os.date("%Y"), month=os.date("%m"), day=os.date("%d"), hour=0, min=0, sec=0}
    local diff_days = math.floor((target_time - today_start) / 86400)
    local day_str = ""
    if diff_days == 0 then day_str = "今天"
    elseif diff_days == 1 then day_str = "明天"
    elseif diff_days == 2 then day_str = "后天"
    elseif diff_days == -1 then day_str = "昨天"
    elseif diff_days == -2 then day_str = "前天"
    else
        local wday = os.date("%w", target_time)
        local week_map = {["0"]="周日", ["1"]="周一", ["2"]="周二", ["3"]="周三", ["4"]="周四", ["5"]="周五", ["6"]="周六"}
        day_str = week_map[wday]
    end
    return day_str .. " " .. h .. ":" .. min
end

local function format_display_time(time_str)
    local h, m = time_str:match("^%d%d%d%d%d%d%d%d(%d%d)(%d%d)")
    if h and m then return h .. ":" .. m else return "" end
end

local function parse_epg_string(xml_str)
    mp.msg.info("EPG 内容预览 (前300字符): " .. xml_str:sub(1,300))
    state.epg_data = {}
    local count = 0
    xml_str = xml_str:gsub("\n", " ")
    for prog_block in xml_str:gmatch('<programme(.-)</programme>') do
        local start_t = prog_block:match('start="([^"]+)"')
        local stop_t = prog_block:match('stop="([^"]+)"')
        local channel_id = prog_block:match('channel="([^"]+)"')
        local title = prog_block:match('<title[^>]*>([^<]+)</title>')
        if start_t and stop_t and channel_id and title then
            if not state.epg_data[channel_id] then state.epg_data[channel_id] = {} end
            table.insert(state.epg_data[channel_id], {
                title = title,
                start_time = start_t,
                end_time = stop_t,
                start_utc = xmltv_to_utc(start_t),
                end_utc = xmltv_to_utc(stop_t),
                display_start = format_display_date(start_t),
                display_end = format_display_time(stop_t)
            })
            count = count + 1
        end
    end
    mp.msg.info("EPG 解析完成: " .. count .. " 条节目")
    if count > 0 then mp.osd_message("EPG 已加载: " .. count .. " 条节目", 3) end
end

local function get_curl_path()
    -- 使用 expand-path 获取脚本目录（支持单文件脚本）
    local success, script_dir = pcall(function()
        return mp.command_native({"expand-path", "~~home/scripts/"})
    end)
    if not success or not script_dir or script_dir == "" or script_dir == "~~home/scripts/" then
        mp.msg.verbose("无法获取脚本目录，将使用系统 curl")
        return nil
    end
    
    -- 根据平台决定二进制文件名
    local is_windows = package.config:sub(1,1) == '\\'
    local bin_name = is_windows and "curl.exe" or "curl"
    local bin_path = utils.join_path(script_dir, "bin", bin_name)
    
    mp.msg.verbose("尝试查找 curl: " .. bin_path)
    
    local file = io.open(bin_path, "r")
    if file then
        file:close()
        mp.msg.info("使用本地 curl: " .. bin_path)
        return bin_path
    end
    
    mp.msg.verbose("本地 curl 不存在，将使用系统 curl")
    -- 如果不存在，返回nil，让系统自动查找curl
    return nil
end

local function decompress_gzip_if_needed(data)
    -- 检查是否为gzip格式（前两个字节为0x1F 0x8B）
    if #data < 2 then return data end
    local byte1, byte2 = data:byte(1), data:byte(2)
    if byte1 == 0x1F and byte2 == 0x8B then
        mp.msg.verbose("检测到gzip压缩数据，尝试解压...")
        local is_windows = package.config:sub(1,1) == '\\'
        if is_windows then
            -- Windows: 使用PowerShell解压，通过临时文件避免编码问题
            local temp_dir = os.getenv('TEMP') or mp.get_script_directory()
            local temp_file = utils.join_path(temp_dir, "mpv_epg_" .. os.time() .. "_" .. math.random(10000) .. ".gz")

            
            -- 写入临时文件
            local f = io.open(temp_file, "wb")
            if f then
                f:write(data)
                f:close()
                
                -- 使用PowerShell解压gzip文件
                local ps_cmd = string.format([[
                    try {
                        $inFile = '%s'
                        $bytes = [System.IO.File]::ReadAllBytes($inFile)
                        $ms = New-Object System.IO.MemoryStream($bytes, $false)
                        $gz = New-Object System.IO.Compression.GzipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
                        $stdout = [Console]::OpenStandardOutput()
                        $gz.CopyTo($stdout)
                        $stdout.Flush()
                        $gz.Close()
                        $ms.Close()
                    } finally {
                        if (Test-Path $inFile) { Remove-Item $inFile -Force }
                    }
                ]], temp_file:gsub("\\", "\\\\"):gsub("'", "''"))
                
                local result = mp.command_native({
                    name = "subprocess",
                    args = {"powershell", "-NoProfile", "-Command", ps_cmd},
                    capture_stdout = true,
                    capture_stderr = true,
                    playback_only = false
                })
                
                if result.status == 0 and result.stdout then
                    mp.msg.verbose("gzip解压成功")
                    return result.stdout
                else
                    mp.msg.warn("gzip解压失败，返回原始数据")
                    -- 清理临时文件
                    os.remove(temp_file)
                    return data
                end
            else
                mp.msg.warn("无法创建临时文件，返回原始数据")
                return data
            end
        else
            -- Linux/macOS: 使用gzip命令
            local result = mp.command_native({
                name = "subprocess",
                args = {"gzip", "-d", "-c"},
                capture_stdout = true,
                capture_stderr = true,
                stdin_data = data
            })
            if result.status == 0 and result.stdout then
                mp.msg.verbose("gzip解压成功")
                return result.stdout
            else
                mp.msg.warn("gzip解压失败，返回原始数据")
                return data
            end
        end
    end
    -- 不是gzip格式，返回原始数据
    return data
end

local function read_file_safe(path)
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        return content
    end
    local is_windows = package.config:sub(1,1) == '\\'
    local args = is_windows and {"cmd", "/c", "type", path:gsub("/", "\\")} or {"cat", path}
    local res = mp.command_native({ name = "subprocess", args = args, capture_stdout = true })
    if res.status == 0 and res.stdout then return res.stdout end
    return nil
end

local function fetch_and_parse_epg_async(force_refresh)
    if state.epg_url == "" then return end
    
    local cache_path = get_epg_cache_path()
    
    -- 检查是否可以使用缓存
    if not force_refresh and cache_path then
        if is_cache_valid(cache_path) then
            mp.msg.info("使用缓存的 EPG 数据: " .. cache_path)
            mp.osd_message("正在加载缓存的 EPG 数据...", 2)
            local cached_data = read_file_safe(cache_path)
            if cached_data then
                parse_epg_string(decompress_gzip_if_needed(cached_data))
                return
            end
        else
            mp.msg.info("缓存过期/不存在，重新下载 EPG")
        end
    elseif force_refresh then
        mp.msg.info("强制刷新：跳过缓存，重新下载 EPG")
        mp.osd_message("正在强制刷新 EPG 数据...", 3)
    end
    
    mp.msg.info("尝试使用 curl 下载 EPG")
    
    -- 构建可能的curl命令列表：先本地，后系统
    local curl_commands = {}
    local local_curl = get_curl_path()
    if local_curl then
        table.insert(curl_commands, local_curl)
        mp.msg.info("使用 curl.exe 下载 EPG")
    else
        mp.msg.info("本地 curl 不存在，将使用系统 curl")
    end
    table.insert(curl_commands, "curl")  -- 系统curl
    local function try_next(index)
        if index > #curl_commands then
            mp.msg.error("所有 curl 尝试失败，尝试 PowerShell")
            local ps_args = {
                "powershell", "-NoProfile", "-Command",
                "$url = '" .. state.epg_url .. "'; $wc = New-Object System.Net.WebClient; $bytes = $wc.DownloadData($url); [Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)"
            }
            mp.command_native_async({
                name = "subprocess",
                args = ps_args,
                capture_stdout = true,
                capture_stderr = true,
                playback_only = false
            }, function(ps_success, ps_res)
                if ps_success and ps_res.status == 0 and ps_res.stdout then
                    -- 保存到缓存
                    if cache_path then
                        save_epg_cache(cache_path, ps_res.stdout)
                    end
                    parse_epg_string(decompress_gzip_if_needed(ps_res.stdout))
                else
                    mp.osd_message("EPG 下载失败", 5)
                end
            end)
            return
        end
        
        local curl_cmd = curl_commands[index]
        mp.msg.verbose("尝试 curl: " .. curl_cmd)
        mp.command_native_async({
            name = "subprocess",
            args = {curl_cmd, "-s", "--compressed", "-L", state.epg_url},
            capture_stdout = true,
            capture_stderr = true,
            playback_only = false
        }, function(success, res, err)
            if success and res.status == 0 and res.stdout and res.stdout ~= "" then
                -- 保存到缓存
                if cache_path then
                    save_epg_cache(cache_path, res.stdout)
                end
                parse_epg_string(decompress_gzip_if_needed(res.stdout))
                mp.msg.info("curl 下载 EPG 成功")
            else
                -- 失败，尝试下一个
                try_next(index + 1)
            end
        end)
    end
    
    try_next(1)
end

-- 强制刷新 EPG（忽略缓存）
local function force_refresh_epg()
    if state.epg_url == "" then
        mp.osd_message("未配置 EPG 下载地址", 3)
        return
    end
    mp.msg.info("手动强制刷新 EPG 数据")
    fetch_and_parse_epg_async(true)  -- true = 强制刷新
end

local function build_utility_menu_items()
    return {
        {
            title = "EPG 回看搜索",
            value = {"script-binding", "epg/show-epg-search-menu"},
            hint = "F9",
            icon = "manage_search"
        }
    }
end

local function build_channel_menu_item(group_name, ch)
    local has_epg = state.epg_data[ch.tvg_id] and #state.epg_data[ch.tvg_id] > 0
    local has_catchup = ch.catchup ~= "" and ch.catchup:find("%$%{")

    local item = {
        title = ch.name,
        search_key = ch.name,
        value = {"loadfile", ch.url},
        icon = "live_tv",
        id = "channel_" .. ch.name,
        hint = group_name,
    }

    if has_epg then
        item.hint = has_catchup and (group_name .. " | 回看▶") or (group_name .. " | EPG")
        item.items = build_channel_epg_items(ch)
    end

    return item
end

local function build_iptv_root_items()
    local items = {}
    local utility_items = build_utility_menu_items()
    for _, utility_item in ipairs(utility_items) do
        table.insert(items, utility_item)
    end

    table.insert(items, {
        title = "频道分组",
        selectable = false,
        muted = true,
        italic = true
    })

    return items
end

local function build_channel_search_items(query)
    local items = {}
    local normalized_query = trim(query or ""):lower()

    if normalized_query == "" then
        return nil
    end

    for _, group_name in ipairs(state.group_names) do
        local channels = state.groups[group_name]
        for _, ch in ipairs(channels) do
            if ch.name and channel_name_matches_query(ch.name, normalized_query) then
                table.insert(items, build_channel_menu_item(group_name, ch))
            end
        end
    end

    if #items == 0 then
        table.insert(items, {
            title = "未找到匹配的频道",
            selectable = false,
            muted = true,
            italic = true
        })
    end

    return items
end

local function update_iptv_menu_items(items)
    local menu_data = {
        id = "iptv_root",
        type = "iptv_menu",
        title = "搜索频道",
        items = items,
        anchor_x = "left",
        anchor_offset = 20,
        search_style = "palette",
        search_input_target = "iptv_root",
        on_search = {"script-message-to", "epg", "iptv-channel-search"}
    }

    mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(menu_data))
end

local function handle_iptv_channel_search(query)
    local search_items = build_channel_search_items(query)
    if search_items then
        update_iptv_menu_items(search_items)
    else
        local menu_data = build_main_menu()
        if menu_data then
            update_iptv_menu_items(menu_data.items)
        end
    end
end

local function parse_m3u(path)
    local content = read_file_safe(path)
    if not content then return false end
    state.groups = {}
    state.group_names = {}
    channel_search_cache = {}
    state.epg_url = trim(options.epg_download_url)
    if state.epg_url ~= "" then
        mp.msg.info("使用配置的 EPG 下载连接: " .. state.epg_url)
    end
    local current_info = {}
    for line in content:gmatch("([^\r\n]+)") do
        if line:match("^#EXTM3U") then
            local epg = line:match('x%-tvg%-url="([^"]+)"')
            if epg and state.epg_url == "" then state.epg_url = trim(epg) end
        elseif line:match("^#EXTINF") then
            local comma_name = line:match(",(.*)$")
            current_info = {
                tvg_id = line:match('tvg%-id="([^"]+)"') or "",
                name = comma_name or line:match('tvg%-name="([^"]+)"') or "未知频道",
                catchup = line:match('catchup%-source="([^"]+)"') or "",
                group = line:match('group%-title="([^"]+)"') or "其他频道",
                logo = line:match('tvg%-logo="([^"]+)"') or ""
            }
        elseif line:match("^http") or line:match("^rtsp") or line:match("^rtmp") or line:match("^udp") then
            current_info.url = line
            if not state.groups[current_info.group] then
                state.groups[current_info.group] = {}
                table.insert(state.group_names, current_info.group)
            end
            table.insert(state.groups[current_info.group], {
                name = current_info.name,
                url = line,
                tvg_id = current_info.tvg_id,
                catchup = current_info.catchup,
                logo = current_info.logo,
                group = current_info.group
            })
            current_info = {}
        end
    end
    state.is_loaded = true
    fetch_and_parse_epg_async()

    -- 自动播放上次播放的频道
    local last_channel = load_last_channel_from_history()
    if last_channel and last_channel.url then
        mp.msg.info("自动播放上次频道: " .. (last_channel.name or "未知"))
        state.auto_playing = true  -- 标记正在自动播放
        -- 先设置 current_channel，这样菜单能正确识别当前频道
        state.current_channel = last_channel
        mp.add_timeout(0.4, function()
            mp.commandv("loadfile", last_channel.url)
            -- 播放命令发送后，延迟清除标记（给路径变化监听器足够时间）
            mp.add_timeout(1.5, function()
                state.auto_playing = false
                mp.msg.info("自动播放标记已清除")
            end)
        end)
    end

    return true
end

-- ==================== 构建三级菜单：分组 > 频道 > EPG ====================

-- 为单个频道构建 EPG 回看子菜单
build_channel_epg_items = function(ch)
    local epg_items = {}
    local epg_list = state.epg_data[ch.tvg_id]
    
    -- 分隔线
    table.insert(epg_items, {title = "节目单", selectable = false, muted = true, italic = true})
    
    if epg_list and #epg_list > 0 then
        -- 【修改】回看资格判定延迟 2 分钟，兼容节目整点刚开始时的回看源稳定性
        local catchup_ready_utc = catchup_ready_utc_string()
        for _, prog in ipairs(epg_list) do
            local display_title = prog.display_start .. " " .. prog.title
            if ch.catchup ~= "" and ch.catchup:find("%$%{") and prog.start_utc ~= "" and prog.end_utc ~= "" and prog.start_utc <= catchup_ready_utc then
                local catchup_url = ch.catchup
                catchup_url = replace_catchup_time_params(catchup_url, prog.start_utc, prog.end_utc)
                table.insert(epg_items, {
                    title = display_title,
                    value = {"script-message-to", "epg", "play-catchup",
                        catchup_url, ch.catchup, prog.start_utc, prog.end_utc, ch.url},
                    hint = "回看",
                    icon = "history"
                })
            else
                table.insert(epg_items, {
                    title = display_title,
                    value = {"loadfile", ch.url},
                    muted = true,
                    hint = "直播"
                })
            end
        end
    else
        table.insert(epg_items, {
            title = "(暂无节目单)",
            selectable = false,
            muted = true,
            italic = true
        })
    end
    
    return epg_items
end

-- 构建主菜单（三级嵌套结构）
-- 返回值: menu_data, current_group_index, current_channel_index, current_has_epg, current_epg_index
build_main_menu = function()
    if not state.is_loaded then
        mp.osd_message("请先播放 M3U 文件！", 3)
        return nil
    end
    
    local items = build_iptv_root_items()
    local current_group_idx = nil
    local current_channel_idx = nil
    local current_has_epg = false
    local current_epg_idx = nil
    
    for group_idx, group_name in ipairs(state.group_names) do
        local channels = state.groups[group_name]
        local channel_items = {}
        
        for channel_idx, ch in ipairs(channels) do
            -- 判断是否为当前播放频道
            local is_current = state.current_channel and state.current_channel.url == ch.url
            if is_current then
                current_group_idx = group_idx
                current_channel_idx = channel_idx
            end
            
            -- 判断频道是否有 EPG 数据及回看功能
            local has_epg = state.epg_data[ch.tvg_id] and #state.epg_data[ch.tvg_id] > 0
            
            if is_current and has_epg then
                current_has_epg = true
                -- 找到当前时间点的节目索引
                local now_utc = current_utc_string()
                local epg_list = state.epg_data[ch.tvg_id]
                for i, prog in ipairs(epg_list) do
                    if prog.start_utc <= now_utc and now_utc <= prog.end_utc then
                        current_epg_idx = i + 1  -- +1 因为EPG列表第一项是分隔线"节目单"
                        break
                    end
                end
                -- 如果没找到当前节目，默认选第一个节目（索引2）
                if not current_epg_idx then
                    current_epg_idx = 2
                end
            end
            
            table.insert(channel_items, build_channel_menu_item(group_name, ch))
        end
        
        table.insert(items, {
            title = group_name,
            hint = #channels .. " 频道",
            icon = "folder",
            bold = true,
            id = "group_" .. group_name,
            items = channel_items  -- 嵌套频道列表
        })
    end
    
    local menu_data = {
        id = "iptv_root",
        type = "iptv_menu",
        title = "搜索频道",
        items = items,
        anchor_x = "left",
        anchor_offset = 20,
        search = "",
        search_style = "palette",
        search_input_target = "iptv_root",
        on_search = {"script-message-to", "epg", "iptv-channel-search"}
    }
    
    return menu_data, current_group_idx, current_channel_idx, current_has_epg, current_epg_idx
end

-- ==================== 交互命令 ====================

function show_iptv_menu()
    local menu_data, current_group_idx, current_channel_idx, current_has_epg, current_epg_idx = build_main_menu()
    if not menu_data then return end
    
    -- 确定要展开的分组ID
    local submenu_id = nil
    if state.current_channel and state.current_channel.group then
        submenu_id = "group_" .. state.current_channel.group
    elseif #state.group_names > 0 then
        submenu_id = "group_" .. state.group_names[1]
    end
    
    -- 打开菜单
    if submenu_id then
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data), submenu_id)
    else
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data))
    end
    
    -- 如果有当前频道，处理选中/展开逻辑
    if current_group_idx and current_channel_idx and state.current_channel then
        -- 延迟一点执行，确保菜单已经渲染
        mp.add_timeout(0.01, function()
            if current_has_epg and current_epg_idx then
                -- 有EPG：展开EPG子菜单，并选中当前时间点的节目
                local channel_id = "channel_" .. state.current_channel.name
                mp.commandv("script-message-to", "uosc", "expand-submenu", channel_id)
                -- 延迟选中当前时间点的节目
                mp.add_timeout(0.01, function()
                    mp.commandv("script-message-to", "uosc", "select-menu-item", "iptv_menu", tostring(current_epg_idx), channel_id)
                end)
            else
                -- 无EPG：只选中频道，不展开子菜单，不进入直播
                mp.commandv("script-message-to", "uosc", "select-menu-item", "iptv_menu", tostring(current_channel_idx), submenu_id)
            end
        end)
    end
end

-- 注册脚本绑定 (快捷键在 input.conf 中配置)
mp.add_key_binding(nil, "show-iptv-menu", show_iptv_menu)
mp.register_script_message("iptv-channel-search", function(query)
    handle_iptv_channel_search(query)
end)

-- 前向声明（实现在文件末尾）
local start_catchup_timer

-- 停止续播定时器
local function stop_catchup_timer()
    if state.catchup_timer then
        state.catchup_timer:kill()
        state.catchup_timer = nil
    end
end

-- 跟踪当前播放的频道
mp.observe_property("path", "string", function(name, path)
    if not path then return end
    for group_name, channels in pairs(state.groups) do
        for _, ch in ipairs(channels) do
            if ch.url == path or (path and path:find(ch.url, 1, true)) then
                -- 命中直播URL：清空回看上下文和timer
                stop_catchup_timer()
                state.current_catchup = nil
                -- 只有当频道真正改变时才更新
                if not state.current_channel or state.current_channel.url ~= ch.url then
                    state.current_channel = ch
                    mp.msg.info("当前频道: " .. ch.name)
                    -- 自动播放时跳过保存历史记录
                    if not state.auto_playing then
                        save_current_channel_to_history()
                    end
                end
                return
            end
        end
    end
    -- 未命中任何直播URL：当前是回看流
    -- 若 current_catchup 存在，启动/重启预判 timer
    if state.current_catchup then
        mp.msg.info("observe_property: 检测到回看URL，启动预判timer")
        stop_catchup_timer()
        start_catchup_timer()
    end
end)

-- 初始加载 M3U
mp.observe_property("path", "string", function(name, path)
    if not path then return end
    local lower_path = path:lower()
    if (lower_path:match("%.m3u$") or lower_path:match("%.m3u8$")) and not path:match("^http") then
        local clean_path = path:gsub("^file://", "")
        local wd = mp.get_property("working-directory") or ""
        if wd ~= "" and not clean_path:match("^/") and not clean_path:match("^%a+:") then
            clean_path = utils.join_path(wd, clean_path)
        end
        state.m3u_path = clean_path  -- 保存 m3u 文件路径
        mp.osd_message("解析 M3U...", 2)
        if parse_m3u(clean_path) then
            mp.osd_message("IPTV 已加载！鼠标右键:选台菜单", 4)
        end
    end
end)

mp.msg.info("IPTV 脚本已加载: 鼠标右键=三级选台菜单 (分组 > 频道 > EPG)")

-- 打印调试信息
mp.msg.info("===== EPG 脚本初始化调试信息 =====")
mp.msg.info("工作目录: " .. tostring(mp.get_property("working-directory", "未知")))
-- 获取配置目录路径
local expanded_home = ""
local success, home_path = pcall(function()
    return mp.command_native({"expand-path", "~~home/"})
end)
if success then expanded_home = home_path end
mp.msg.info("配置目录: " .. tostring(expanded_home ~= "" and expanded_home or "未找到"))
mp.msg.info("==========================")

-- 初始化：加载频道历史记录
load_channel_history()

-- ==================== EPG 回看搜索菜单 (F9) ====================
-- 【新增】EPG 回看搜索菜单 (F9) - 搜索所有可回看的节目，按时间倒序排列

-- 构建回看 EPG 搜索菜单（显示所有可回看的节目，按时间倒序排列）
local function build_catchup_epg_menu()
    if not state.is_loaded then
        mp.osd_message("请先播放 M3U 文件！", 3)
        return nil
    end
    
    local temp_items = {}  -- 临时存储，包含排序键
    -- 【修改】EPG 搜索菜单与三级菜单保持一致：节目开始 2 分钟后才显示为可回看
    local catchup_ready_utc = catchup_ready_utc_string()
    
    -- 遍历所有频道组
    for group_name, channels in pairs(state.groups) do
        for _, ch in ipairs(channels) do
            -- 检查频道是否有回看功能
            local has_catchup = ch.catchup ~= "" and ch.catchup:find("%$%{")
            if has_catchup then
                local epg_list = state.epg_data[ch.tvg_id]
                if epg_list then
                    for _, prog in ipairs(epg_list) do
                        -- 【修改】只显示开始时间早于当前时间 2 分钟的节目（可以回看）
                        if prog.start_utc <= catchup_ready_utc then
                            -- 生成回看URL
                            local catchup_url = ch.catchup
                            catchup_url = replace_catchup_time_params(catchup_url, prog.start_utc, prog.end_utc)
                            
                            -- 格式化显示文本：频道名称 + 时间 + 标题
                            local display_text = string.format("%s | %s | %s", 
                                ch.name, prog.display_start, prog.title)
                            
                            table.insert(temp_items, {
                                start_utc = prog.start_utc,
                                menu_item = {
                                    title = display_text,
                                    search_key = prog.title,  -- 只用于搜索的EPG标题
                                    value = {"script-message-to", "epg", "play-catchup",
                                        catchup_url, ch.catchup, prog.start_utc, prog.end_utc, ch.url},
                                    hint = "回看",
                                    icon = "history"
                                }
                            })
                        end
                    end
                end
            end
        end
    end
    
    -- 按开始时间倒序排列（最新的在前）
    table.sort(temp_items, function(a, b)
        return a.start_utc > b.start_utc  -- 降序排序
    end)
    
    local items = {}
    for _, temp in ipairs(temp_items) do
        table.insert(items, temp.menu_item)
    end
    
    local count = #items
    if count == 0 then
        table.insert(items, {
            title = "无可回看的节目",
            selectable = false,
            muted = true,
            italic = true
        })
    end
    
    local menu_data = {
        type = "epg_search",
        title = "EPG 回看搜索 (" .. count .. " 个节目)",
        items = items,
        anchor_x = "left",
        anchor_offset = 20,
        search = "",              -- 立即激活搜索框
        search_style = "palette", -- 立即显示搜索框（palette模式）
        search_submenus = true     -- 启用搜索功能
    }
    
    return menu_data
end

-- 【新增】显示回看 EPG 搜索菜单
local function show_epg_search_menu()
    local menu_data = build_catchup_epg_menu()
    if not menu_data then return end

    -- 强制启用输入法，解决中文输入法第一个字符输入英文的问题
    mp.set_property_bool("input-ime", true)

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data))
end

-- 注册脚本绑定 (快捷键在 input.conf 中配置)
mp.add_key_binding(nil, "show-epg-search-menu", show_epg_search_menu)

-- 注册强制刷新 EPG 快捷键 (Shift+F9)
mp.add_key_binding(nil, "force-refresh-epg", force_refresh_epg)

-- ==================== 时移续播逻辑 ====================

-- 启动续播预判定时器（每3秒检查time-remaining）
start_catchup_timer = function()
    stop_catchup_timer()
    state.catchup_timer = mp.add_periodic_timer(5, function()
        if not state.current_catchup then
            stop_catchup_timer()
            return
        end
        local remaining = mp.get_property_number("time-remaining")
        mp.msg.verbose(string.format("预判timer: time-remaining=%.1f", remaining or -1))
        if remaining == nil then return end
        if remaining > 15 then return end
        mp.msg.info(string.format("预判timer: 剩余%.1f秒 <= 15秒，触发续播", remaining))

        local cc = state.current_catchup
        if cc.retry_count >= 3 then
            mp.msg.warn("回看续播已达最大重试次数，切回直播")
            mp.osd_message("回看续播失败，切回直播", 4)
            stop_catchup_timer()
            state.current_catchup = nil
            mp.commandv("loadfile", cc.live_url)
            return
        end

        local new_end_utc = calc_resume_end_utc(cc.start_utc)
        if not new_end_utc then
            stop_catchup_timer()
            return
        end

        -- 已达5h上限（new_end == last_end）时等待播完当前片段
        local time_pos = mp.get_property_number("time-pos") or 0
        if new_end_utc <= cc.last_end_utc then
            mp.msg.verbose("续播判断: 已达5h上限，等待播完当前片段")
            return
        end

        -- 有新内容，提前切换续播URL（无缝预判）
        local new_url = replace_catchup_time_params(cc.catchup_template, cc.start_utc, new_end_utc)
        mp.msg.info(string.format("回看续播（预判）: end_utc %s -> %s", cc.last_end_utc, new_end_utc))
        mp.osd_message(string.format("回看续播中... 已延伸至 %s:%s",
            new_end_utc:sub(9,10), new_end_utc:sub(11,12)), 3)
        -- seek到当前实际播放位置（time_pos）
        mp.msg.info(string.format("回看续播seek: 跳转到 %.0f 秒处（当前time_pos）", time_pos))
        cc.pending_seek_secs = time_pos
        -- last_end_utc改存实际播放位置对应的UTC，而非new_end_utc
        -- 这样下次续播new_end(start+5h)永远大于last_end，平展续播
        cc.last_end_utc = os.date("!%Y%m%d%H%M%S", utc_str_to_timestamp(cc.start_utc) + time_pos)
        cc.retry_count = cc.retry_count + 1
        stop_catchup_timer()  -- 切换后由observe_property重新启动
        mp.commandv("loadfile", new_url)
    end)
end

-- 处理回看播放请求（由菜单项触发）
-- 参数: catchup_url, catchup_template, start_utc, end_utc, live_url
mp.register_script_message("play-catchup", function(catchup_url, catchup_template, start_utc, end_utc, live_url)
    mp.msg.info(string.format("play-catchup: start=%s end=%s", start_utc, end_utc))
    if not catchup_url or not catchup_template or not start_utc or not end_utc or not live_url then
        mp.msg.error("play-catchup: 参数不完整")
        if catchup_url then mp.commandv("loadfile", catchup_url) end
        return
    end
    state.current_catchup = {
        live_url         = live_url,
        catchup_template = catchup_template,
        start_utc        = start_utc,
        last_end_utc     = end_utc,
        retry_count      = 0
    }
    mp.commandv("loadfile", catchup_url)
end)

-- end-file 兜底：timer 来不及时处理 eof
mp.register_event("end-file", function(event)
    if event.reason ~= "eof" then
        -- 只有用户真正退出(quit)才清空续播状态
        -- stop 是 loadfile 切换流时mpv内部自动触发的，不能将它当作用户主动停止
        if event.reason == "quit" then
            stop_catchup_timer()
            state.current_catchup = nil
        end
        return
    end

    if not state.current_catchup then return end

    local cc = state.current_catchup
    stop_catchup_timer()

    if cc.retry_count >= 3 then
        mp.msg.warn("回看续播已达最大重试次数（end-file兜底），切回直播")
        mp.osd_message("回看续播失败，切回直播", 4)
        state.current_catchup = nil
        mp.commandv("loadfile", cc.live_url)
        return
    end

    local new_end_utc = calc_resume_end_utc(cc.start_utc)
    if not new_end_utc then
        state.current_catchup = nil
        return
    end

    -- 已达5h上限（new_end == last_end）则切回直播
    if new_end_utc <= cc.last_end_utc then
        mp.msg.info(string.format("续播判断(eof兜底): new_end=%s <= last_end=%s，已达5h上限，切回直播", new_end_utc, cc.last_end_utc))
        mp.osd_message("已追上直播，切换直播流", 4)
        state.current_catchup = nil
        mp.commandv("loadfile", cc.live_url)
        return
    end

    -- 续播
    local new_url = replace_catchup_time_params(cc.catchup_template, cc.start_utc, new_end_utc)
    mp.msg.info(string.format("回看续播（end-file兜底）: end_utc %s -> %s", cc.last_end_utc, new_end_utc))
    mp.osd_message(string.format("回看续播中... 已延伸至 %s:%s",
        new_end_utc:sub(9,10), new_end_utc:sub(11,12)), 3)
    -- eof时用duration计算实际播到的位置
    local duration = mp.get_property_number("duration") or 0
    local seek_secs = duration
    local actual_pos_utc = os.date("!%Y%m%d%H%M%S", utc_str_to_timestamp(cc.start_utc) + duration)
    mp.msg.info(string.format("回看续播seek(兜底): 跳转到 %.0f 秒处（actual_pos=%s）", seek_secs, actual_pos_utc))
    cc.pending_seek_secs = seek_secs
    -- last_end_utc改存实际播放位置，而非new_end_utc
    cc.last_end_utc = actual_pos_utc
    cc.retry_count = cc.retry_count + 1
    mp.commandv("loadfile", new_url)
end)

-- 续播加载完成后执行seek，跳过已看过的部分
-- 延迟1秒等待流缓冲建立，再用 keyframes 模式 seek，避免 "Invalid video timestamp" 警告和画面闪烁
mp.register_event("file-loaded", function()
    if state.current_catchup and state.current_catchup.pending_seek_secs then
        local secs = state.current_catchup.pending_seek_secs
        state.current_catchup.pending_seek_secs = nil
        mp.msg.info(string.format("file-loaded: 执行续播seek到 %.0f 秒", secs))
        mp.add_timeout(1.0, function()
            -- 再次确认仍处于回看上下文（防止1秒内用户手动切台）
            if not state.current_catchup then return end
            mp.commandv("seek", string.format("%.3f", secs), "absolute", "keyframes")
        end)
    end
end)

