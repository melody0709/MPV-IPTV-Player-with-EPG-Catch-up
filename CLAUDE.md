# CLAUDE.md - mpv + uosc IPTV 播放器开发指南

本文档为 AI 开发助手提供关于此 mpv + uosc 5.12 定制版 IPTV 播放器的项目背景、开发规范和注意事项。

## 项目概述

这是一个基于 **mpv 播放器** 和 **uosc 5.12 UI 框架** 深度定制的 IPTV 播放器，专为直播电视和回看功能设计。

### 核心功能

- **三级滑动菜单**：分组 → 频道 → EPG节目单 的嵌套菜单结构
- **EPG 回看**：支持 XMLTV 格式节目单，时间跳转回看功能
- **智能右键**：根据上下文（IPTV/普通视频）显示不同的右键菜单
- **历史记录**：自动保存/恢复上次播放的频道
- **多平台支持**：Windows/Linux/macOS，自带 curl 工具链

### 技术栈

| 组件       | 技术            | 说明                      |
| ---------- | --------------- | ------------------------- |
| 播放器核心 | mpv             | 多媒体播放引擎            |
| UI 框架    | uosc 5.12 (Lua) | 现代 OSC 界面，已定制扩展 |
| EPG 处理   | Lua + XML       | 节目单解析和回看 URL 生成 |
| 数据存储   | JSON            | 频道历史记录持久化        |

```
portable_config/
├── 📄 CLAUDE.md              # 本文档（AI 开发指南）
├── 📄 UOSC_MODIFY_DIFF.md    # uosc 源码修改记录（重要！）
├── 📄 mpv.conf               # mpv 配置文件
├── 📄 input.conf             # 快捷键配置
│
├── 📁 scripts/
│   ├── 📄 epg.lua            # 【核心】IPTV EPG 脚本
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

## 文件结构

## 关键修改点（必须维护）

### 1. uosc 源码修改

本项目对 uosc 5.12 源码进行了三处关键修改，以支持 IPTV 三级菜单功能：

1. **`scripts/uosc/main.lua`** - 新增 `expand-submenu` 消息处理器，增强 `open-menu` 支持 `anchor_x`/`anchor_offset`
2. **`scripts/uosc/elements/Menu.lua`** - 修改 `activate_selected_item` 方法，支持同时执行 value 和展开子菜单
3. **`scripts/uosc/lib/menus.lua`** - 修改 `toggle_menu_with_items` 函数，确保任何类型菜单都能正确关闭

### 2. IPTV 核心脚本

**`scripts/epg.lua`** 是主要业务逻辑，包含：

- M3U/M3U8 文件解析
- EPG XML 数据下载和解析（支持 gzip 压缩）
- 三级菜单数据结构构建
- 回看 URL 生成（支持 OK影视、酷9、APTV 三种时间模板）
- 频道历史记录管理

## 开发规范

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

**当修改以下文件时，必须同步更新 `UOSC_MODIFY_DIFF.md`：**

1. `scripts/uosc/main.lua`
2. `scripts/uosc/elements/Menu.lua`
3. `scripts/uosc/lib/menus.lua`

**更新格式参考 `UOSC_MODIFY_DIFF.md` 现有结构。**

## 工作流程

### 新增功能步骤

1. **分析需求** - 确定是否需要修改 uosc 源码，还是仅扩展 epg.lua
2. **编码实现** - 优先在 epg.lua 中实现，如需 UI 交互变更再修改 uosc
3. **标记修改** - 在代码中添加 `【修改】`/`【新增】` 标记
4. **更新文档** - 在 `UOSC_MODIFY_DIFF.md` 中添加修改记录
5. **测试验证** - 让开发者使用 mpv --msg-level=ffmpeg=no tv.m3u 验证
6. **版本记录** - 更新版本历史

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

- **不要修改未标记的文件**，除非有充分理由
- **修改 uosc 源码后必须更新 `UOSC_MODIFY_DIFF.md`**
- **保留原始注释**，在附近添加中文修改说明
- **向后兼容**：确保修改不破坏原有功能

### 2. IPTV 功能扩展

- **优先在 `epg.lua` 中实现新功能**
- **利用现有 API**：`open-menu`、`expand-submenu`、`select-menu-item`
- **考虑多平台兼容**：Windows PowerShell 和 Linux/macOS gzip 解压
- **错误处理**：网络请求失败、文件读写权限、数据解析异常

### 3. 升级 uosc 版本

1. **备份修改**：复制 `UOSC_MODIFY_DIFF.md`，导出 git diff
2. **替换文件**：用新版本替换 `scripts/uosc/` 目录
3. **重新应用修改**：参考 `UOSC_MODIFY_DIFF.md` 逐个文件对比
4. **API 兼容性检查**：验证 `open-menu`、`expand-submenu` 接口
5. **功能测试**：IPTV 菜单、频道切换、EPG 展开、回看功能

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
- `build_main_menu()` - 构建三级菜单数据结构
- `show_iptv_menu()` - 显示 IPTV 菜单（绑定 F8 和鼠标右键）

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
- **IPTV 版本**：V1.4（2026-03-21）
- **最后更新**：2026-03-21

## 相关文档

- `DEVELOPMENT_GUIDE.md` - 详细开发规范
- `UOSC_MODIFY_DIFF.md` - uosc 源码修改记录
- 官方 uosc 文档：https://github.com/tomasklaen/uosc
- mpv Lua API：https://mpv.io/manual/master/#lua-scripting

---

*本文档供 AI 开发助手使用，确保开发工作符合项目规范*
*请严格遵循修改标记约定和文档更新要求*
