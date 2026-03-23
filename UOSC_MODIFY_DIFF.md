# uosc 5.12 定制版修改记录

> 本文档记录了本地定制的 uosc 5.12 与官方源码的差异，便于后续开发和维护。
>
> 官方源码：https://github.com/tomasklaen/uosc
> 基础版本：5.12.0

---

## 一、新增文件

### 1. `scripts/epg.lua` - IPTV EPG 回看脚本

**功能概述：**
完整的 IPTV 播放器扩展，支持 M3U 播放列表解析、EPG 节目单下载解析、四级滑动菜单选台、回看功能等。

**主要功能模块：**

| 模块     | 功能描述                                                   |
| -------- | ---------------------------------------------------------- |
| M3U 解析 | 解析 M3U/M3U8 文件，提取频道分组、名称、URL、Logo、EPG URL |
| EPG 下载 | 异步下载 EPG XML 数据，支持 gzip 压缩解压                  |
| 四级菜单 | 分组 → 频道 → 日期桶 → EPG节目单 的嵌套菜单结构         |
| 回看功能 | 支持多种时间模板替换（OK影视、酷9、APTV格式）              |
| 历史记录 | 自动保存/恢复上次播放的频道                                |

**新增消息接口：**

- 监听 `path` 属性变化自动加载 M3U
- 绑定 `F8` 打开 IPTV 菜单
- 绑定 `MBTN_RIGHT`（鼠标右键）根据上下文显示 IPTV 菜单或 uosc 默认菜单

**回看时间模板支持：**

```lua
-- 1. OK影视: ${utc:yyyyMMddHHmmss} / ${utcend:yyyyMMddHHmmss}
-- 2. 酷9: ${(b)yyyyMMddHHmmss|UTC} / ${(e)yyyyMMddHHmmss|UTC}
-- 3. APTV: ${(b)yyyyMMddHHmmss:utc} / ${(e)yyyyMMddHHmmss:utc}
```

**关键函数：**

- `parse_m3u(path)` - 解析 M3U 文件
- `fetch_and_parse_epg_async()` - 异步获取并解析 EPG
- `build_main_menu()` - 构建四级菜单数据结构
- `show_iptv_menu()` - 显示 IPTV 菜单
- `decompress_gzip_if_needed(data)` - gzip 解压（支持 Windows PowerShell 和 Linux gzip）

---

## 二、修改的 uosc 核心文件

### 1. `scripts/uosc/main.lua`

#### 修改点 1：新增消息处理器 `expand-submenu`

**位置：** 文件末尾消息处理器区域

**修改内容：**

```lua
-- 新增：展开子菜单（如果菜单已打开则只展开子菜单，不关闭）
mp.register_script_message('expand-submenu', function(id)
    local menu = Menu:is_open()
    if menu and id then
        menu:activate_menu(id)
    end
end)
```

**用途：** 供 `epg.lua` 使用，允许在菜单已打开的情况下动态展开指定子菜单（如展开当前频道所在的分组）。

#### 修改点 2：`open-menu` 消息处理器增强

**修改内容：** 支持 `anchor_x` 和 `anchor_offset` 参数

```lua
mp.register_script_message('open-menu', function(json, submenu_id)
    local data = utils.parse_json(json)
    if type(data) ~= 'table' or type(data.items) ~= 'table' then
        msg.error('open-menu: received json didn\'t produce a table with menu configuration')
    else
        open_command_menu(data, {
            submenu = submenu_id,
            on_close = data.on_close,
            anchor_x = data.anchor_x,        -- 新增
            anchor_offset = data.anchor_offset  -- 新增
        })
    end
end)
```

**用途：** 允许外部脚本通过 JSON 数据控制菜单位置（如左对齐、偏移量）。

---

### 2. `scripts/uosc/elements/Menu.lua`

#### 修改点 0：菜单项支持双行副标题（频道名下显示当前节目）

**位置：** 约第 1-20 行（类型定义）、约第 295-330 行（尺寸计算）、约第 1520-1745 行（菜单项绘制）

**修改原因：** IPTV 三折叠菜单需要像机顶盒一样，在频道名下方用更小一号的文字显示当前节目；后续又针对二级菜单宽度做了紧凑化处理，仅保留节目名。

**修改内容：**

