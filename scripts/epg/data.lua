--[[
    data.lua - 数据层
    包含：EPG缓存/下载/解析、M3U解析、历史记录、频道查找
]]

local mp = require 'mp'
local utils = require 'mp.utils'

-- ==================== EPG 缓存相关函数 ====================

-- 获取缓存目录路径
function get_cache_dir()
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
function simple_hash(str)
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
function get_epg_cache_path()
    if state.epg_url == "" then return nil end
    local cache_dir = get_cache_dir()
    if not cache_dir then return nil end
    local url_hash = simple_hash(state.epg_url)
    return utils.join_path(cache_dir, "epg_" .. url_hash .. ".xml")
end

function get_subscription_m3u_key(url)
    local normalized_url = trim(url or "")
    if normalized_url == "" then
        return ""
    end
    return "sub:" .. normalized_url
end

function get_subscription_m3u_cache_path(url)
    local normalized_url = trim(url or "")
    if normalized_url == "" then return nil end
    local cache_dir = get_cache_dir()
    if not cache_dir then return nil end
    return utils.join_path(cache_dir, "m3u_" .. simple_hash(normalized_url) .. ".m3u")
end

local function save_cache_file(cache_path, data, label)
    if not cache_path or not data then return false end

    local file, err = io.open(cache_path, "wb")
    if not file then
        mp.msg.warn(string.format("无法保存%s: %s", label or "缓存文件", tostring(err)))
        return false
    end

    file:write(data)
    file:close()
    mp.msg.info(string.format("%s已保存: %s (%d 字节)", label or "缓存文件", cache_path, #data))
    return true
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

function is_cache_valid(cache_path)
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
function save_epg_cache(cache_path, data)
    save_cache_file(cache_path, data, "EPG 缓存")
end

-- ==================== 历史记录 ====================

-- 获取历史记录文件路径
-- 使用 mpv 配置目录下的 cache 子目录，如果不存在则使用 Windows 临时目录
function get_history_file_path()
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
function load_channel_history()
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
function save_channel_history()
    local history_path = get_history_file_path()
    mp.msg.info("尝试保存历史记录到: " .. history_path)

    local file, err = io.open(history_path, "w")
    if file then
        local content = utils.format_json(state.channel_history)
        file:write(content)
        file:close()
        state.history_dirty = false
        mp.msg.info("频道历史记录已保存成功: " .. history_path)
        return true
    else
        mp.msg.error("无法保存频道历史记录: " .. tostring(err))
        mp.msg.error("目标路径: " .. history_path)
        return false
    end
end

function schedule_channel_history_save(channel_name)
    state.history_dirty = true

    if history_save_timer then
        history_save_timer:kill()
        history_save_timer = nil
    end

    history_save_timer = mp.add_timeout(HISTORY_SAVE_DELAY, function()
        history_save_timer = nil
        flush_channel_history()
    end)

    if channel_name and channel_name ~= "" then
        mp.msg.info(string.format("频道历史记录已加入延迟保存队列(%.1f秒): %s", HISTORY_SAVE_DELAY, channel_name))
    else
        mp.msg.info(string.format("频道历史记录已加入延迟保存队列(%.1f秒)", HISTORY_SAVE_DELAY))
    end
end

function flush_channel_history()
    if history_save_timer then
        history_save_timer:kill()
        history_save_timer = nil
    end

    if not state.history_dirty then
        return false
    end

    return save_channel_history()
end

-- 获取 m3u 文件的唯一标识（使用文件路径的哈希）
local function normalize_m3u_key(m3u_path)
    return (m3u_path or ""):gsub("\\", "/"):gsub("^file://", "")
end

function get_m3u_key(m3u_path)
    if state.m3u_path ~= "" and m3u_path == state.m3u_path and state.m3u_source_key ~= "" then
        return state.m3u_source_key
    end
    return normalize_m3u_key(m3u_path)
end

-- 保存当前播放的频道到历史记录
function save_current_channel_to_history()
    if not state.m3u_path or state.m3u_path == "" then return end
    if not state.current_channel or not state.current_channel.url then return end

    local m3u_key = get_m3u_key(state.m3u_path)
    state.channel_history[m3u_key] = {
        url = state.current_channel.url,
        name = state.current_channel.name,
        group = state.current_channel.group,
        timestamp = os.time()
    }
    schedule_channel_history_save(state.current_channel.name)
end

-- 从历史记录加载上次播放的频道
function load_last_channel_from_history()
    if not state.m3u_path or state.m3u_path == "" then return nil end

    local m3u_key = get_m3u_key(state.m3u_path)
    local history = state.channel_history[m3u_key]

    if history and history.url then
        mp.msg.info("从历史记录加载频道: " .. (history.name or "未知"))
        return history
    end

    return nil
end

-- ==================== EPG 解析/下载 ====================

function parse_epg_string(xml_str)
    mp.msg.info("EPG 内容预览 (前300字符): " .. xml_str:sub(1,300))
    state.epg_data = {}
    state.epg_buckets = {}
    state.channel_bucket_cache = {}
    local parse_now_ts = os.time()
    local parse_day_start = get_local_day_start(parse_now_ts)
    local count = 0
    for prog_block in xml_str:gmatch('<programme(.-)</programme>') do
        local start_t = prog_block:match('start="([^"]+)"')
        local stop_t = prog_block:match('stop="([^"]+)"')
        local channel_id = prog_block:match('channel="([^"]+)"')
        local title = prog_block:match('<title[^>]*>([^<]+)</title>')
        if start_t and stop_t and channel_id and title then
            local channel_epg = state.epg_data[channel_id]
            if not channel_epg then
                channel_epg = {}
                state.epg_data[channel_id] = channel_epg
            end

            local start_utc = xmltv_to_utc(start_t)
            local end_utc = xmltv_to_utc(stop_t)
            local start_ts = utc_str_to_timestamp(start_utc)
            local end_ts = utc_str_to_timestamp(end_utc)
            local prog_entry = {
                title = title,
                start_time = start_t,
                end_time = stop_t,
                start_utc = start_utc,
                end_utc = end_utc,
                start_ts = start_ts,
                end_ts = end_ts,
                bucket_key = get_bucket_key_from_timestamp(start_ts, parse_now_ts),
                display_start = format_display_date(start_t, parse_day_start),
                display_end = format_display_time(stop_t)
            }
            channel_epg[#channel_epg + 1] = prog_entry

            local date_str = os.date("%Y-%m-%d", start_ts)
            local day_buckets = state.epg_buckets[channel_id]
            if not day_buckets then
                day_buckets = {}
                state.epg_buckets[channel_id] = day_buckets
            end
            if not day_buckets[date_str] then
                day_buckets[date_str] = {}
            end
            table.insert(day_buckets[date_str], prog_entry)

            count = count + 1
        end
    end
    mp.msg.info("EPG 解析完成: " .. count .. " 条节目")
    if count > 0 then mp.osd_message("EPG 已加载: " .. count .. " 条节目", 3) end
end

function get_curl_path()
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
    return nil
end

function download_url_async(url, request_options, callback)
    local normalized_url = trim(url or "")
    if normalized_url == "" then
        if callback then
            callback(false, nil, nil, "empty-url")
        end
        return false
    end

    local opts = request_options or {}
    local description = opts.description or "资源"
    local use_compressed = opts.compressed ~= false
    local is_windows = package.config:sub(1, 1) == '\\'

    local curl_commands = {}
    local local_curl = get_curl_path()
    if local_curl then
        table.insert(curl_commands, local_curl)
    end
    table.insert(curl_commands, "curl")

    local function finish(success, data, backend, err)
        if callback then
            callback(success, data, backend, err)
        end
    end

    local function try_powershell()
        if not is_windows then
            finish(false, nil, nil, "curl-failed")
            return
        end

        local escaped_url = normalized_url:gsub("'", "''")
        local ps_args = {
            "powershell", "-NoProfile", "-Command",
            "$url = '" .. escaped_url .. "'; $ProgressPreference = 'SilentlyContinue'; $wc = New-Object System.Net.WebClient; $bytes = $wc.DownloadData($url); [Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)"
        }

        mp.command_native_async({
            name = "subprocess",
            args = ps_args,
            capture_stdout = true,
            capture_stderr = true,
            playback_only = false
        }, function(ps_success, ps_res)
            if ps_success and ps_res.status == 0 and ps_res.stdout and ps_res.stdout ~= "" then
                finish(true, ps_res.stdout, "powershell")
            else
                mp.msg.error(string.format("%s 下载失败: PowerShell 兜底不可用", description))
                finish(false, nil, "powershell", "powershell-failed")
            end
        end)
    end

    local function try_curl(index)
        if index > #curl_commands then
            try_powershell()
            return
        end

        local curl_cmd = curl_commands[index]
        local args = {curl_cmd, "-s", "-L"}
        if use_compressed then
            table.insert(args, "--compressed")
        end
        table.insert(args, normalized_url)

        mp.msg.verbose(string.format("尝试下载%s: %s", description, curl_cmd))
        mp.command_native_async({
            name = "subprocess",
            args = args,
            capture_stdout = true,
            capture_stderr = true,
            playback_only = false
        }, function(success, res)
            if success and res.status == 0 and res.stdout and res.stdout ~= "" then
                finish(true, res.stdout, curl_cmd)
            else
                try_curl(index + 1)
            end
        end)
    end

    try_curl(1)
    return true
end

function decompress_gzip_if_needed(data)
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

function read_file_safe(path)
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        return content
    end
    local is_windows = package.config:sub(1,1) == '\\'
    local normalized_path = is_windows and path:gsub("/", "\\") or path
    local args = is_windows and {"cmd", "/c", "type", normalized_path} or {"cat", normalized_path}
    local res = mp.command_native({ name = "subprocess", args = args, capture_stdout = true })
    if res and res.status == 0 and res.stdout then return res.stdout end
    return nil
end

local function apply_parsed_channel_selection(channel)
    if not channel or not channel.url then
        return false
    end

    local matched_group_name, matched_channel_index = find_channel_position_by_url(channel.url)
    if matched_group_name and matched_channel_index then
        local resolved_channel = set_selected_channel_position(matched_group_name, matched_channel_index) or channel
        set_current_channel_state(resolved_channel)
        return true
    end

    state.selected_group_name = nil
    state.selected_channel_index = nil
    set_current_channel_state(channel)
    return true
end

function fetch_and_parse_epg_async(force_refresh)
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

    mp.msg.info("尝试下载 EPG 数据")
    download_url_async(state.epg_url, {
        description = "EPG",
        compressed = true,
    }, function(success, data)
        if success and data then
            if cache_path then
                save_epg_cache(cache_path, data)
            end
            parse_epg_string(decompress_gzip_if_needed(data))
            mp.msg.info("EPG 下载成功")
        else
            mp.osd_message("EPG 下载失败", 5)
        end
    end)
end

function refresh_subscription_m3u_async(force_refresh, callback)
    local subscription_url = trim(options.m3u_download_url)
    if subscription_url == "" then
        if callback then
            callback(false, {reason = "not-configured"})
        end
        return false
    end

    if state.subscription_refresh_in_progress then
        if callback then
            callback(false, {reason = "busy"})
        end
        return false
    end

    local source_key = get_subscription_m3u_key(subscription_url)
    local cache_path = get_subscription_m3u_cache_path(subscription_url)
    if not cache_path then
        if callback then
            callback(false, {reason = "cache-unavailable"})
        end
        return false
    end

    local previous_cache = cache_path and read_file_safe(cache_path) or nil
    local previous_hash = previous_cache and simple_hash(previous_cache) or state.subscription_last_hash

    state.subscription_refresh_in_progress = true
    mp.msg.info(force_refresh and "开始强制刷新 IPTV 订阅" or "开始刷新 IPTV 订阅")

    download_url_async(subscription_url, {
        description = "M3U订阅",
        compressed = false,
    }, function(success, data)
        state.subscription_refresh_in_progress = false

        if not success or not data or trim(data) == "" then
            mp.msg.error("M3U 订阅下载失败")
            if callback then
                callback(false, {reason = "download-failed"})
            end
            return
        end

        local new_hash = simple_hash(data)
        local changed = new_hash ~= previous_hash

        if changed or not previous_cache then
            if not save_cache_file(cache_path, data, "M3U 订阅缓存") then
                if callback then
                    callback(false, {reason = "cache-save-failed", cache_path = cache_path})
                end
                return
            end
        else
            mp.msg.info("M3U 订阅内容未变化，跳过重新解析")
        end

        state.subscription_url = subscription_url
        state.subscription_cache_path = cache_path
        state.subscription_last_hash = new_hash

        local should_apply_to_player = state.active_source_kind ~= "local"
            and (not state.is_loaded or state.m3u_source_key == "" or state.m3u_source_key == source_key)

        if not should_apply_to_player then
            if callback then
                callback(true, {changed = changed, applied = false, cache_path = cache_path})
            end
            return
        end

        if changed or not state.is_loaded or state.m3u_source_key ~= source_key then
            local was_loaded = state.is_loaded and state.m3u_source_key == source_key
            state.active_source_kind = "subscription"
            local parse_ok = parse_m3u(cache_path, {
                is_subscription = true,
                source_key = source_key,
                cache_path = cache_path,
                subscription_url = subscription_url,
                content_hash = new_hash,
                history_autoplay = not was_loaded,
                preserve_current_channel = was_loaded,
                force_epg_refresh = force_refresh,
            })
            if not parse_ok then
                if callback then
                    callback(false, {reason = "parse-failed", cache_path = cache_path})
                end
                return
            end
        elseif force_refresh then
            fetch_and_parse_epg_async(true)
        end

        if callback then
            callback(true, {changed = changed, applied = true, cache_path = cache_path})
        end
    end)

    return true
end

function bootstrap_subscription_m3u()
    local subscription_url = trim(options.m3u_download_url)
    if subscription_url == "" then
        return false
    end

    local source_key = get_subscription_m3u_key(subscription_url)
    local cache_path = get_subscription_m3u_cache_path(subscription_url)
    if not cache_path then
        mp.msg.error("无法确定 IPTV 订阅缓存路径")
        return false
    end

    local cached_data = cache_path and read_file_safe(cache_path) or nil
    local cache_loaded = false
    local cache_valid = cached_data and is_cache_valid(cache_path) or false

    if cached_data and cache_path then
        state.active_source_kind = "subscription"
        mp.msg.info("检测到 IPTV 订阅缓存，优先从缓存启动")
        mp.osd_message("正在从缓存启动 IPTV 订阅...", 2)
        cache_loaded = parse_m3u(cache_path, {
            is_subscription = true,
            source_key = source_key,
            cache_path = cache_path,
            subscription_url = subscription_url,
            content_hash = simple_hash(cached_data),
            skip_epg_refresh = not cache_valid,
        })
        if cache_loaded then
            mp.osd_message("IPTV 订阅已从缓存启动", 2)
        end
    end

    if cache_valid then
        mp.msg.info("IPTV 订阅缓存仍在有效期内，跳过后台刷新")
        return cache_loaded
    end

    if cache_loaded then
        mp.msg.info("IPTV 订阅缓存已启动，后台刷新远程 M3U")
    else
        mp.osd_message("正在更新 IPTV 订阅...", 3)
    end

    refresh_subscription_m3u_async(false, function(success)
        if not success and cache_loaded then
            fetch_and_parse_epg_async(false)
        elseif not success then
            mp.osd_message("IPTV 订阅下载失败", 5)
        end
    end)

    return cache_loaded
end

-- 强制刷新 EPG（忽略缓存）
function force_refresh_epg()
    local subscription_url = trim(options.m3u_download_url)
    local subscription_key = get_subscription_m3u_key(subscription_url)
    if subscription_url ~= "" and state.is_subscription_mode and state.m3u_source_key == subscription_key then
        mp.msg.info("手动强制刷新 IPTV 订阅与 EPG 数据")
        mp.osd_message("正在强制刷新 IPTV 订阅...", 3)
        refresh_subscription_m3u_async(true, function(success)
            if not success then
                fetch_and_parse_epg_async(true)
            end
        end)
        return
    end

    if state.epg_url == "" then
        mp.osd_message("未配置 EPG 下载地址", 3)
        return
    end
    mp.msg.info("手动强制刷新 EPG 数据")
    fetch_and_parse_epg_async(true)  -- true = 强制刷新
end

-- ==================== M3U 解析 ====================

function parse_m3u(path, parse_options)
    parse_options = parse_options or {}
    local content = read_file_safe(path)
    if not content then return false end

    local preserve_current_channel = parse_options.preserve_current_channel == true
    local previous_channel = preserve_current_channel and state.current_channel or nil

    state.m3u_path = path
    state.m3u_source_key = parse_options.source_key or normalize_m3u_key(path)
    state.is_subscription_mode = parse_options.is_subscription == true
    state.subscription_url = state.is_subscription_mode and (parse_options.subscription_url or trim(options.m3u_download_url)) or ""
    state.subscription_cache_path = state.is_subscription_mode and (parse_options.cache_path or path) or nil
    state.subscription_last_hash = parse_options.content_hash or (state.is_subscription_mode and simple_hash(content) or nil)
    state.active_source_kind = state.is_subscription_mode and "subscription" or "local"

    state.groups = {}
    state.group_names = {}
    state.channel_bucket_cache = {}
    state.url_to_channel_map = {}
    state.epg_buckets = {}
    channel_search_cache = {}
    state.selected_group_name = nil
    state.selected_channel_index = nil
    if not preserve_current_channel then
        set_current_channel_state(nil)
        set_current_catchup_state(nil, nil)
    end
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
            local channel_index = #state.groups[current_info.group] + 1
            local ch_entry = {
                name = current_info.name,
                url = line,
                tvg_id = current_info.tvg_id,
                catchup = current_info.catchup,
                logo = current_info.logo,
                group = current_info.group
            }
            table.insert(state.groups[current_info.group], ch_entry)
            local base_url = line:match("^([^?]+)") or line
            state.url_to_channel_map[base_url] = {
                group_name = current_info.group,
                channel_index = channel_index,
                channel = ch_entry
            }
            current_info = {}
        end
    end
    state.is_loaded = true

    if preserve_current_channel and previous_channel and apply_parsed_channel_selection(previous_channel) then
        mp.msg.info("订阅刷新后已保持当前频道状态")
    else
        local should_restore_history = parse_options.history_autoplay ~= false
        if should_restore_history then
            local last_channel = load_last_channel_from_history()
            if last_channel and last_channel.url then
                mp.msg.info("自动播放上次频道: " .. (last_channel.name or "未知"))
                state.auto_playing = true  -- 标记正在自动播放
                local last_group_name, last_channel_index = find_channel_position_by_url(last_channel.url)
                local resolved_channel = set_selected_channel_position(last_group_name, last_channel_index) or last_channel
                -- 先设置 current_channel，这样菜单能正确识别当前频道
                set_current_channel_state(resolved_channel)
                load_iptv_url(last_channel.url, "history-resume")
                -- 播放命令发送后，延迟清除标记（给路径变化监听器足够时间）
                mp.add_timeout(1.5, function()
                    state.auto_playing = false
                    mp.msg.info("自动播放标记已清除")
                end)
            end
        end
    end

    if not parse_options.skip_epg_refresh then
        mp.add_timeout(0, function()
            fetch_and_parse_epg_async(parse_options.force_epg_refresh == true)
        end)
    end

    return true
end

-- ==================== URL 匹配 ====================

function url_matches(path, target_url)
    if path == target_url then return true end
    local target_len = #target_url
    if path:sub(1, target_len) == target_url then
        local next_char = path:sub(target_len + 1, target_len + 1)
        if next_char:match("[?#/]") then
            return true
        end
    end
    return false
end

-- ==================== 频道查找 ====================

function get_current_program_for_channel(ch, now_utc)
    if not ch or not ch.tvg_id or ch.tvg_id == "" then
        return nil, nil
    end

    local epg_list = state.epg_data[ch.tvg_id]
    if not epg_list or #epg_list == 0 then
        return nil, nil
    end

    local reference_utc = now_utc or current_utc_string()
    local reference_ts = utc_str_to_timestamp(reference_utc)
    for index, prog in ipairs(epg_list) do
        local has_timestamps = reference_ts and prog.start_ts and prog.end_ts
        if has_timestamps and prog.start_ts <= reference_ts and reference_ts <= prog.end_ts then
            return prog, index
        end
        if not has_timestamps and prog.start_utc ~= "" and prog.end_utc ~= "" and prog.start_utc <= reference_utc and reference_utc <= prog.end_utc then
            return prog, index
        end
    end

    return nil, nil
end

function get_current_program_from_list(programs, reference_utc)
    if not programs or #programs == 0 then
        return nil, nil
    end

    local compare_utc = reference_utc or current_utc_string()
    local compare_ts = utc_str_to_timestamp(compare_utc)
    for index, prog in ipairs(programs) do
        local has_timestamps = compare_ts and prog.start_ts and prog.end_ts
        if has_timestamps and prog.start_ts <= compare_ts and compare_ts <= prog.end_ts then
            return prog, index
        end
        if not has_timestamps and prog.start_utc ~= "" and prog.end_utc ~= "" and prog.start_utc <= compare_utc and compare_utc <= prog.end_utc then
            return prog, index
        end
    end

    return nil, nil
end

function get_channel_bucket_data(ch)
    if not ch or not ch.tvg_id or ch.tvg_id == "" then
        return nil
    end

    local pre_buckets = state.epg_buckets[ch.tvg_id]
    if not pre_buckets then
        local epg_list = state.epg_data[ch.tvg_id]
        if not epg_list or #epg_list == 0 then
            return nil
        end
    end

    local now_ts = os.time()
    local day_offsets = {
        tomorrow = 1,
        today = 0,
        yesterday = -1,
        day_minus_2 = -2,
        day_minus_3 = -3,
        day_minus_4 = -4,
        day_minus_5 = -5,
        day_minus_6 = -6,
    }

    local buckets = {}
    for _, bucket_key in ipairs(DATE_BUCKET_ORDER) do
        local label, subtitle = get_bucket_label_and_subtitle(bucket_key, now_ts)
        local offset = day_offsets[bucket_key] or 0
        local date_str = os.date("%Y-%m-%d", get_local_day_start(now_ts) + offset * 86400)
        local programs = pre_buckets and pre_buckets[date_str] or {}

        buckets[bucket_key] = {
            key = bucket_key,
            label = label,
            subtitle = subtitle,
            programs = programs or {}
        }
    end

    return buckets
end

function find_channel_by_url(url)
    if not url or url == "" then
        return nil
    end

    local base_url = url:match("^([^?]+)") or url
    local map_entry = state.url_to_channel_map and state.url_to_channel_map[base_url]
    if map_entry then
        return map_entry.channel
    end

    for _, group_name in ipairs(state.group_names) do
        local channels = state.groups[group_name]
        if channels then
            for _, ch in ipairs(channels) do
                if ch.url == url then
                    return ch
                end
            end
        end
    end

    return nil
end

function find_channel_position_by_url(channel_url)
    if not channel_url or channel_url == "" then
        return nil, nil
    end

    local base_url = channel_url:match("^([^?]+)") or channel_url
    local map_entry = state.url_to_channel_map and state.url_to_channel_map[base_url]
    if map_entry then
        return map_entry.group_name, map_entry.channel_index
    end

    for _, group_name in ipairs(state.group_names) do
        local channels = state.groups[group_name]
        if channels then
            for channel_index, ch in ipairs(channels) do
                if ch.url == channel_url then
                    return group_name, channel_index
                end
            end
        end
    end

    return nil, nil
end

get_channel_by_position = function(group_name, channel_index)
    local channels = group_name and state.groups[group_name] or nil
    if not channels or not channel_index then
        return nil
    end

    return channels[channel_index]
end

function set_selected_channel_position(group_name, channel_index)
    local channels = group_name and state.groups[group_name] or nil
    if not channels or not channel_index or not channels[channel_index] then
        state.selected_group_name = nil
        state.selected_channel_index = nil
        sync_iptv_button_state()
        return nil
    end

    state.selected_group_name = group_name
    state.selected_channel_index = channel_index
    sync_iptv_button_state()
    return channels[channel_index]
end

function get_menu_active_channel()
    if state.current_catchup and state.current_catchup.live_url then
        local catchup_channel = find_channel_by_url(state.current_catchup.live_url)
        if catchup_channel then
            return catchup_channel
        end
    end

    local selected_channel = get_channel_by_position(state.selected_group_name, state.selected_channel_index)
    if selected_channel then
        return selected_channel
    end

    return state.current_channel
end
