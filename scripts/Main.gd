extends Node2D
## Main
## 村口主场景的入口脚本。
## 负责：
## - 进入时给玩家发开场旁白
## - 监听 GameState 信号，把污染度等显示在右上角 HUD

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"

@onready var hud_label: Label = $HUD/HUDPanel/HUDLabel if has_node("HUD/HUDPanel/HUDLabel") else null
@onready var return_map_button: Button = $HUD/ReturnMapButton


func _ready() -> void:
	GameState.pollution_changed.connect(_refresh_hud)
	GameState.clue_triggered.connect(_on_clue)
	_refresh_hud(GameState.pollution)
	return_map_button.pressed.connect(_open_map)
	print("[Main] 村口场景就绪。玩家职业=%s" % GameState.player_role)


func _refresh_hud(_p: int = 0) -> void:
	if hud_label:
		hud_label.text = "污染 %d/%d  ·  线索 %d  ·  道具 %d" % [
			GameState.pollution,
			GameState.MAX_POLLUTION,
			GameState.clues.size(),
			GameState.inventory.size()
		]


func _on_clue(clue_id: String) -> void:
	print("[Main] 触发线索：%s" % clue_id)
	_refresh_hud()
	if clue_id == "ending_mituu":
		print("[Main] *** 污染度到顶 → 迷途结局触发条件达成 ***")


func _unhandled_input(event: InputEvent) -> void:
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui != null and dialogue_ui.has_method("is_open") and dialogue_ui.is_open():
		if event.is_action_pressed("ui_cancel") and dialogue_ui.has_method("close_dialogue"):
			dialogue_ui.close_dialogue()
		if event.is_action_pressed("ui_cancel") or _is_map_shortcut(event):
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_cancel") or _is_map_shortcut(event):
		get_viewport().set_input_as_handled()
		_open_map()


func _is_map_shortcut(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
		and (event.keycode == KEY_M or event.physical_keycode == KEY_M)


func _open_map() -> void:
	var current_scene := get_tree().current_scene
	if current_scene != null:
		GameState.remember_map_return_scene(current_scene.scene_file_path)
	get_tree().change_scene_to_file(MAP_SCENE)
