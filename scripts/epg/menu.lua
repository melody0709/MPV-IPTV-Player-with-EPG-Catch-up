--[[
    menu.lua - 菜单层
    包含：4级菜单构建（分组 > 频道 > 日期桶 > EPG）、菜单更新、搜索、回看搜索菜单
]]

local mp = require 'mp'
local utils = require 'mp.utils'

-- ==================== 辅助函数 ====================

function apply_channel_item_menu_layout(channel_item, menu_level3_min_width, menu_level4_min_width, menu_subtitle_font_size)
    if not channel_item or not channel_item.items then
        return
    end

    if menu_level3_min_width then
        channel_item.menu_min_width = menu_level3_min_width
        channel_item.menu_max_width = menu_level3_min_width
    end
    if menu_subtitle_font_size then
        channel_item.subtitle_font_size = menu_subtitle_font_size
    end

    for _, date_bucket_item in ipairs(channel_item.items) do
        if date_bucket_item.items and menu_level4_min_width then
            date_bucket_item.menu_min_width = menu_level4_min_width
        end
    end
end

function find_menu_group_item(menu_data, group_name)
    if not menu_data or not menu_data.items or not group_name then
        return nil
    end

    local target_id = "group_" .. group_name
    for _, item in ipairs(menu_data.items) do
        if item and item.id == target_id then
            return item
        end
    end

    return nil
end

function update_cached_menu_channel_item(channel_url, bucket_key, reference_utc)
    local menu_data = state.last_iptv_menu_data
    if not menu_data then
        return nil, nil, nil
    end

    local group_name, channel_index = find_channel_position_by_url(channel_url)
    if not group_name or not channel_index then
        return nil, nil, nil
    end

    local group_item = find_menu_group_item(menu_data, group_name)
    local ch = get_channel_by_position(group_name, channel_index)
    if not group_item or not group_item.items or not ch then
        return nil, nil, nil
    end

    local menu_active_channel = get_menu_active_channel()
    local now_utc = current_utc_string()
    local effective_reference_utc = reference_utc or get_menu_reference_utc_for_channel(ch, menu_active_channel, now_utc)
    local channel_item = build_channel_menu_item(
        group_name,
        channel_index,
        ch,
        effective_reference_utc,
        menu_active_channel and menu_active_channel.url == ch.url,
        bucket_key
    )
    apply_channel_item_menu_layout(
        channel_item,
        get_positive_integer_option(options.menu_level3_min_width),
        get_positive_integer_option(options.menu_level4_min_width),
        get_positive_integer_option(options.menu_subtitle_font_size)
    )
    group_item.items[channel_index] = channel_item
    return menu_data, ch, channel_item
end

function build_channel_now_playing_subtitle(ch, now_utc)
    local prog = get_current_program_for_channel(ch, now_utc)
    if not prog then
        return nil
    end

    return prog.title
end

local function build_date_bucket_id(ch, bucket_key)
    return "date_" .. (ch.name or "unknown") .. "_" .. bucket_key
end

-- ==================== 工具栏菜单项 ====================

function build_utility_menu_items()
    return {
        {
            title = "EPG 回看搜索",
            value = {"script-binding", "epg/show-epg-search-menu"},
            hint = "F9",
            icon = "manage_search"
        }
    }
end

-- ==================== 4 级菜单构建 ====================