1. **菜单项结构新增 `subtitle` 字段：**
```lua
---@alias MenuDataItem {title?: string; subtitle?: string; hint?: string; ...}
```

2. **尺寸计算支持双行文本：**
```lua
-- 【新增】如果菜单中存在 subtitle，则自动增大当前菜单实例的 item_height
local base_item_height = round(options.menu_item_height * state.scale)
self.font_size = round(base_item_height * 0.48 * options.font_scale)
self.font_size_subtitle = math.max(8, self.font_size - round(3 * state.scale))
self.subtitle_gap = round(2 * state.scale)
```

3. **菜单项绘制改为“标题 + 副标题”两行布局：**
```lua
-- 【新增】支持菜单项第二行副标题（用于 IPTV 当前节目）
if has_subtitle and subtitle_y then
    ass:txt(title_x, subtitle_y, align, item.ass_safe_subtitle, {
        size = self.font_size_subtitle,
        opacity = menu_opacity * 0.62,
    })
end
```

**用途：** 让 `epg.lua` 传入的频道副标题能在 `uosc` 菜单里以真正的第二行渲染，而不是把所有内容挤在一行里。

#### 修改点 0.0：菜单级副标题字号与最小宽度支持

**位置：** 约第 5-15 行（类型定义）、约第 295-360 行（尺寸计算与宽度计算）、约第 1550-1770 行（副标题绘制）

**修改原因：** IPTV 菜单需要在 `epg.conf` 内分别控制分级最小宽度，并可自定义二级/三级副标题字体大小。

**修改内容：**

1. **菜单结构新增字段：**
```lua
---@alias MenuData ... menu_min_width?: number; subtitle_font_size?: number; ...
```

2. **按菜单级别计算宽度：**
```lua
local custom_menu_min_width = tonumber(menu.menu_min_width)
if custom_menu_min_width and custom_menu_min_width > 0 then
    menu_min_width = math.min(round(custom_menu_min_width * state.scale), width_available)
end
menu.width = round(clamp(menu_min_width, width, width_available))
```

3. **按菜单级别计算副标题字号：**
```lua
local configured_subtitle_font_size = tonumber(menu.subtitle_font_size)
menu.subtitle_font_size_resolved = configured_subtitle_font_size and ... or self.font_size_subtitle
ass:txt(..., {size = subtitle_font_size})
```

**用途：** 让业务脚本能针对一级/二级/三级/四级菜单独立设置最小宽度，并控制副标题字号。

#### 修改点 0.1：移除默认子菜单右箭头

**位置：** 约第 188-200 行（菜单序列化初始化区域）

**修改原因：** IPTV 频道菜单做了极简化收口，希望去掉所有子菜单默认 `>` 箭头，只保留业务脚本显式指定的图标。

**修改内容：**

```lua
-- 【修改】移除所有子菜单默认右箭头，仅保留显式配置的图标
menu.icon = menu_data.icon
```

**用途：** 让所有菜单层级默认不再显示 `chevron_right`，减少视觉噪音并压缩右侧留白。

#### 修改点 0.2：悬停自动展开后，当前时段居中滚动

**位置：** 约第 730-770 行（`activate_selected_item` 子菜单展开分支）、约第 1595-1615 行（鼠标悬停自动展开分支）

**修改原因：** IPTV 三级 EPG 菜单在自动定位到“当前时段”后，还需要进一步把该项滚动到可视区域中间，避免定位项落在边缘不易观察。

**修改内容：**

```lua
-- 【新增】展开后将 selected_sub_index 对应项滚动到可视中间
if item.selected_sub_index then
    self:scroll_to_index(item.selected_sub_index, item.id, true)
end
```

**用途：** 鼠标滑过频道触发三级 EPG 自动展开时，当前时段会自动“选中 + 居中可见”，提升连续浏览体验。

#### 修改点 0.3：日期桶悬停交互与宽度稳定性增强

**位置：** 约第 5-20 行（类型定义）、约第 380-400 行（宽度计算）、约第 1590-1640 行（悬停交互）

**修改原因：** 四级菜单的日期桶列需要避免鼠标滑过时误选/误展开，并且要与四级 EPG 宽度变化解耦，保持列宽稳定。

**修改内容：**

1. **菜单项新增交互字段：**
```lua
---@alias MenuDataItem {...; no_hover_expand?: boolean; no_hover_select?: boolean; ...}
```

