extends Node
## GameState
## 全局游戏状态：污染度 / NPC 好感 / 物品栏 / 已触发线索。
## 通过 autoload 全局可用，名字就是 GameState。
##
## 设计意图：所有「跨场景、跨 NPC 共享」的事实都放这里。
## - 污染度：玩家个人属性（PDF 中污染卡片 0~6），>=6 触发迷途结局。
## - 好感：玩家组别属性（按 NPC 分桶，>=1 视为劝说成功）。
## - 物品：道具卡（参考 PDF §4）。
## - 已触发线索：用于 LLM Prompt 注入 + 任务流转。

signal pollution_changed(new_value: int)
signal affinity_changed(npc_id: String, new_value: int)
signal item_added(item_id: String)
signal clue_triggered(clue_id: String)

const MAX_POLLUTION := 6
const DEFAULT_MAP_RETURN_SCENE := "res://scenes/main/Main.tscn"

## 玩家职业（Phase 1 默认医生，后续可在主菜单选）
var player_role: String = "medic"
var player_name: String = "圆鸟"

## 污染度 0~6
var pollution: int = 0

## NPC 好感字典：{ npc_id: int }
var affinity: Dictionary = {}

## 物品栏：[item_id, ...]
var inventory: Array[String] = []

## 已触发线索：{ clue_id: true }
var clues: Dictionary = {}

## 打开大地图前所在的场景；用于 M / Esc 关闭地图后返回。
var map_return_scene_path: String = DEFAULT_MAP_RETURN_SCENE

func add_pollution(amount: int = 1) -> void:
	pollution = clamp(pollution + amount, 0, MAX_POLLUTION)
	pollution_changed.emit(pollution)
	if pollution >= MAX_POLLUTION:
		clue_triggered.emit("ending_mituu")

func add_affinity(npc_id: String, amount: int = 1) -> void:
	affinity[npc_id] = int(affinity.get(npc_id, 0)) + amount
	affinity_changed.emit(npc_id, affinity[npc_id])

func get_affinity(npc_id: String) -> int:
	return int(affinity.get(npc_id, 0))

func add_item(item_id: String) -> void:
	if not inventory.has(item_id):
		inventory.append(item_id)
		item_added.emit(item_id)

func has_item(item_id: String) -> bool:
	return inventory.has(item_id)

func remove_item(item_id: String) -> bool:
	var idx := inventory.find(item_id)
	if idx >= 0:
		inventory.remove_at(idx)
		return true
	return false

func trigger_clue(clue_id: String) -> void:
	if not clues.has(clue_id):
		clues[clue_id] = true
		clue_triggered.emit(clue_id)

func has_clue(clue_id: String) -> bool:
	return clues.has(clue_id)


func remember_map_return_scene(scene_path: String) -> void:
	if scene_path.is_empty() or scene_path == "res://scenes/map/WorldMap.tscn":
		return
	map_return_scene_path = scene_path

## 给 LLM 的 prompt 用：把当前世界状态摘要成一段自然语言
func summary_for_llm() -> String:
	var lines: PackedStringArray = []
	lines.append("【玩家信息】职业=%s，姓名=%s" % [player_role, player_name])
	lines.append("【污染度】%d/%d" % [pollution, MAX_POLLUTION])
	if not inventory.is_empty():
		lines.append("【已持有道具】%s" % ", ".join(inventory))
	if not clues.is_empty():
		lines.append("【已触发线索】%s" % ", ".join(clues.keys()))
	return "\n".join(lines)
