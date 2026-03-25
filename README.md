# MPV IPTV Player with EPG & Catch-up

基于 **mpv 播放器** 和 **uosc 5.12 UI 框架** 深度定制的 IPTV 播放器，专为直播电视和回看功能设计。

## 核心功能

- **四级滑动菜单 + 频道搜索**：`F8` 顶部搜索框只匹配频道名，不会匹配 EPG 时间或节目标题；菜单结构为 分组 > 频道 > 日期桶 > EPG，日期桶支持 明天 / 今天 / 昨天 / 星期X（附月日副标题）；频道搜索支持中文、拼音全拼和首字母（如 `广东` / `guangdong` / `gd`，`东莞` / `dongguan` / `dg`）
- **组内快速切台 (PgUp / PgDn / uosc 上一台下一台按钮)**：直播时可在当前频道组内切到上一台/下一台，行为与鼠标点选频道一致；切台后 OSD 会在视频顶部居中显示当前频道名；回看状态下不执行切台，只显示提示
- **顶部频道上下文**：鼠标移动到视频顶部时，`uosc` 顶部悬浮标题除原有播放地址/标题外，还会在同一行后方显示当前频道组与频道名
- **EPG 回看**：支持 XMLTV 格式节目单，时间跳转回看功能
- **回看续播预加载**：在当前回看片段接近结束时提前排队下一段 URL，尽量前置网络连接与请求延迟，减少续播卡顿
- **EPG 回看搜索 (F9)**：跨频道搜索所有可回看的节目，按时间倒序排列
- **手动强制刷新 EPG (Shift+F9)**：忽略缓存立即重新下载节目单
- **智能右键**：根据上下文（IPTV/普通视频）显示不同的右键菜单
- **历史记录**：自动保存/恢复上次播放的频道；连续快速切台时会合并为 2 秒后的单次写盘，减少频繁 IO
- **多平台支持**：Windows/Linux/macOS，自带 curl 工具链

## 快速使用

1. 下载 mpv Windows 版（推荐 shinchiro mpv-winbuild）
2. 把 `portable_config` 放到 下载好的mpv 根目录
3. 双击 M3U，或命令行：
   ```bash
   mpv tv.m3u
   ```

## 技术栈

| 组件       | 技术            | 说明                      |
| ---------- | --------------- | ------------------------- |
| 播放器核心 | mpv             | 多媒体播放引擎            |
| UI 框架    | uosc 5.12 (Lua) | 现代 OSC 界面，已定制扩展 |
| EPG 处理   | Lua + XML       | 节目单解析和回看 URL 生成 |
| 数据存储   | JSON            | 频道历史记录持久化        |

## 文件结构

```
portable_config/
├── 📄 CLAUDE.md              # AI 开发指南（开发者文档）
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

## 关键修改点（uosc 源码修改）

本项目对 uosc 5.12 源码进行了关键修改，以支持 IPTV 四级菜单功能：

1. **`scripts/uosc/main.lua`** - 新增 `expand-submenu` 消息处理器，增强 `open-menu` 支持 `anchor_x`/`anchor_offset`
2. **`scripts/uosc/elements/Menu.lua`** - 修改 `activate_selected_item` 方法，支持同时执行 value 和展开子菜单
3. **`scripts/uosc/lib/menus.lua`** - 修改 `toggle_menu_with_items` 函数，确保任何类型菜单都能正确关闭

详细修改记录请查看 `UOSC_MODIFY_DIFF.md` 文件。

## IPTV 核心脚本

**`scripts/epg/`** 是主要业务逻辑（模块化文件夹脚本），包含：

- `main.lua`：全局状态初始化、所有 mp.* 事件/消息/按键绑定
- `utils.lua`：字符串工具、UTF8、OSD、时间日期换算、拼音搜索
- `data.lua`：M3U/M3U8 解析、EPG XML 下载与解析（支持 gzip）、频道历史记录、频道/节目查找
- `menu.lua`：四级菜单数据结构构建（分组 > 频道 > 日期桶 > EPG）、EPG 回看搜索菜单
- `playback.lua`：回看 URL 生成（支持 OK影视、酷9、APTV 三种时间模板）、直播播放、组内切台、HLS 兼容重试

## 核心功能

- 解析 M3U `group-title` 分组、频道
- 自动加载 `x-tvg-url` EPG（xml/xml.gz）
- 支持 `catchup-source` 3 种回看模板
- 支持 `epg_history.json` 记录最后播放频道（每个 m3u）

## M3U 模板

```m3u
 #EXTM3U x-tvg-url="http://your-epg-server/t.xml"
 #EXTINF:-1 tvg-id="CCTV1" tvg-name="CCTV-1高清" tvg-logo="http://..." group-title="央视" catchup="default" catchup-source="http://server/ch{id}?starttime=${utc:yyyyMMddHHmmss}&endtime=${utcend:yyyyMMddHHmmss}",CCTV-1综合
 http://your-stream-url/playlist.m3u8
