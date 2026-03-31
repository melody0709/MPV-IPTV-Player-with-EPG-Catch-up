--[[
    playback.lua - 播放控制层
    包含：URL加载、直播播放、HLS重试、上下频道切换
    回看相关的 get_catchup_reference_utc / get_menu_reference_utc_for_channel 也在此
]]

local mp = require 'mp'

-- ==================== URL 加载 ====================

local function clone_load_options(file_options)
    if not file_options then
        return nil
    end

    local result = {}
    for key, value in pairs(file_options) do
        result[key] = value
    end
    return result
end

local function dispatch_loadfile(playback_url, load_mode, file_options)
    local effective_mode = load_mode or "replace"

    if file_options then
        mp.command_native({"loadfile", playback_url, effective_mode, -1, file_options})
        return
    end

    mp.commandv("loadfile", playback_url, effective_mode)
end

function should_force_hls_for_iptv_url(url)
    if not url or not url:match("^https?://") then
        return false
    end

    local path = url:match("^https?://[^/]+(.-)$") or ""
    path = path:match("^[^?#]*") or path
    path = path:lower()

    if path:match("^/rtp/") or path:match("^/udp/") then
        return false
    end

    if path == "" or path == "/" or path:sub(-1) == "/" then
        return true
    end

    if path:match("%.m3u8$")
        or path:match("%.mpd$")
        or path:match("%.ts$")
        or path:match("%.m2ts$")
        or path:match("%.mp4$")
        or path:match("%.mkv$")
        or path:match("%.webm$")
        or path:match("%.mov$")
        or path:match("%.avi$")
        or path:match("%.flv$")
        or path:match("%.mp3$")
        or path:match("%.aac$")
        or path:match("%.ogg$")
        or path:match("%.opus$")
        or path:match("%.wav$") 
        or path:match("%.php$")  -- ★ 新增：PHP 动态脚本不强制 HLS
        or path:match("%.jsp$")  -- ★ 新增：JSP 动态脚本
        or path:match("%.asp$")  -- ★ 新增：ASP 动态脚本
        then
        return false
    end

    return true
end

function load_iptv_url(url, context, allow_hls_retry, force_hls, load_mode, file_options)
    local playback_url = trim(url)
    if playback_url == "" then
        return false
    end

    if state.last_played_url ~= playback_url then
        state.error_retry_count = 0
        state.last_played_url = playback_url
    end

    local effective_mode = load_mode or "replace"

    cancel_pending_hls_retry_timer()

    if state.known_hls_urls and state.known_hls_urls[playback_url] then
        force_hls = true
        mp.msg.info("命中 HLS 缓存，直接使用 HLS 模式: " .. playback_url)
    end

    if force_hls then
        state.pending_hls_retry = nil
        local hls_options = clone_load_options(file_options) or {}
        hls_options["demuxer-lavf-format"] = "hls"
        if state.known_hls_urls and state.known_hls_urls[playback_url] then
            mp.msg.info(string.format("IPTV HLS加速: %s %s", context or "unknown", playback_url))
        else
            mp.msg.info(string.format("IPTV HLS兼容: %s 默认打开失败，改用 HLS 重试 %s", context or "unknown", playback_url))
        end
        dispatch_loadfile(playback_url, effective_mode, hls_options)
        return true
    end

    if allow_hls_retry ~= false and should_force_hls_for_iptv_url(playback_url) then
        state.pending_hls_retry = {
            url = playback_url,
            context = context or "unknown",
            load_mode = effective_mode,
            file_options = clone_load_options(file_options)
        }
    else
        state.pending_hls_retry = nil
    end

    dispatch_loadfile(playback_url, effective_mode, file_options)
    return true
end

-- ==================== 直播播放 ====================

function play_live_channel(channel, show_osd, group_name, channel_index)
    if not channel or not channel.url or channel.url == "" then
        return false
    end

    set_current_catchup_state(nil, nil)

    if group_name and channel_index then
        set_selected_channel_position(group_name, channel_index)
    else
        local resolved_group_name, resolved_channel_index = find_channel_position_by_url(channel.url)
        set_selected_channel_position(resolved_group_name, resolved_channel_index)
    end

    local channel_changed = not state.current_channel or state.current_channel.url ~= channel.url
    set_current_channel_state(channel)

    if channel_changed then
        mp.msg.info("当前频道: " .. channel.name)
        if not state.auto_playing then
            save_current_channel_to_history()
        end
    end

    if show_osd then
        show_top_center_osd(channel.name, 2)
    end

    return load_iptv_url(channel.url, "live-channel")
end

-- ==================== 回看参考时间 ====================

function get_catchup_reference_utc()
    if not state.current_catchup or not state.current_catchup.start_utc then
        return nil
    end

    local start_ts = utc_str_to_timestamp(state.current_catchup.start_utc)
    if not start_ts then
        return nil
    end

    local time_pos = state.current_time_pos
    if not time_pos or time_pos < 0 then
        time_pos = 0
    end

    return to_utc_string(start_ts + math.floor(time_pos))
end

function get_menu_reference_utc_for_channel(ch, menu_active_channel, default_utc)
    if not ch or not menu_active_channel then
        return default_utc
    end

    if state.current_catchup and menu_active_channel.url == ch.url then
        local catchup_utc = get_catchup_reference_utc()
        if catchup_utc then
            return catchup_utc
        end
    end

    return default_utc
end

-- ==================== 组内频道切换 ====================

-- 支持 PageUp/PageDown 在当前频道组内切换直播频道，回看场景下不响应。
function switch_channel_in_current_group(direction)
    if state.current_catchup then
        mp.osd_message("回看中不支持组内切台", 2)
        return
    end

    local current_group_name = state.selected_group_name
    local current_index = state.selected_channel_index

    if not current_group_name or not current_index then
        local current_channel = get_menu_active_channel()
        if not current_channel or not current_channel.group then
            return
        end
        current_group_name, current_index = find_channel_position_by_url(current_channel.url)
    end

    if not current_group_name or not current_index then
        return
    end

    local group_channels = state.groups[current_group_name]
    if not group_channels or #group_channels == 0 then
        return
    end

    local target_index = current_index + direction
    if target_index < 1 or target_index > #group_channels then
        return
    end

    local target_channel = group_channels[target_index]
    if not target_channel or not target_channel.url or target_channel.url == "" then
        return
    end

    play_live_channel(target_channel, true, current_group_name, target_index)
end
