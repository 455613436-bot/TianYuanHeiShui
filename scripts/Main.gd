extends Node2D
## Main
## 村长家场景（第 0 号"村口广场"）。
##
## 设计：固定背景，不可移动。进入场景后自动打开与村长的对话，
## 把跑团叙事的第一幕完全交给 DialogueUI 承担。
## 提供 M / Esc / 按钮三种方式返回世界地图。

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"

## 村长 NPC 的 profile 路径（与 scenes/main/Main.tscn 中 NpcWuZhiyuan 节点一致）
const NPC_ID := "wu_zhiyuan"
const NPC_MD_PATH := "res://data/npcs/wu_zhiyuan.md"
const NPC_JSON_PATH := "res://data/npcs/wu_zhiyuan.json"

@onready var npc_node: Node = $NpcWuZhiyuan
@onready var return_map_button: Button = $HUD/ReturnMapButton

## 进入场景后延迟一帧自动开启对话，避免 DialogueUI._ready() 还没跑完
var _auto_open_pending: bool = true


func _ready() -> void:
	GameState.restore_current_scene()
	# HUD 上原来的污染/线索显示对玩家不友好（场景里没移动），直接隐藏避免误读
	return_map_button.pressed.connect(_open_map)
	print("[Main] 村长家场景就绪，进入自动开对话。")
	call_deferred("_auto_open_dialogue")


func _auto_open_dialogue() -> void:
	if not _auto_open_pending:
		return
	_auto_open_pending = false
	var ui := get_tree().get_first_node_in_group("dialogue_ui")
	if ui == null:
		push_error("[Main] 场景中没有 dialogue_ui 组的节点，无法自动开对话")
		return
	if ui.has_method("is_open") and ui.is_open():
		return
	# 让 NpcInteractable 加载 profile，然后再开对话 —— 与玩家按 E 时走同一条路径
	if npc_node and npc_node.has_method("on_player_interact"):
		npc_node.on_player_interact(self)
	else:
		# 兜底：手动加载 profile 并打开
		var profile: Dictionary = _load_profile()
		if not profile.is_empty() and ui.has_method("open_dialogue"):
			ui.open_dialogue(profile)


func _load_profile() -> Dictionary:
	if NPC_MD_PATH != "" and FileAccess.file_exists(NPC_MD_PATH):
		var p: Dictionary = NpcPersona.load_from_file(NPC_MD_PATH)
		if p.get("id", "") == "" and NPC_ID != "":
			p["id"] = NPC_ID
		return p
	if NPC_JSON_PATH != "" and FileAccess.file_exists(NPC_JSON_PATH):
		var f := FileAccess.open(NPC_JSON_PATH, FileAccess.READ)
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			return parsed
	return {}


func _open_map() -> void:
	InputManager.request_open_map()