2. **父级悬停支持禁用选中/展开：**
```lua
and not (is_parent and item.no_hover_select)
```

3. **新增菜单级最大宽度字段并参与 clamp：**
```lua
local custom_menu_max_width = tonumber(menu.menu_max_width)
menu.width = round(clamp(menu_min_width, width, menu_max_width))
```

**用途：** 让日期桶列支持“仅点击切换”，并通过 `menu_max_width` 锁定列宽，避免随下级 EPG 内容抖动。

#### 修改点 1：搜索框绘制逻辑优化（EPG搜索优化）

**位置：** 约第 1795-1830 行（Query/Placeholder 绘制区域）

**修改原因：**
1. 光标位置默认在右侧，改为左对齐
2. 占位符文本改为左对齐显示
3. 输入文本时从左到右绘制

**修改内容：**

```lua
-- 【修改】光标初始位置对齐到搜索图标右侧（左对齐起点）
local cursor_ax = icon_rect.bx + self.item_padding
if menu.search.query ~= '' then
    -- ... opts 定义 ...
    local query, cursor = menu.search.query, menu.search.cursor
    -- Add a ZWNBSP suffix to prevent libass from trimming trailing spaces
    local head = ass_escape(string.sub(query, 1, cursor)) .. '\239\187\191'
    local tail_no_escape = string.sub(query, cursor + 1)
    local tail = ass_escape(tail_no_escape) .. '\239\187\191'
    -- 【修改】计算光标位置 = 起点 + head文本宽度
    cursor_ax = cursor_ax + text_width(head, opts)
    -- 【修改】左对齐绘制文本
    local text_x = icon_rect.bx + self.item_padding
    ass:txt(text_x, rect.cy, 4, head, opts)
    ass:txt(cursor_ax, rect.cy, 4, tail, opts)
else
    -- ... 占位符绘制 ...
    -- 【修改】光标和占位符都从左侧开始
    ass:txt(cursor_ax, rect.cy, 4, placeholder, {...})
end
```

#### 修改点 2：`search_items` 函数增强（支持 `search_key` 字段）

**位置：** 约第 877-920 行

**修改原因：** EPG 回看搜索需要只匹配节目标题，而不是完整的 "频道 | 时间 | 标题" 字符串

**修改内容：**

1. **构建搜索索引时优先使用 `search_key`：**
```lua
for _, item in ipairs(items) do
    if item.selectable ~= false then
        local prefixed_title = prefix and prefix .. ' / ' .. (item.title or '') or item.title
        -- 【修改】优先使用search_key进行搜索（如果存在），用于EPG回看搜索等场景
        haystacks[#haystacks + 1] = item.search_key or item.title
        flat_items[#flat_items + 1] = item
        -- ...
    end
end
```

2. **显示结果时使用完整标题并正确高亮：**
```lua
local fuzzy = fzy.filter(query, haystacks, false)
for _, match in ipairs(fuzzy) do
    local idx, positions, score = match[1], match[2], match[3]
    local matched_title = haystacks[idx]
    local item = flat_items[idx]
    -- ...
    -- 【修改】使用原始完整标题进行高亮显示，而不是matched_title（search_key）
    -- 如果item有search_key，需要将匹配位置映射到完整标题中
    local display_title = item.title or matched_title
    local ass_safe_title
    if item.search_key and item.search_key ~= display_title then
        -- 在search_key中匹配，需要找到search_key在display_title中的位置
        local search_key_pos = display_title:find(item.search_key, 1, true)
        if search_key_pos then
            -- 调整匹配位置到完整标题
            local adjusted_positions = {}
            for _, pos in ipairs(positions) do
                table.insert(adjusted_positions, pos + search_key_pos - 1)
            end
            ass_safe_title = highlight_match(display_title, adjusted_positions, font_color, bold) or nil
        else
            ass_safe_title = ass_escape(display_title)
        end
    else
        ass_safe_title = highlight_match(display_title, positions, font_color, bold) or nil
    end
    -- ...
end
```

**用途：** 实现 EPG 回看搜索功能——搜索时只匹配节目标题，但显示完整信息（频道 | 时间 | 标题）

#### 修改点 3：`activate_selected_item` 方法增强

**位置：** 约第 680-710 行

**原始逻辑：** 点击菜单项时，如果有子菜单则展开子菜单。

