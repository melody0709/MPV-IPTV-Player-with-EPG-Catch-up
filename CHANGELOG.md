# Changelog

## V1.6.1 - 2026-03-23

- 优化三级 EPG 自动展开体验：鼠标悬停频道触发子菜单展开后，当前时段会自动选中并滚动到可视区域中间

## V1.6 - 2026-03-23

- 支持在 `epg.conf` 分别设置一级/二级/三级菜单最小宽度：`menu_level1_min_width`、`menu_level2_min_width`、`menu_level3_min_width`
- 支持在 `epg.conf` 设置副标题字体大小：`menu_subtitle_font_size`
- 三级 EPG 菜单改为副标题模式：节目标题为主标题，日期时间改为副标题
- 三级 EPG 菜单项跟随极简样式，去掉额外图标/右侧提示

## V1.5 - 2026-03-23

- 新增二级频道菜单双行显示：频道名下方显示当前节目名
- 缩短频道副标题，移除 `HH:MM-HH:MM` 时间段，减少二级菜单宽度
- 去掉频道右侧 `回看` / `EPG` 提示
- 去掉分组前面的 `folder` 图标
- 去掉所有子菜单默认 `>` 箭头
- 同步更新 `README.md`、`INSTRUCTIONS.md`、`UOSC_MODIFY_DIFF.md`

## V1.4 - 2026-03-21

- 新增 IPTV 菜单频道搜索，支持中文、拼音全拼和首字母
- 新增 EPG 回看搜索菜单 `F9`
- 新增 `search_key` 支持与根菜单搜索转发
- 新增频道历史记录与自动恢复播放
- 新增可配置 EPG 缓存刷新与 `Shift+F9` 强制刷新
