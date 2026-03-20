--[[
  mpv + uosc 5.12 IPTV 脚本 V5.2
  重构：三级滑动菜单结构 - 分组 > 频道 > EPG回看
]]

local mp = require 'mp'
local utils = require 'mp.utils'
local opt = require 'mp.options'

local options = {
    epg_download_url = ""
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
    channel_history = {}
}

-- ==================== 工具函数（保持原样） ====================

-- 去除字符串前后空白字符
local function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$")
end

-- 获取历史记录文件路径
-- 优先使用 mpv 配置目录，如果不存在则使用 Windows 临时目录
local function get_history_file_path()
    -- 方法1: 使用 mpv 配置目录
    local config_dir = mp.find_config_file("")
    if config_dir then
        -- 移除末尾的目录分隔符
        config_dir = config_dir:gsub("[\\/]+$", "")
        local history_path = utils.join_path(config_dir, state.history_file)
        mp.msg.info("历史记录路径 (mpv配置目录): " .. history_path)
        return history_path
    end

    -- 方法2: 获取 mpv 配置路径
    local mpv_config = mp.get_property("config-dir", "")
    if mpv_config and mpv_config ~= "" then
        local history_path = utils.join_path(mpv_config, state.history_file)
        mp.msg.info("历史记录路径 (config-dir): " .. history_path)
        return history_path
    end

    -- 方法3: 使用 Windows 临时目录
    local is_windows = package.config:sub(1,1) == '\\'
    if is_windows then
        local temp_dir = os.getenv("TEMP") or os.getenv("TMP")
        if temp_dir then
            local history_path = utils.join_path(temp_dir, "mpv_epg_" .. state.history_file)
            mp.msg.info("历史记录路径 (Windows临时目录): " .. history_path)
            return history_path
        end
    end

    -- 方法4: 使用脚本目录（最后备选）
    local script_dir = mp.get_script_directory()
    if script_dir then
        local history_path = utils.join_path(script_dir, state.history_file)
        mp.msg.info("历史记录路径 (脚本目录): " .. history_path)
        return history_path
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

local function get_curl_path()
    -- 获取脚本所在目录
    local script_dir = mp.get_script_directory()
    if not script_dir then return nil end
    -- 根据平台决定二进制文件名
    local is_windows = package.config:sub(1,1) == '\\'
    local bin_name = is_windows and "curl.exe" or "curl"
    local bin_path = utils.join_path(script_dir, "bin", bin_name)
    local file = io.open(bin_path, "r")
    if file then
        file:close()
        return bin_path
    end
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

local function fetch_and_parse_epg_async()
    if state.epg_url == "" then return end
    mp.osd_message("正在后台下载 EPG 数据...", 3)
    mp.msg.warn("尝试使用 curl 下载 EPG")
    
    -- 构建可能的curl命令列表：先本地，后系统
    local curl_commands = {}
    local local_curl = get_curl_path()
    if local_curl then
        table.insert(curl_commands, local_curl)
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
                parse_epg_string(decompress_gzip_if_needed(res.stdout))
                mp.msg.warn(" curl 下载 EPG成功")
            else
                -- 失败，尝试下一个
                try_next(index + 1)
            end
        end)
    end
    
    try_next(1)
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
        mp.add_timeout(0.5, function()
            mp.commandv("loadfile", last_channel.url)
        end)
    end

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
                catchup_url = replace_catchup_time_params(catchup_url, prog.start_utc, prog.end_utc)
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
-- 返回值: menu_data, current_group_index, current_channel_index, current_has_epg, current_epg_index
local function build_main_menu()
    if not state.is_loaded then
        mp.osd_message("请先播放 M3U 文件！", 3)
        return nil
    end
    
    local items = {}
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
            local has_catchup = ch.catchup ~= "" and ch.catchup:find("%$%{")
            
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
            
            if has_epg then
                -- 有EPG数据：同时支持直接播放和 EPG 子菜单
                local hint_text = has_catchup and "回看▶" or "EPG"
                table.insert(channel_items, {
                    title = ch.name,
                    value = {"loadfile", ch.url},  -- 点击直接播放
                    icon = "live_tv",
                    hint = hint_text,
                    id = "channel_" .. ch.name,  -- 为频道添加ID
                    items = build_channel_epg_items(ch)  -- 右侧展开 EPG 子菜单
                })
            else
                -- 无EPG数据：频道直接播放
                table.insert(channel_items, {
                    title = ch.name,
                    value = {"loadfile", ch.url},
                    icon = "live_tv",
                    id = "channel_" .. ch.name  -- 为频道添加ID
                })
            end
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
        type = "iptv_menu",
        title = "IPTV",
        items = items,
        anchor_x = "left",
        anchor_offset = 20
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
        mp.add_timeout(0.1, function()
            if current_has_epg and current_epg_idx then
                -- 有EPG：展开EPG子菜单，并选中当前时间点的节目
                local channel_id = "channel_" .. state.current_channel.name
                mp.commandv("script-message-to", "uosc", "expand-submenu", channel_id)
                -- 延迟选中当前时间点的节目
                mp.add_timeout(0.15, function()
                    mp.commandv("script-message-to", "uosc", "select-menu-item", "iptv_menu", tostring(current_epg_idx), channel_id)
                end)
            else
                -- 无EPG：只选中频道，不展开子菜单，不进入直播
                mp.commandv("script-message-to", "uosc", "select-menu-item", "iptv_menu", tostring(current_channel_idx), submenu_id)
            end
        end)
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
                -- 只有当频道真正改变时才保存历史记录
                if not state.current_channel or state.current_channel.url ~= ch.url then
                    state.current_channel = ch
                    mp.msg.info("当前频道: " .. ch.name)
                    -- 保存到历史记录
                    save_current_channel_to_history()
                end
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
mp.msg.info("配置目录: " .. tostring(mp.find_config_file("") or "未找到"))
mp.msg.info("config-dir: " .. tostring(mp.get_property("config-dir", "未知")))
mp.msg.info("脚本目录: " .. tostring(mp.get_script_directory() or "未知"))
mp.msg.info("TEMP 环境变量: " .. tostring(os.getenv("TEMP") or "未设置"))
mp.msg.info("==========================")

-- 初始化：加载频道历史记录
load_channel_history()

-- 强制覆盖鼠标右键绑定，优先于 uosc 的暂停功能
mp.set_key_bindings({
    {'MBTN_RIGHT', show_iptv_menu}
}, 'MBTN_RIGHT', 'force')