**修改后逻辑：** 优先执行 value（如果存在），同时保留子菜单可展开功能。

```lua
function Menu:activate_selected_item(shortcut, is_pointer)
    local menu = self.current
    local item = menu.items[menu.selected_index]
    if item then
        -- 【修改】优先执行 value（如果存在），否则展开子菜单
        if item.value then
            -- 有 value：执行命令（同时保留子菜单可展开功能）
            local actions = item.actions or menu.item_actions
            local action = actions and actions[menu.action_index]
            self.callback({
                type = 'activate',
                index = menu.selected_index,
                value = item.value,
                is_pointer = is_pointer == true,
                action = action and action.name,
                keep_open = item.keep_open or menu.keep_open,
                modifiers = shortcut and shortcut.modifiers or nil,
                alt = shortcut and shortcut.alt or false,
                ctrl = shortcut and shortcut.ctrl or false,
                shift = shortcut and shortcut.shift or false,
                menu_id = menu.id,
            })
        elseif item.items then
            -- 无 value 但有子菜单：展开子菜单
            if not self.mouse_nav then
                self:select_index(1, item.id)
            end
            self:activate_menu(item.id)
            self:tween(self.offset_x + menu.width / 2, 0, function(offset) self:set_offset_x(offset) end)
            self.opacity = 1
        end
    end
end
```

**用途：** 实现 IPTV 三级菜单的交互逻辑——点击频道直接播放（执行 value），同时可以展开右侧的 EPG 子菜单。

#### 修改点 4：键盘搜索输入可转发到指定菜单

**位置：** 约第 444 行、1080-1160 行（`get_menu` 附近及搜索输入处理区域）

**修改原因：** IPTV 菜单打开后会自动钻进当前 `EPG` 子菜单，用户希望保留这个视觉定位，但键盘输入仍然优先触发根菜单的“搜索频道”，而不是对子菜单执行搜索。

**修改内容：**

1. **新增 `get_search_target_menu()`：**
```lua
-- 【修改】允许子菜单将键盘搜索输入转发到指定菜单（例如 IPTV 根菜单搜索框）
function Menu:get_search_target_menu(menu_id)
    local menu = self:get_menu(menu_id)
    if not menu then return nil end

    local current = menu
    while current do
        local target_id = current.search_input_target
        if target_id == 'root' then return self.root end
        if type(target_id) == 'string' and self.by_id[target_id] then
            return self.by_id[target_id]
        end
        current = current.parent_menu
    end

    return menu
end
```

2. **修改 `search_text_input` / `search_query_backspace` / `search_query_delete`：**
```lua
-- 【修改】文本输入优先转发到指定搜索目标（例如 IPTV 根菜单搜索框）
local menu = self:get_search_target_menu()
if not menu or (not menu.search and menu.search_style == 'disabled') then return end

if not menu.search then self:search_start(menu.id) end
self:search_query_insert(key_text, menu.id)
```

**用途：** 让 IPTV 菜单在保留“自动展开当前 EPG 子菜单”的同时，用户一按键盘仍然直接进入根菜单的频道搜索。

---

### 3. `scripts/uosc/lib/menus.lua`

#### 修改点 1：`toggle_menu_with_items` 函数增强

**位置：** 文件开头

**修改内容：**

```lua
function toggle_menu_with_items(opts)
    -- 【修改】检查是否有任何菜单打开（而不仅仅是 'menu' 类型）
    if Menu:is_open() then
        Menu:close()
    else
        open_command_menu({type = 'menu', items = get_menu_items(), search_submenus = true}, opts)
    end
end
```

**原始代码：** `if Menu:is_open('menu') then`

**修改原因：** 确保任何类型的菜单（包括 IPTV 菜单）都能被正确关闭，避免菜单重叠。

---

## 三、文件结构对比

### 官方 uosc 5.12 结构

