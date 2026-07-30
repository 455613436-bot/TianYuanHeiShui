extends Node2D
## Main
## 村长家场景（第 0 号"村口广场"）。
##
## 设计：固定背景 + 场景立绘。进入场景后**不自动开对话**，
## 玩家需要点击场景中的村长立绘才会打开 DialogueUI。
## 对话框打开后场景立绘的悬停高亮不再触发。
## 提供 M / Esc / 按钮三种方式返回世界地图。

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"

## 村长 NPC 的 profile 路径（与 scenes/main/Main.tscn 中 NpcWuZhiyuan 节点一致）
const NPC_ID := "wu_zhiyuan"
const NPC_MD_PATH := "res://data/npcs/wu_zhiyuan.md"
const NPC_JSON_PATH := "res://data/npcs/wu_zhiyuan.json"

## 立绘常态（稍暗）与悬停态（提亮）的 modulate
const PORTRAIT_NORMAL_MODULATE := Color(0.85, 0.85, 0.85, 1)
const PORTRAIT_HOVER_MODULATE := Color(1.0, 1.0, 1.0, 1.0)

@onready var npc_node: Node = $NpcWuZhiyuan
@onready var return_map_button: BaseButton = $HUD/ReturnMapButton
@onready var portrait_button: BaseButton = $PortraitLayer/VillageChiefPortrait


func _ready() -> void:
	GameState.restore_current_scene()
	return_map_button.pressed.connect(_open_map)
	portrait_button.pressed.connect(_on_portrait_clicked)
	portrait_button.mouse_entered.connect(_on_portrait_hover.bind(true))
	portrait_button.mouse_exited.connect(_on_portrait_hover.bind(false))
	portrait_button.modulate = PORTRAIT_NORMAL_MODULATE
	print("[Main] 村长家场景就绪，点击立绘开始对话。")


## 对话框打开时禁用立绘的悬停高亮，避免视觉干扰
func _process(_delta: float) -> void:
	var dialogue_open := _is_dialogue_open()
	# 对话进行中 → 立绘不响应悬停，并恢复常态
	if dialogue_open:
		if portrait_button.modulate != PORTRAIT_NORMAL_MODULATE:
			portrait_button.modulate = PORTRAIT_NORMAL_MODULATE
		portrait_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		portrait_button.mouse_filter = Control.MOUSE_FILTER_STOP


func _is_dialogue_open() -> bool:
	var ui := get_tree().get_first_node_in_group("dialogue_ui")
	if ui == null:
		return false
	if ui.has_method("is_open"):
		return ui.is_open()
	return false


func _on_portrait_hover(is_hover: bool) -> void:
	if _is_dialogue_open():
		portrait_button.modulate = PORTRAIT_NORMAL_MODULATE
		return
	portrait_button.modulate = PORTRAIT_HOVER_MODULATE if is_hover else PORTRAIT_NORMAL_MODULATE


func _on_portrait_clicked() -> void:
	if _is_dialogue_open():
		return
	var ui := get_tree().get_first_node_in_group("dialogue_ui")
	if ui == null:
		push_error("[Main] 场景中没有 dialogue_ui 组的节点，无法开对话")
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