```

## 字段说明

- `x-tvg-url`：EPG 数据源
- `tvg-id`：频道 ID（与 EPG channel id 关联）
- `group-title`：频道分组
- `catchup-source`：回看 URL 模板

## 频道历史记录

- 文件位置：优先使用 `~~home/cache/epg_history.json`，无法确定时回退到 `%TEMP%/mpv_epg_epg_history.json`
- 格式：`{ "path/to/tv.m3u": { "url":"...", "name":"...", "group":"...", "timestamp":123456789 } }`
- 下次打开同一路径的 m3u 将自动还原上次频道
- 连续快速切台时，历史记录会在停止切台约 2 秒后统一写入最后一次频道
- 如果在 2 秒内直接退出 mpv，脚本会在退出前立即刷盘，尽量避免最后频道丢失

## 配置示例

 `script-opts/epg.conf`

```ini
 epg_download_url=http://your-epg-source.com/epg.xml
 epg_cache_refresh_start=00:04
 epg_cache_refresh_interval_hours=7
 catchup_preload_seconds=15
 catchup_overlap_skip_seconds=0.5
```

## 运行日志调试

```bash
 mpv --msg-level=ffmpeg=no  tv.m3u
```

 关注 `epg.lua` 输出：历史记录路径、EPG 下载状态、自动恢复频道

按 `F8` 打开 IPTV 菜单后，顶部会直接显示搜索框，可输入频道名快速筛选；搜索结果只按频道名匹配，并支持中文、拼音全拼和首字母。

## 常见问题

- 无 EPG：确认 `x-tvg-url` 可访问,修改script-opts\epg.conf 中的下载连接
- 无回看：检查 `catchup-source` 时间模板
- 无历史记忆：确认脚本有写权限
- 某些直播频道在 Android IPTV 能播、mpv 直接打开不行：当前脚本会在“先打开本地 M3U，再通过 IPTV 菜单/历史恢复播放频道”时，先按 mpv 默认方式打开；只有当 mpv 明确报错，且该地址看起来像无明确媒体后缀的 HTTP/HTTPS IPTV 源时，才自动再用 HLS 方式重试一次；这只作用于 IPTV 工作流，不会改动普通本地文件或普通网络文件的全局行为
- 想在同一频道组内快速上下切台：直播时按 `PgUp` / `PgDn`，或点击 `uosc` 底部上一台/下一台按钮；如果正在看回看，只会提示“回看中不支持组内切台”
- 想立即更新节目单：按 `Shift+F9`，或打开 `F8` IPTV 菜单后选择 `强制刷新 EPG`
- 想快速找频道：按 `F8` 后直接输入频道名，菜单会即时筛选频道结果，不会匹配 EPG 节目时间或标题；例如 `gd` 和 `guangdong` 都能匹配 `广东`，`dianying` 和 `dy` 都能匹配 `电影`，但不会因为 `jingdian` 里恰好含有 `gd` 就误命中 `经典` 类频道

## ⚙️ 配置说明

### EPG 下载 URL（可选）

脚本会优先使用 `script-opts/epg.conf` 中的 `epg_download_url` 配置来下载 EPG 数据，若该值为空则会回退到 M3U 中的 `x-tvg-url` 字段。

`script-opts/epg.conf` 示例：

```ini
# EPG 下载连接配置
# 当此参数存在时，优先使用该连接下载 EPG，而不是 M3U 表头中的 x-tvg-url
epg_download_url=http://your-epg-source.com/epg.xml

# EPG 缓存刷新时间配置
# 从每天 00:04 开始，按 7 小时间隔生成当天刷新点：00:04 / 07:04 / 14:04 / 21:04
epg_cache_refresh_start=00:04
epg_cache_refresh_interval_hours=7

# 回看续播预加载阈值（秒）
# 当当前回看片段距离结束还剩这么多秒时，提前排队下一段 URL
catchup_preload_seconds=15