```
scripts/
└── uosc/
    ├── main.lua
    ├── lib/
    │   ├── ass.lua
    │   ├── buttons.lua
    │   ├── char_conv.lua
    │   ├── cursor.lua
    │   ├── fzy.lua
    │   ├── intl.lua
    │   ├── menus.lua
    │   ├── std.lua
    │   ├── text.lua
    │   └── utils.lua
    ├── elements/
    │   ├── BufferingIndicator.lua
    │   ├── Button.lua
    │   ├── Controls.lua
    │   ├── Curtain.lua
    │   ├── CycleButton.lua
    │   ├── Element.lua
    │   ├── Elements.lua
    │   ├── ManagedButton.lua
    │   ├── Menu.lua
    │   ├── PauseIndicator.lua
    │   ├── Speed.lua
    │   ├── Timeline.lua
    │   ├── TopBar.lua
    │   ├── Updater.lua
    │   ├── Volume.lua
    │   └── WindowBorder.lua
    └── bin/
        ├── ziggy-windows.exe
        ├── ziggy-linux
        └── ziggy-darwin
```

### 本地定制版结构

```
scripts/
├── epg.lua              # 【新增】IPTV EPG 脚本
├── thumbfast.lua        # 【新增】缩略图生成脚本
├── bin/
│   └── main.lua         # 【新增】curl 下载工具
└── uosc/
    ├── main.lua         # 【修改】新增消息处理器
    ├── lib/
    │   ├── menus.lua    # 【修改】toggle_menu_with_items 增强
    │   └── ...          # 其他未修改
    ├── elements/
    │   ├── Menu.lua     # 【修改】activate_selected_item 增强
    │   └── ...          # 其他未修改
    └── bin/
        └── ziggy-*      # 未修改
```

---

## 四、脚本交互关系图

```
┌─────────────────────────────────────────────────────────────┐
│                       mpv 播放器                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐         ┌───────────────────────────────┐ │
│  │  epg.lua     │         │   uosc (main.lua + Menu.lua)  │ │
│  │  (IPTV扩展)  │◄───────►│   (UI界面框架)                │ │
│  └──────────────┘         └───────────────────────────────┘ │
│         │                              │                    │
│         │ 1. 发送 open-menu            │                    │
│         │    消息(JSON格式)            │                    │
│         │─────────────────────────────►│                    │
│         │                              │                    │
│         │ 2. 发送 expand-submenu       │                    │
│         │    展开指定子菜单            │                    │
│         │─────────────────────────────►│                    │
│         │                              │                    │
│         │ 3. 监听 path 变化            │                    │
│         │    自动保存频道历史          │                    │
│         │◄─────────────────────────────│                    │
│         │                              │                    │
│  ┌──────▼──────────────────────────────▼────────────────┐   │
│  │                   M3U/EPG 数据处理                     │   │
│  │  - M3U解析 (分组/频道/URL/Logo/EPG地址)               │   │
│  │  - EPG下载 (XMLTV格式, gzip解压)                      │   │
│  │  - 回看URL生成 (时间模板替换)                         │   │
│  │  - 频道历史记录 (JSON持久化)                          │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐   │
│  │                   四级滑动菜单结构                      │   │
│  │                                                       │   │
│  │   分组 (Group) ──► 频道 (Channel) ──► 日期桶 ──► EPG  │   │
│  │        │                  │                │          │   │
│  │   ┌────┴────┐        ┌───┴───┐      ┌─────┴─────┐    │   │
│  │   │央视     │        │CCTV1  │      │回看 08:00 │    │   │
│  │   │卫视     │        │CCTV2  │      │回看 09:00 │    │   │
│  │   │地方     │        │...    │      │正在直播   │    │   │
│  │   └─────────┘        └───────┘      └───────────┘    │   │
│  │                                                       │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 五、API 接口说明

### uosc 提供的新消息接口

| 消息名称           | 参数                     | 说明                         |
| ------------------ | ------------------------ | ---------------------------- |
| `open-menu`      | `json`, `submenu_id` | 打开自定义菜单，支持锚点位置 |
| `expand-submenu` | `id`                   | 展开指定 ID 的子菜单         |

### epg.lua 使用的 uosc 接口

| 接口类型 | 名称                                      | 用途             |
| -------- | ----------------------------------------- | ---------------- |
| 消息发送 | `script-message-to uosc open-menu`      | 打开 IPTV 菜单   |
| 消息发送 | `script-message-to uosc expand-submenu` | 展开当前频道分组 |
| 属性监听 | `observe_property("path")`              | 跟踪播放频道变化 |
| 命令执行 | `mp.commandv("loadfile", url)`          | 播放频道/回看    |

---

## 六、配置说明

### epg.lua 配置选项

在 `script-opts/epg.conf` 中配置：

```ini
# EPG 下载地址（可选，优先使用 M3U 中的 x-tvg-url）
epg_download_url=
```

### input.conf 绑定示例

```ini
# F8 打开 IPTV 菜单
F8 script-binding epg/show-iptv-menu

