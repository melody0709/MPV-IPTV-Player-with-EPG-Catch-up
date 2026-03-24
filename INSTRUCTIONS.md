# CLAUDE.md - mpv + uosc IPTV 播放器开发指南

本文档为 AI 开发助手提供关于此 mpv + uosc 5.12 定制版 IPTV 播放器的项目背景、开发规范和注意事项。

## 项目概述

基于 **mpv 播放器** 和 **uosc 5.12 UI 框架** 深度定制的 IPTV 播放器，专为直播电视和回看功能设计。

## 核心功能

- **四级滑动菜单 + 频道搜索**：`F8` 顶部搜索框只匹配频道名，不会匹配 EPG 时间或节目标题；菜单结构为 分组 > 频道 > 日期桶 > EPG，日期桶支持 明天 / 今天 / 昨天 / 星期X（附月日副标题）；搜索支持中文、拼音全拼和首字母，如 `广东` / `guangdong` / `gd`、`东莞` / `dongguan` / `dg`
- **组内快速切台 (PgUp / PgDn / uosc 上一台下一台按钮)**：直播时可在当前频道组内切到上一台/下一台，行为与鼠标点选频道一致；切台后 OSD 会在视频顶部居中显示当前频道名；回看状态下不执行切台，只显示提示
- **顶部频道上下文**：鼠标移动到视频顶部时，`uosc` 顶部悬浮标题除原有播放地址/标题外，还会在同一行后方显示当前频道组与频道名
- **EPG 回看**：支持 XMLTV 格式节目单，时间跳转回看功能
- **EPG 回看搜索 (F9)**：跨频道搜索所有可回看的节目，按时间倒序排列
- **手动强制刷新 EPG (Shift+F9)**：忽略缓存立即重新下载节目单
- **智能右键**：根据上下文（IPTV/普通视频）显示不同的右键菜单
- **历史记录**：自动保存/恢复上次播放的频道；连续快速切台时会合并为 2 秒后的单次写盘，减少频繁 IO
- **多平台支持**：Windows/Linux/macOS，自带 curl 工具链

### 技术栈

| 组件       | 技术            | 说明                      |
| ---------- | --------------- | ------------------------- |
| 播放器核心 | mpv             | 多媒体播放引擎            |
| UI 框架    | uosc 5.12 (Lua) | 现代 OSC 界面，已定制扩展 |
| EPG 处理   | Lua + XML       | 节目单解析和回看 URL 生成 |
| 数据存储   | JSON            | 频道历史记录持久化        |

## 文件结构

```
portable_config/
├── 📄 CLAUDE.md              # 本文档（AI 开发指南）
├── 📄 UOSC_MODIFY_DIFF.md    # uosc 源码修改记录（重要！）
├── 📄 mpv.conf               # mpv 配置文件
├── 📄 input.conf             # 快捷键配置
│
├── 📁 scripts/
│   ├── � epg/               # 【核心】IPTV EPG 脚本（模块化）
│   │   ├── 📄 main.lua       # 入口：全局状态 + mp.* 绑定
│   │   ├── 📄 utils.lua      # 工具层：字符串/时间/搜索
│   │   ├── 📄 data.lua       # 数据层：EPG/M3U/历史/频道
│   │   ├── 📄 menu.lua       # 菜单层：4级菜单构建
│   │   └── 📄 playback.lua   # 播放层：直播/回看/切台
│   ├── 📄 thumbfast.lua      # 缩略图生成（第三方）
│   │
│   ├── 📁 bin/
│   │   └── 📄 curl.exe       # curl 下载工具（Windows）
│   │
│   └── 📁 uosc/              # 【修改区域】uosc 5.12 源码
│       ├── 📄 main.lua       # ⚠️ 已修改（消息处理器）
│       ├── 📁 lib/
│       │   ├── 📄 menus.lua  # ⚠️ 已修改（toggle_menu_with_items）
│       │   └── 📄 ...        # 其他未修改文件
│       ├── 📁 elements/
│       │   ├── 📄 Menu.lua   # ⚠️ 已修改（activate_selected_item）
│       │   └── 📄 ...        # 其他未修改文件
│       └── 📁 bin/           # ziggy 二进制文件
│
├── 📁 script-opts/           # 脚本配置文件
│   └── 📄 epg.conf           # EPG 配置（epg_download_url）
│
└── 📁 fonts/                 # 字体文件
```

