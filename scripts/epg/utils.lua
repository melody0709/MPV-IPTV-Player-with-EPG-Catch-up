--[[
    utils.lua - 纯工具函数层（无 state 依赖）
    包含：字符串工具、UTF8、OSD、时间/日期、搜索拼音
]]

local mp = require 'mp'
local utils = require 'mp.utils'

-- ==================== 字符串工具 ====================

function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$")
end

function get_positive_integer_option(value)
    local number = tonumber(value)
    if not number then
        return nil
    end

    number = math.floor(number)
    if number <= 0 then
        return nil
    end

    return number
end

function escape_ass_text(text)
    if not text then
        return ""
    end

    return tostring(text)
        :gsub("\\", "\\\\")
        :gsub("{", "\\{")
        :gsub("}", "\\}")
        :gsub("\n", "\\N")
end

-- ==================== OSD ====================

function show_top_center_osd(text, duration)
    if top_center_osd_timer then
        top_center_osd_timer:kill()
        top_center_osd_timer = nil
    end

    local ass_text = "{\\an8}" .. escape_ass_text(text)
    mp.set_osd_ass(0, 0, ass_text)

    top_center_osd_timer = mp.add_timeout(duration or 2, function()
        mp.set_osd_ass(0, 0, "")
        top_center_osd_timer = nil
    end)
end

-- ==================== UTF8 ====================

function utf8_char_bytes(str, index)
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

function utf8_iter(str)
    local byte_start = 1
    return function()
        local start_index = byte_start
        if #str < start_index then return nil end
        local byte_count = utf8_char_bytes(str, start_index)
        byte_start = start_index + byte_count
        return start_index, str:sub(start_index, start_index + byte_count - 1)
    end
end

-- ==================== 时间/日期工具 ====================

function get_local_date_cache_key(ts)
    local dt = os.date("*t", ts or os.time())
    return string.format("%04d-%02d-%02d", dt.year, dt.month, dt.day)
end

function get_local_timezone_offset(reference_ts)
    local cache_key = get_local_date_cache_key(reference_ts)
    local cached_offset = timezone_offset_cache[cache_key]
    if cached_offset ~= nil then
        return cached_offset
    end

    local base_ts = reference_ts or os.time()
    local local_offset = os.difftime(
        os.time(os.date("*t", base_ts)),
        os.time(os.date("!*t", base_ts))
    )
    timezone_offset_cache[cache_key] = local_offset
    return local_offset
end

function xmltv_to_utc(time_str)
    local cached_utc = xmltv_utc_cache[time_str]
    if cached_utc ~= nil then return cached_utc end

    local y, m, d, h, min, s, sign, offset_h, offset_m = time_str:match("^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d) ([%+%-])(%d%d)(%d%d)")
    if not y then return "" end
    local t = os.time{year=y, month=m, day=d, hour=h, min=min, sec=s}
    t = t + get_local_timezone_offset(t)
    local xml_offset = (tonumber(offset_h) * 3600) + (tonumber(offset_m) * 60)
    if sign == "+" then t = t - xml_offset else t = t + xml_offset end
    local utc_time = os.date("!%Y%m%d%H%M%S", t)
    xmltv_utc_cache[time_str] = utc_time
    return utc_time
end

function current_utc_string()
    return os.date("!%Y%m%d%H%M%S")
end

function to_utc_string(timestamp)
    if not timestamp then
        return nil
    end
    return os.date("!%Y%m%d%H%M%S", timestamp)
end

-- 回看节目延迟 2 分钟才标记为可回看，避免节目刚开播时立即进入导致闪退
function catchup_ready_utc_string()
    return os.date("!%Y%m%d%H%M%S", os.time() - 120)
end

-- 将 YYYYMMDDHHmmss UTC字符串转为 Unix 时间戳
function utc_str_to_timestamp(s)
    local cached_timestamp = utc_timestamp_cache[s]
    if cached_timestamp ~= nil then return cached_timestamp end

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
    local timestamp = os.time{year=y, month=mo, day=d, hour=h, min=mi, sec=sc} + get_local_timezone_offset()
    utc_timestamp_cache[s] = timestamp
    return timestamp
end

-- 计算续播 end_utc：固定 start_utc + 5h
function calc_resume_end_utc(start_utc)
    local start_ts = utc_str_to_timestamp(start_utc)
    if not start_ts then
        mp.msg.warn("calc_resume_end_utc: utc_str_to_timestamp 返回 nil，start_utc=" .. tostring(start_utc))
        return nil
    end
    local end_ts = start_ts + 5 * 3600
    local result = os.date("!%Y%m%d%H%M%S", end_ts)
    mp.msg.info(string.format("calc_resume_end_utc: start=%s result=%s", start_utc, result))
    return result
end

-- 通用的时间参数替换函数，支持多种格式
function replace_catchup_time_params(catchup_url, start_utc, end_utc)
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

