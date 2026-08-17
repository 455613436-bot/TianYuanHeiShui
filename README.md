# TianYuanHeiShui / 思源村探案

基于田原村设定的 Godot 叙事探案游戏。项目包含多地点探索、时间推进、NPC 对话、线索册、物品与技能检定，以及基于披露等级的 LLM NPC 剧情系统。

## 运行

使用 Godot 打开项目后按 `F6` 或 `F5` 运行。首次启动会导入资源。

## 主要目录

- `data/`：NPC、物品、线索、技能与地点数据。
- `scenes/`：标题、地图、地点与界面场景。
- `scripts/autoload/`：游戏状态、时间、NPC、物品、线索与技能系统。
- `scripts/llm/`：LLM 对话、披露等级与固定剧情事件系统。
- `scripts/locations/`：场景遮罩热点与地点交互。

## 本地配置

LLM 服务配置应保存在本地忽略文件中，不要将 API Key 提交到仓库。