## 关键修改点（uosc 源码修改 必须维护）

本项目对 uosc 5.12 源码进行了关键修改，以支持 IPTV 四级菜单功能：

1. **`scripts/uosc/main.lua`** - 新增 `expand-submenu` 消息处理器，增强 `open-menu` 支持 `anchor_x`/`anchor_offset`
2. **`scripts/uosc/elements/Menu.lua`** - 修改 `activate_selected_item` 方法，支持同时执行 value 和展开子菜单
3. **`scripts/uosc/lib/menus.lua`** - 修改 `toggle_menu_with_items` 函数，确保任何类型菜单都能正确关闭

详细修改记录请查看 `UOSC_MODIFY_DIFF.md` 文件。

## IPTV 核心脚本

**`scripts/epg/`** 是主要业务逻辑（模块化文件夹脚本，mpv 自动以 `main.lua` 为入口），包含：

- `main.lua`：全局状态（`state`/`options`/缓存表）初始化、所有 `mp.*` 事件/消息/按键绑定
- `utils.lua`：字符串工具、UTF8、OSD、时间日期换算、拼音搜索（无 state 依赖，纯函数）
- `data.lua`：M3U/M3U8 解析、EPG XML 下载与解析（支持 gzip）、频道历史记录、频道/节目查找
- `menu.lua`：四级菜单数据结构构建（分组 > 频道 > 日期桶 > EPG）、EPG 回看搜索菜单
- `playback.lua`：回看 URL 生成（支持 OK影视、酷9、APTV 三种时间模板）、直播播放、组内切台、HLS 兼容重试

模块间通过全局变量共享 `state`、`options`、各缓存表；前向声明（`build_main_menu` 等）在 `main.lua` 顶部赋 `nil`，由对应模块 require 后完成真正赋值。

## 核心功能

- 解析 M3U `group-title` 分组、频道
- 自动加载 `x-tvg-url` EPG（xml/xml.gz）
- 支持 `catchup-source` 3 种回看模板
- 支持 `epg_history.json` 记录最后播放频道（每个 m3u）

### 修改标记约定

所有对 uosc 源码的修改必须用中文注释标记：

```lua
-- 【修改】简短说明修改原因
-- 原始代码：
-- if condition then
--     original_code()
-- end
修改后的代码()
```

### 修改类型标记

| 标记         | 用途            | 示例                                         |
| ------------ | --------------- | -------------------------------------------- |
| `【修改】` | 修改现有逻辑    | `-- 【修改】支持同时执行value和展开子菜单` |
| `【新增】` | 新增函数/代码块 | `-- 【新增】expand-submenu 消息处理器`     |
| `【删除】` | 删除原始代码    | `-- 【删除】原代码不支持xxx功能`           |

### 必须同步更新的文件

**当修改以下文件时，`scripts/uosc/` 必须同步更新 `UOSC_MODIFY_DIFF.md`**

**更新格式参考 `UOSC_MODIFY_DIFF.md` 现有结构。**

## 工作流程

### 新增功能步骤

1. **分析需求** - 确定是否需要修改 uosc 源码，还是仅扩展 epg.lua
2. **编码实现** - 优先在 epg.lua 中实现，如需 UI 交互变更再修改 uosc
3. **更新文档** - 在 `UOSC_MODIFY_DIFF.md` 中添加修改记录
4. **测试验证** - 让开发者使用 mpv --msg-level=ffmpeg=no tv.m3u 验证
5. **版本记录** - 更新版本历史