# 回看边界重叠补偿（秒）
# 打开下一段时，从该片段开头向后偏移这么多秒开始播放，用于跳过边界重复
catchup_overlap_skip_seconds=0.5

# IPTV 菜单 UI 配置（0=沿用 uosc.conf）
menu_subtitle_font_size=0
menu_level1_min_width=0
menu_level2_min_width=0
menu_level3_min_width=0
menu_level4_min_width=0
```

- `menu_subtitle_font_size`：二级/三级菜单副标题字体大小（频道当前节目、日期桶日期）
- `menu_level1_min_width`：一级菜单（分组）最小宽度
- `menu_level2_min_width`：二级菜单（频道）最小宽度
- `menu_level3_min_width`：三级菜单（日期桶）最小宽度
- `menu_level4_min_width`：四级菜单（EPG）最小宽度
- `catchup_preload_seconds`：回看片段剩余多少秒时，提前把下一段插入播放列表；默认 `15`
- `catchup_overlap_skip_seconds`：打开下一段时，从该片段开头向后偏移多少秒开始播放，用于跳过边界重复；默认 `0.5`

### EPG 缓存刷新规则

- `epg_cache_refresh_start`：每天首个刷新点，格式为 `HH:MM`
- `epg_cache_refresh_interval_hours`：当天后续刷新点的小时间隔
- 默认配置会得到 `00:04 / 07:04 / 14:04 / 21:04` 四个刷新点
- 如果配置缺失或格式错误，脚本会自动回退到旧的固定时段规则，避免缓存失效

## 🔧 故障排除

### EPG 无法加载

1. **检查 EPG URL 格式**

   - 确保 M3U 中的 `x-tvg-url` 是可访问的 XML 文件
   - 文件编码应为 UTF-8
2. **查看 mpv 日志**

   ```bash
   mpv --msg-level=ffmpeg=no tv.m3u
   ```

   搜索 `epg.lua` 相关日志

### 回看功能不工作

1. **检查 `catchup-source` 格式**

   - 支持以下三种时间参数格式：
     - **标准回看模板**: `${utc:yyyyMMddHHmmss}` 和 `${utcend:yyyyMMddHHmmss}`
     - **KU9回看模板**: `${(b)yyyyMMddHHmmss|UTC}` 和 `${(e)yyyyMMddHHmmss|UTC}`
     - **APTV回看模板**: `${(b)yyyyMMddHHmmss:utc}` 和 `${(e)yyyyMMddHHmmss:utc}`
2. **检查时间格式**

   - 确保 EPG 中的 `start` 和 `stop` 时间是标准 XMLTV 格式

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

### 重要注意事项

1. **uosc 源码修改**

   - **不要修改未标记的文件**，除非有充分理由
   - **修改 uosc 源码后必须更新 `UOSC_MODIFY_DIFF.md`**
   - **保留原始注释**，在附近添加中文修改说明
   - **向后兼容**：确保修改不破坏原有功能
2. **IPTV 功能扩展**

   - **优先在 `epg.lua` 中实现新功能**
   - **利用现有 API**：`open-menu`、`expand-submenu`、`select-menu-item`
   - **考虑多平台兼容**：Windows PowerShell 和 Linux/macOS gzip 解压
   - **错误处理**：网络请求失败、文件读写权限、数据解析异常
3. **升级 uosc 版本**

   - **备份修改**：复制 `UOSC_MODIFY_DIFF.md`，导出 git diff
   - **替换文件**：用新版本替换 `scripts/uosc/` 目录
   - **重新应用修改**：参考 `UOSC_MODIFY_DIFF.md` 逐个文件对比
   - **API 兼容性检查**：验证 `open-menu`、`expand-submenu` 接口
   - **功能测试**：IPTV 菜单、频道切换、EPG 展开、回看功能

## 版本信息

- **基础版本**：uosc 5.12.0
- **IPTV 版本**：V1.7.3（2026-03-25）
- **最后更新**：2026-03-25

## 🤝 致谢

- [mpv](https://mpv.io/) - 强大的媒体播放器
- [uosc](https://github.com/tomasklaen/uosc) - 优秀的 mpv 界面脚本
- [XMLTV](http://wiki.xmltv.org/) - EPG 数据格式标准

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

---

**注意**: 本脚本仅供学习研究使用，请遵守当地法律法规，合理使用 IPTV 资源.