-- Level 4: 单个日期桶内的 EPG 节目列表
build_channel_epg_items = function(ch, programs)
    local epg_items = {}
    local epg_list = programs or state.epg_data[ch.tvg_id]

    if epg_list and #epg_list > 0 then
        -- 回看资格判定延迟 2 分钟，兼容节目整点刚开始时的回看源稳定性
        local catchup_ready_utc = catchup_ready_utc_string()
        for _, prog in ipairs(epg_list) do
            local epg_subtitle = prog.display_start
            if prog.display_end and prog.display_end ~= "" then
                epg_subtitle = epg_subtitle .. " - " .. prog.display_end
            end

            if ch.catchup ~= "" and ch.catchup:find("%$%{") and prog.start_utc ~= "" and prog.end_utc ~= "" and prog.start_utc <= catchup_ready_utc then
                -- 延迟生成回看 URL：菜单构建阶段只传模板和时间参数，点击时再计算实际 URL
                table.insert(epg_items, {
                    title = prog.title,
                    subtitle = epg_subtitle,
                    value = {"script-message-to", "epg", "play-catchup",
                        "", ch.catchup, prog.start_utc, prog.end_utc, ch.url}
                })
            else
                table.insert(epg_items, {
                    title = prog.title,
                    subtitle = epg_subtitle,
                    value = {"script-message-to", "epg", "play-live-channel", ch.url, "yes"},
                    muted = true
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

-- Level 3: 单个频道的日期桶列表
build_channel_date_bucket_items = function(ch, reference_utc, preload_bucket_keys)
    local bucket_items = {}
    local bucket_data = get_channel_bucket_data(ch)
    local active_bucket_key = get_bucket_key_for_utc(reference_utc)
    local active_bucket_idx = nil
    local active_epg_idx = nil

    if not bucket_data then
        return bucket_items, active_bucket_idx, active_epg_idx, active_bucket_key
    end

    local preload = preload_bucket_keys or {}
    for _, bucket_key in ipairs(DATE_BUCKET_ORDER) do
        local bucket = bucket_data[bucket_key]
        local programs = bucket and bucket.programs or nil
        if programs and #programs > 0 then
            local bucket_item = {
                title = bucket.label,
                subtitle = bucket.subtitle,
                id = build_date_bucket_id(ch, bucket_key),
                no_hover_expand = true,
                no_hover_select = true
            }

            if preload[bucket_key] then
                bucket_item.items = build_channel_epg_items(ch, programs)

                if bucket_key == active_bucket_key then
                    local _, current_prog_index = get_current_program_from_list(programs, reference_utc)
                    if current_prog_index then
                        active_epg_idx = current_prog_index + 1
                    elseif #bucket_item.items >= 2 then
                        active_epg_idx = 2
                    end

                    if active_epg_idx then
                        bucket_item.selected_sub_index = active_epg_idx
                    end
                end
            else
                bucket_item.value = {
                    "script-message-to", "epg", "open-channel-date-bucket",
                    ch.url,
                    bucket_key,
                    reference_utc or ""
                }
                bucket_item.keep_open = true
            end

            table.insert(bucket_items, bucket_item)
            if bucket_key == active_bucket_key then
                active_bucket_idx = #bucket_items
            end
        end
    end

    if not active_bucket_idx and #bucket_items > 0 then
        active_bucket_idx = 1
    end

    return bucket_items, active_bucket_idx, active_epg_idx, active_bucket_key
end

-- Level 2: 单个频道菜单项（含子菜单）
build_channel_menu_item = function(group_name, channel_index, ch, now_utc, is_current_channel, forced_preload_bucket_key)
    local has_epg = state.epg_data[ch.tvg_id] and #state.epg_data[ch.tvg_id] > 0
    local current_program_subtitle = build_channel_now_playing_subtitle(ch, now_utc)

    local item = {
        title = ch.name,
        subtitle = current_program_subtitle,
        search_key = ch.name,
        value = {"script-message-to", "epg", "play-live-channel", ch.url, "yes", group_name, tostring(channel_index)},
        id = "channel_" .. ch.name,
    }

    local menu_meta = {
        has_epg = false,
        active_bucket_key = nil,
        active_bucket_idx = nil,
        active_epg_idx = nil
    }

    if has_epg then
        local preload_bucket_keys = {today = true}
        local active_bucket_key = get_bucket_key_for_utc(now_utc)
        if is_current_channel then
            preload_bucket_keys[active_bucket_key] = true
        end
        if forced_preload_bucket_key then
            preload_bucket_keys[forced_preload_bucket_key] = true
        end

        local bucket_items, active_bucket_idx, active_epg_idx = build_channel_date_bucket_items(ch, now_utc, preload_bucket_keys)
        if #bucket_items > 0 then
            item.items = bucket_items
            if active_bucket_idx then
                item.selected_sub_index = active_bucket_idx
            end
        end

        menu_meta.has_epg = #bucket_items > 0
        menu_meta.active_bucket_key = active_bucket_key
        menu_meta.active_bucket_idx = active_bucket_idx
        menu_meta.active_epg_idx = active_epg_idx
    end

    return item, menu_meta
end

-- Level 1 (root): 工具栏 + 频道分组标题
local function build_iptv_root_items()
    local items = {}
    local utility_items = build_utility_menu_items()
    for _, utility_item in ipairs(utility_items) do
        table.insert(items, utility_item)
    end

    return items
end

-- ==================== 搜索 ====================

local function build_channel_search_items(query)
    local items = {}
    local normalized_query = trim(query or ""):lower()
    local now_utc = current_utc_string()

    if normalized_query == "" then
        return nil
    end

    for _, group_name in ipairs(state.group_names) do
        local channels = state.groups[group_name]
        for channel_index, ch in ipairs(channels) do
            if ch.name and channel_name_matches_query(ch.name, normalized_query) then
                local channel_item = build_channel_menu_item(group_name, channel_index, ch, now_utc)
                table.insert(items, channel_item)
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

function update_iptv_menu_items(items)
    local menu_level2_min_width = get_positive_integer_option(options.menu_level2_min_width)
    local menu_subtitle_font_size = get_positive_integer_option(options.menu_subtitle_font_size)

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

    if menu_level2_min_width then
        menu_data.menu_min_width = menu_level2_min_width
    end
    if menu_subtitle_font_size then
        menu_data.subtitle_font_size = menu_subtitle_font_size
    end

    mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(menu_data))
end

function handle_iptv_channel_search(query)
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

-- ==================== 主菜单（四级嵌套） ====================

-- 返回值: menu_data, current_group_index, current_channel_index, current_has_epg, current_bucket_id, current_epg_index
build_main_menu = function(preload_target)
    if not state.is_loaded then
        mp.osd_message("请先播放 M3U 文件！", 3)
        return nil
    end

    local items = build_iptv_root_items()
    local current_group_idx = nil
    local current_channel_idx = nil
    local current_has_epg = false
    local current_bucket_id = nil
    local current_epg_idx = nil
    local menu_active_channel = get_menu_active_channel()
    local now_utc = current_utc_string()
    local menu_subtitle_font_size = get_positive_integer_option(options.menu_subtitle_font_size)
    local menu_level1_min_width = get_positive_integer_option(options.menu_level1_min_width)
    local menu_level2_min_width = get_positive_integer_option(options.menu_level2_min_width)
    local menu_level3_min_width = get_positive_integer_option(options.menu_level3_min_width)
    local menu_level4_min_width = get_positive_integer_option(options.menu_level4_min_width)

    for group_idx, group_name in ipairs(state.group_names) do
        local channels = state.groups[group_name]
        local channel_items = {}

        for channel_idx, ch in ipairs(channels) do
            -- 判断是否为当前播放频道
            local is_current = menu_active_channel and menu_active_channel.url == ch.url
            local reference_utc = get_menu_reference_utc_for_channel(ch, menu_active_channel, now_utc)
            if is_current then
                current_group_idx = group_idx
                current_channel_idx = channel_idx
            end

            local forced_preload_bucket_key = nil
            if preload_target and preload_target.channel_url == ch.url then
                forced_preload_bucket_key = preload_target.bucket_key
            end

            local channel_item, channel_meta = build_channel_menu_item(group_name, channel_idx, ch, reference_utc, is_current, forced_preload_bucket_key)
            if is_current and channel_meta and channel_meta.has_epg then
                current_has_epg = true
                if channel_meta.active_bucket_key then
                    current_bucket_id = build_date_bucket_id(ch, channel_meta.active_bucket_key)
                end
                current_epg_idx = channel_meta.active_epg_idx
            end

            table.insert(channel_items, channel_item)
        end

        local group_item = {
            title = group_name,
            hint = #channels .. " 频道",
            bold = true,
            id = "group_" .. group_name,
            items = channel_items  -- 嵌套频道列表
        }
        if menu_level2_min_width then
            group_item.menu_min_width = menu_level2_min_width
        end
        if menu_subtitle_font_size then
            group_item.subtitle_font_size = menu_subtitle_font_size
        end

        table.insert(items, group_item)
    end

    if menu_level3_min_width or menu_level4_min_width or menu_subtitle_font_size then
        for _, group_item in ipairs(items) do
            if group_item.items then
                for _, channel_item in ipairs(group_item.items) do
                    if channel_item.items then
                        if menu_level3_min_width then
                            channel_item.menu_min_width = menu_level3_min_width
                            channel_item.menu_max_width = menu_level3_min_width
                        end
                        if menu_subtitle_font_size then
                            channel_item.subtitle_font_size = menu_subtitle_font_size
                        end

                        for _, date_bucket_item in ipairs(channel_item.items) do
                            if date_bucket_item.items then
                                if menu_level4_min_width then
                                    date_bucket_item.menu_min_width = menu_level4_min_width
                                end
                            end
                        end
                    end
                end
            end
        end
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

    if menu_level1_min_width then
        menu_data.menu_min_width = menu_level1_min_width
    end
    if menu_subtitle_font_size then
        menu_data.subtitle_font_size = menu_subtitle_font_size
    end

    state.last_iptv_menu_data = menu_data

    return menu_data, current_group_idx, current_channel_idx, current_has_epg, current_bucket_id, current_epg_idx
end

-- ==================== 菜单入口 ====================

function show_iptv_menu()
    local menu_data, current_group_idx, current_channel_idx, current_has_epg, current_bucket_id, current_epg_idx = build_main_menu()
    if not menu_data then return end
    local menu_active_channel = get_menu_active_channel()

    -- 确定要展开的分组ID
    local submenu_id = nil
    if menu_active_channel and menu_active_channel.group then
        submenu_id = "group_" .. menu_active_channel.group
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
    if current_group_idx and current_channel_idx and menu_active_channel then
        -- 延迟一点执行，确保菜单已经渲染
        mp.add_timeout(MENU_RENDER_DELAY, function()
            if current_has_epg and current_bucket_id then
                -- 有EPG：展开频道 -> 日期桶 -> 当前节目
                local channel_id = "channel_" .. menu_active_channel.name

                -- 长频道列表场景下，先选中频道触发滚动，再展开四级菜单，避免目标项未渲染导致定位失败。
                if submenu_id then
                    mp.commandv("script-message-to", "uosc", "select-menu-item", "iptv_menu", tostring(current_channel_idx), submenu_id)
                end
                mp.commandv("script-message-to", "uosc", "expand-submenu", channel_id)

                mp.add_timeout(MENU_EXPAND_DELAY, function()
                    mp.commandv("script-message-to", "uosc", "expand-submenu", current_bucket_id)
                    if current_epg_idx then
                        mp.add_timeout(MENU_SELECT_DELAY, function()
                            mp.commandv("script-message-to", "uosc", "select-menu-item", "iptv_menu", tostring(current_epg_idx), current_bucket_id)
                        end)
                    end
                end)
            else
                -- 无EPG：只选中频道，不展开子菜单，不进入直播
                mp.commandv("script-message-to", "uosc", "select-menu-item", "iptv_menu", tostring(current_channel_idx), submenu_id)
            end
        end)
    end
end

function show_channel_date_bucket_menu(channel_url, bucket_key, reference_utc)
    local ch = find_channel_by_url(channel_url)
    if not ch then
        return
    end

    local bucket_data = get_channel_bucket_data(ch)
    local bucket = bucket_data and bucket_data[bucket_key] or nil
    if not bucket or not bucket.programs or #bucket.programs == 0 then
        return
    end

    local refreshed_menu_data, refreshed_channel = update_cached_menu_channel_item(channel_url, bucket_key, reference_utc)
    if not refreshed_menu_data then
        refreshed_menu_data = build_main_menu({
            channel_url = channel_url,
            bucket_key = bucket_key
        })
        if not refreshed_menu_data then
            return
        end
    end

    mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(refreshed_menu_data))

    ch = refreshed_channel or ch
    local channel_id = "channel_" .. ch.name
    local bucket_id = build_date_bucket_id(ch, bucket_key)

    mp.add_timeout(MENU_RENDER_DELAY, function()
        -- 先确保频道层已激活，再展开日期桶，避免 group -> channel 的往返切换抖动。
        mp.commandv("script-message-to", "uosc", "expand-submenu", channel_id)
        mp.add_timeout(MENU_EXPAND_DELAY, function()
            mp.commandv("script-message-to", "uosc", "expand-submenu", bucket_id)

            local _, active_prog_index = get_current_program_from_list(bucket.programs, reference_utc)
            if active_prog_index then
                local selected_index = active_prog_index + 1
                mp.add_timeout(MENU_SELECT_DELAY, function()
                    mp.commandv("script-message-to", "uosc", "select-menu-item", "iptv_menu", tostring(selected_index), bucket_id)
                end)
            end
        end)
    end)
