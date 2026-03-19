--[[
  mpv + uosc 5.12 IPTV 脚本 V5.2
  重构：三级滑动菜单结构 - 分组 > 频道 > EPG回看
]]

local mp = require 'mp'
local utils = require 'mp.utils'

local state = {
    m3u_path = "",
    epg_url = "",
    groups = {},       
    group_names = {},  
    epg_data = {},     
    is_loaded = false,
    current_channel = nil
}

-- ==================== 工具函数（保持原样） ====================
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
    mp.msg.info("EPG 内容预览 (前500字符): " .. xml_str:sub(1,500))
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

local function fetch_and_parse_epg_async()
    if state.epg_url == "" then return end
    mp.osd_message("正在后台下载 EPG 数据...", 3)
    if mp.http_request then
        mp.http_request({
            url = state.epg_url,
            method = "GET",
            headers = { ["Accept-Encoding"] = "gzip, deflate" },
        }, function(res)
            if res.status == 200 and res.body then parse_epg_string(res.body) end
        end)
        return
    end
    mp.msg.warn("尝试使用 curl 下载 EPG")
    mp.command_native_async({
        name = "subprocess",
        args = {"curl", "-s", "--compressed", "-L", state.epg_url},
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false
    }, function(success, res, err)
        if success and res.status == 0 and res.stdout and res.stdout ~= "" then
            parse_epg_string(res.stdout)
        else
            mp.msg.error("curl 失败，尝试 PowerShell")
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
                    parse_epg_string(ps_res.stdout)
                else
                    mp.osd_message("EPG 下载失败", 5)
                end
            end)
        end
    end)
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

local function parse_m3u(path)
    local content = read_file_safe(path)
    if not content then return false end
    state.groups = {}
    state.group_names = {}
    state.epg_url = ""
    local current_info = {}
    for line in content:gmatch("([^\r\n]+)") do
        if line:match("^#EXTM3U") then
            local epg = line:match('x%-tvg%-url="([^"]+)"')
            if epg then state.epg_url = epg end
        elseif line:match("^#EXTINF") then
            current_info = {
                tvg_id = line:match('tvg%-id="([^"]+)"') or "",
                name = line:match('tvg%-name="([^"]+)"') or "未知频道",
                catchup = line:match('catchup%-source="([^"]+)"') or "",
                group = line:match('group%-title="([^"]+)"') or "其他频道",
                logo = line:match('tvg%-logo="([^"]+)"') or ""
            }
            local comma_name = line:match(",(.*)$")
            if comma_name and current_info.name == "未知频道" then
                current_info.name = comma_name
            end
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
                logo = current_info.logo
            })
            current_info = {}
        end
    end
    state.is_loaded = true
    fetch_and_parse_epg_async()
    return true
end

-- ==================== 构建三级菜单：分组 > 频道 > EPG ====================

-- 为单个频道构建 EPG 回看子菜单
local function build_channel_epg_items(ch)
    local epg_items = {}
    local epg_list = state.epg_data[ch.tvg_id]
    
    -- 分隔线
    table.insert(epg_items, {title = "节目单", selectable = false, muted = true, italic = true})
    
    if epg_list and #epg_list > 0 then
        local now_utc = current_utc_string()
        for _, prog in ipairs(epg_list) do
            local display_title = prog.display_start .. " " .. prog.title
            if ch.catchup ~= "" and ch.catchup:find("%$%{") and prog.start_utc ~= "" and prog.end_utc ~= "" and prog.start_utc <= now_utc then
                local catchup_url = ch.catchup
                catchup_url = catchup_url:gsub("%${%(b%)yyyyMMddHHmmss|UTC%}", prog.start_utc)
                catchup_url = catchup_url:gsub("%${%(e%)yyyyMMddHHmmss|UTC%}", prog.end_utc)
                table.insert(epg_items, {
                    title = display_title,
                    value = {"loadfile", catchup_url},
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
local function build_main_menu()
    if not state.is_loaded then
        mp.osd_message("请先播放 M3U 文件！", 3)
        return nil
    end
    
    local items = {}
    
    for _, group_name in ipairs(state.group_names) do
        local channels = state.groups[group_name]
        local channel_items = {}
        
        for _, ch in ipairs(channels) do
            -- 判断频道是否有 EPG 数据及回看功能
            local has_epg = state.epg_data[ch.tvg_id] and #state.epg_data[ch.tvg_id] > 0
            local has_catchup = ch.catchup ~= "" and ch.catchup:find("%$%{")
            
            if has_epg then
                -- 有EPG数据：同时支持直接播放和 EPG 子菜单
                local hint_text = has_catchup and "回看▶" or "EPG"
                table.insert(channel_items, {
                    title = ch.name,
                    value = {"loadfile", ch.url},  -- 点击直接播放
                    icon = "live_tv",
                    hint = hint_text,
                    items = build_channel_epg_items(ch)  -- 右侧展开 EPG 子菜单
                })
            else
                -- 无EPG数据：频道直接播放
                table.insert(channel_items, {
                    title = ch.name,
                    value = {"loadfile", ch.url},
                    icon = "live_tv"
                })
            end
        end
        
        table.insert(items, {
            title = group_name,
            hint = #channels .. " 频道",
            icon = "folder",
            bold = true,
            items = channel_items  -- 嵌套频道列表
        })
    end
    
    return {
        type = "iptv_menu",
        title = "IPTV 选台",
        items = items,
        anchor_x = "left",
        anchor_offset = 20
    }
end

-- ==================== 交互命令 ====================

function show_iptv_menu()
    local menu_data = build_main_menu()
    if menu_data then
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data))
    end
end

mp.add_key_binding("F8", "show-iptv-menu", show_iptv_menu)
mp.add_key_binding("MBTN_RIGHT", "show-iptv-menu-mouse", show_iptv_menu)

-- 强制覆盖鼠标右键绑定，优先于 uosc 的暂停功能
mp.set_key_bindings({
    {'MBTN_RIGHT', show_iptv_menu}
}, 'MBTN_RIGHT', 'force')

-- 跟踪当前播放的频道
mp.observe_property("path", "string", function(name, path)
    if not path then return end
    for group_name, channels in pairs(state.groups) do
        for _, ch in ipairs(channels) do
            if ch.url == path or (path and path:find(ch.url, 1, true)) then
                state.current_channel = ch
                mp.msg.info("当前频道: " .. ch.name)
                return
            end
        end
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
        mp.osd_message("解析 M3U...", 2)
        if parse_m3u(clean_path) then
            mp.osd_message("IPTV 已加载！鼠标右键:选台菜单", 4)
        end
    end
end)

mp.msg.info("IPTV 脚本已加载: 鼠标右键=三级选台菜单 (分组 > 频道 > EPG)")

-- 强制覆盖鼠标右键绑定，优先于 uosc 的暂停功能
mp.set_key_bindings({
    {'MBTN_RIGHT', show_iptv_menu}
}, 'MBTN_RIGHT', 'force')