function format_display_date(time_str, today_start)
    local effective_today_start = today_start
    if not effective_today_start then
        local today_key = get_local_date_cache_key(os.time())
        effective_today_start = local_day_start_cache[today_key]
        if effective_today_start == nil then
            local now_dt = os.date("*t", os.time())
            effective_today_start = os.time({
                year = now_dt.year,
                month = now_dt.month,
                day = now_dt.day,
                hour = 0,
                min = 0,
                sec = 0,
            })
            local_day_start_cache[today_key] = effective_today_start
        end
    end

    local cache_key = tostring(effective_today_start) .. "|" .. tostring(time_str)
    local cached_display = display_date_cache[cache_key]
    if cached_display ~= nil then return cached_display end

    local y, m, d, h, min = time_str:match("^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)")
    if not y then return "" end
    local target_time = os.time{year=y, month=m, day=d, hour=h, min=min, sec=0}
    local diff_days = math.floor((target_time - effective_today_start) / 86400)
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
    local display_value = day_str .. " " .. h .. ":" .. min
    display_date_cache[cache_key] = display_value
    return display_value
end

function format_display_time(time_str)
    local h, m = time_str:match("^%d%d%d%d%d%d%d%d(%d%d)(%d%d)")
    if h and m then return h .. ":" .. m else return "" end
end

function get_local_day_start(ts)
    local cache_key = get_local_date_cache_key(ts)
    local cached_day_start = local_day_start_cache[cache_key]
    if cached_day_start ~= nil then
        return cached_day_start
    end

    local dt = os.date("*t", ts)
    local day_start = os.time({
        year = dt.year,
        month = dt.month,
        day = dt.day,
        hour = 0,
        min = 0,
        sec = 0
    })
    local_day_start_cache[cache_key] = day_start
    return day_start
end

function get_bucket_label_and_subtitle(bucket_key, now_ts)
    if DATE_BUCKET_LABELS[bucket_key] then
        return DATE_BUCKET_LABELS[bucket_key], nil
    end
    local day_offsets = {
        day_minus_2 = -2,
        day_minus_3 = -3,
        day_minus_4 = -4,
        day_minus_5 = -5,
        day_minus_6 = -6,
    }
    local offset = day_offsets[bucket_key]
    if offset then
        local target_ts = get_local_day_start(now_ts or os.time()) + offset * 86400
        local dt = os.date("*t", target_ts)
        local weekday = CHINESE_WEEKDAYS[dt.wday]
        local subtitle = string.format("%d月%d日", dt.month, dt.day)
        return weekday, subtitle
    end
    return bucket_key, nil
end

function get_bucket_key_from_timestamp(target_ts, now_ts)
    if not target_ts then
        return "today"
    end

    local reference_now = now_ts or os.time()
    local diff_days = math.floor((get_local_day_start(target_ts) - get_local_day_start(reference_now)) / 86400)

    if diff_days >= 1 then
        return "tomorrow"
    elseif diff_days == 0 then
        return "today"
    elseif diff_days == -1 then
        return "yesterday"
    elseif diff_days == -2 then
        return "day_minus_2"
    elseif diff_days == -3 then
        return "day_minus_3"
    elseif diff_days == -4 then
        return "day_minus_4"
    elseif diff_days == -5 then
        return "day_minus_5"
    elseif diff_days == -6 then
        return "day_minus_6"
    end

    return "day_minus_6"
end

function get_bucket_key_for_utc(utc_str)
    local ts = utc_str_to_timestamp(utc_str)
    return get_bucket_key_from_timestamp(ts, os.time())
end

-- ==================== 频道搜索（拼音） ====================

function load_channel_search_romanization()
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
    local roman_keys = {}
    for roman in pairs(data) do
        roman_keys[#roman_keys + 1] = roman
    end

    table.sort(roman_keys, function(a, b)
        if #a == #b then
            return a < b
        end
        return #a > #b
    end)

    -- 多音字采用稳定策略：优先较长拼音，避免广->an、莞->wan 这类短拼音覆盖常用读音。
    for _, roman in ipairs(roman_keys) do
        local chars = data[roman]
        for _, char in utf8_iter(chars) do
            if not romanization[char] then
                romanization[char] = roman
            end
        end
    end

    channel_search_romanization = romanization
    return channel_search_romanization
end

function build_channel_search_terms(name)
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

        for _, token in ipairs(forward_full) do
            full_sequences.forward[#full_sequences.forward + 1] = token
        end
        for _, token in ipairs(forward_initials) do
            initial_sequences.forward[#initial_sequences.forward + 1] = token
        end
        for _, token in ipairs(reverse_groups) do
            full_sequences.backward[#full_sequences.backward + 1] = token
        end
        for _, token in ipairs(reverse_initials_groups) do
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

function token_sequences_match_query(token_sequences, query)
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

function channel_name_matches_query(name, query)
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
