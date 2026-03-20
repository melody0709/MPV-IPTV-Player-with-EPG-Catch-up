# uosc 5.12 定制版修改记录

> 本文档记录了本地定制的 uosc 5.12 与官方源码的差异，便于后续开发和维护。
>
> 官方源码：https://github.com/tomasklaen/uosc
> 基础版本：5.12.0

---

## 一、新增文件

### 1. `scripts/epg.lua` - IPTV EPG 回看脚本

**功能概述：**
完整的 IPTV 播放器扩展，支持 M3U 播放列表解析、EPG 节目单下载解析、三级滑动菜单选台、回看功能等。

**主要功能模块：**

| 模块     | 功能描述                                                   |
| -------- | ---------------------------------------------------------- |
| M3U 解析 | 解析 M3U/M3U8 文件，提取频道分组、名称、URL、Logo、EPG URL |
| EPG 下载 | 异步下载 EPG XML 数据，支持 gzip 压缩解压                  |
| 三级菜单 | 分组 → 频道 → EPG节目单 的嵌套菜单结构                   |
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
- `build_main_menu()` - 构建三级菜单数据结构
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

#### 修改点 1：`activate_selected_item` 方法增强

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
│  │                   三级滑动菜单结构                      │   │
│  │                                                       │   │
│  │   分组 (Group) ──► 频道 (Channel) ──► EPG节目单       │   │
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
3. **测试 EPG 功能**：升级后验证三级菜单、回看功能是否正常

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

| 版本 | 日期    | 修改内容                              |
| ---- | ------- | ------------------------------------- |
| V1.2 | 2026-03 | 三级滑动菜单结构重构，EPG回看功能完善 |
| V1.1 | -       | 初始版本，基础 M3U/EPG 支持           |

---

*文档生成时间：2026-03-20*
*基于 uosc 5.12.0 定制*