# 鼠标右键（已自动绑定）
# MBTN_RIGHT script-binding epg/show-iptv-menu-mouse
```

---

## 七、关键修改代码对比

### 1. Menu.lua - activate_selected_item

**官方版本：**

```lua
function Menu:activate_selected_item(shortcut, is_pointer)
    local menu = self.current
    local item = menu.items[menu.selected_index]
    if item then
        local actions = item.actions or menu.item_actions
        local action = actions and actions[menu.action_index]
        self.callback({...})
    end
end
```

**定制版本：**

```lua
function Menu:activate_selected_item(shortcut, is_pointer)
    local menu = self.current
    local item = menu.items[menu.selected_index]
    if item then
        -- 【修改点】优先执行 value，否则展开子菜单
        if item.value then
            -- 执行命令
            local actions = item.actions or menu.item_actions
            local action = actions and actions[menu.action_index]
            self.callback({...})
        elseif item.items then
            -- 展开子菜单
            if not self.mouse_nav then
                self:select_index(1, item.id)
            end
            self:activate_menu(item.id)
            self:tween(self.offset_x + menu.width / 2, 0, function(offset) self:set_offset_x(offset) end)
            self.opacity = 1
        end
    end
end
```

---

## 八、后续开发建议

### 1. 升级 uosc 时的注意事项

1. **保留修改标记**：在新版本中找到对应位置，重新应用标记为 `【修改】` 的代码段
2. **检查 API 兼容性**：uosc 6.x 可能有重大变更，需验证 `open-menu` 和 `expand-submenu` 接口
3. **测试 EPG 功能**：升级后验证四级菜单、回看功能是否正常

### 2. 可扩展功能

| 功能      | 实现思路                                      |
| --------- | --------------------------------------------- |
| 收藏频道  | 在 epg.lua 中添加 favorites 表，持久化到 JSON |
| 节目搜索  | 在 EPG 菜单中添加搜索框，过滤节目单           |
| 多 EPG 源 | 支持配置多个 EPG URL，合并数据                |
| 节目提醒  | 定时检查即将开始的节目，显示 OSD 通知         |

### 3. 调试方法

```lua
-- 在 epg.lua 中开启详细日志
-- 查看 mpv 控制台输出：按 ` 键（反引号）
mp.msg.info("调试信息")
mp.msg.warn("警告信息")
mp.msg.error("错误信息")

-- 显示 OSD 消息
mp.osd_message("提示信息", 3)  -- 显示3秒
```

---

## 九、版本历史

| 版本   | 日期       | 修改内容                                                     |
| ------ | ---------- | ------------------------------------------------------------ |
| V1.6.2 | 2026-03-23 | 日期桶升级为 7 桶动态显示；修复悬停联动与点击两次展开；新增 `menu_max_width` 并锁定三级日期桶宽度；修复频道搜索崩溃与拼音多音字映射不稳定 |
| V1.6.1 | 2026-03-23 | 菜单升级为四级结构（分组 > 频道 > 日期桶 > EPG）；新增 `menu_level4_min_width`；非预构建日期桶改为同树内惰性展开 |
| V1.6   | 2026-03-23 | 支持 `epg.conf` 分级菜单最小宽度与副标题字号配置；三级 EPG 菜单改为标题+副标题（日期时间）模式 |
| V1.5   | 2026-03-23 | 新增频道当前节目双行副标题，并完成 IPTV 菜单极简化（去时间、去 `回看/EPG`、去 `folder`、去默认 `>` 箭头） |
| V1.4   | 2026-03-21 | 新增 IPTV 菜单频道搜索（中文/拼音/首字母），并让自动展开的 EPG 子菜单将键盘搜索转发到根菜单 |
| V1.3   | 2026-03-21 | 新增 EPG 回看搜索菜单 (F9)，搜索框光标左对齐优化，`search_key` 支持 |
| V1.2   | 2026-03-20 | 三级滑动菜单结构重构，新增频道历史记忆，EPG回看功能完善      |
| V1.1   | -          | 初始版本，基础 M3U/EPG 支持                                  |

---

*文档生成时间：2026-03-23*
*基于 uosc 5.12.0 定制*