end

-- ==================== EPG 回看搜索菜单 (F9) ====================

-- 构建回看 EPG 搜索菜单（显示所有可回看的节目，按时间倒序排列）
function build_catchup_epg_menu()
    if not state.is_loaded then
        mp.osd_message("请先播放 M3U 文件！", 3)
        return nil
    end

    local temp_items = {}  -- 临时存储，包含排序键
    -- EPG 搜索菜单与三级菜单保持一致：节目开始 2 分钟后才显示为可回看
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
                        -- 只显示开始时间早于当前时间 2 分钟的节目（可以回看）
                        if prog.start_utc <= catchup_ready_utc then
                            local catchup_url = ch.catchup
                            -- 不在此处生成完整 URL，延迟到点击时生成
                            local display_text = string.format("%s | %s | %s",
                                ch.name, prog.display_start, prog.title)

                            table.insert(temp_items, {
                                start_utc = prog.start_utc,
                                menu_item = {
                                    title = display_text,
                                    search_key = prog.title,  -- 只用于搜索的EPG标题
                                    value = {"script-message-to", "epg", "play-catchup",
                                        "", ch.catchup, prog.start_utc, prog.end_utc, ch.url},
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
        return a.start_utc > b.start_utc
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

function show_epg_search_menu()
    local menu_data = build_catchup_epg_menu()
    if not menu_data then return end

    -- 强制启用输入法，解决中文输入法第一个字符输入英文的问题
    mp.set_property_bool("input-ime", true)

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data))
end