## 规范 Git 提交

使用约定式提交格式：

- feat: 新增功能
- fix: 修复问题
- refactor: 重构代码
- style: 样式/格式调整
- docs: 文档修改
- 使用 SSH 方式
- 自动写 commit 信息

版本号规则：

- fix → 升修订号 x.y.z+1
- feat → 升次版本 x.y+1.0
- 重大重构 → 升主版本 x+1.0.0
  禁止随意跳版本。

### 发布说明规则

- 发布 Release 时，只能使用当前版本的小节作为发布说明，禁止直接粘贴整个 `CHANGELOG.md`。
- `CHANGELOG.md` 必须保持“每个版本一个独立小节”（版本号、日期、变更列表）。
- 建议先从 `CHANGELOG.md` 提取当前版本小节到临时发布说明文件，再用于 GitHub Release。
- 发布前核对：Release 标题版本号、Git Tag、`CHANGELOG.md` 当前版本小节三者一致。

### 调试方法

```lua
-- 查看 mpv 控制台输出：按 ` 键（反引号）
mp.msg.info("调试信息")
mp.msg.warn("警告信息")
mp.msg.error("错误信息")

-- 显示 OSD 消息
mp.osd_message("提示信息", 3)  -- 显示3秒
```

在 `mpv.conf` 中可开启详细日志：

```ini
log-file=mpv.log
msg-level=all=debug
```

## 重要注意事项

### 1. uosc 源码修改

- **修改 uosc 源码后必须更新 `UOSC_MODIFY_DIFF.md`**
- **保留原始注释**，在附近添加中文修改说明
- **向后兼容**：确保修改不破坏原有功能

### 2. IPTV 功能扩展

- **考虑多平台兼容**：Windows PowerShell 和 Linux/macOS gzip 解压
- **错误处理**：网络请求失败、文件读写权限、数据解析异常

## API 参考

### uosc 扩展接口

```lua
-- 打开自定义菜单
mp.commandv("script-message-to", "uosc", "open-menu", json_data, submenu_id)

-- 展开指定子菜单（菜单已打开时）
mp.commandv("script-message-to", "uosc", "expand-submenu", menu_id)

-- 选中指定菜单项
mp.commandv("script-message-to", "uosc", "select-menu-item", menu_type, index, parent_id)
```

### epg.lua 关键函数

- `parse_m3u(path)` - 解析 M3U 文件
- `fetch_and_parse_epg_async()` - 异步获取并解析 EPG
- `build_main_menu()` - 构建四级菜单数据结构
- `show_iptv_menu()` - 显示 IPTV 菜单（绑定 F8 和鼠标右键）
- `switch_channel_in_current_group(direction)` - 在当前频道组内切换直播频道（绑定 PgUp/PgDn）

## 快速检查清单

### 修改代码前

- [ ] 已查看 `UOSC_MODIFY_DIFF.md` 了解现有修改

### 修改代码时

- [ ] 已添加 `【修改】`/`【新增】` 标记
- [ ] 已记录修改原因
- [ ] 未破坏原有功能（向后兼容）

### 修改代码后

- [ ] 已更新 `UOSC_MODIFY_DIFF.md`
- [ ] 已测试功能正常
- [ ] 已更新版本历史
- [ ] 已提交/保存更改

## 版本信息

- **基础版本**：uosc 5.12.0
- **IPTV 版本**：V1.7.3（2026-03-25）
- **最后更新**：2026-03-25

## 相关文档

- `DEVELOPMENT_GUIDE.md` - 详细开发规范
- `UOSC_MODIFY_DIFF.md` - uosc 源码修改记录
- 官方 uosc 文档：https://github.com/tomasklaen/uosc
- mpv Lua API：https://mpv.io/manual/master/#lua-scripting

---

*本文档供 AI 开发助手使用，确保开发工作符合项目规范*
*请严格遵循修改标记约定和文档更新要求*
