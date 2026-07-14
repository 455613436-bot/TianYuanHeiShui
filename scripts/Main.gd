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
	GameState.restore_current_scene()
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


func _open_map() -> void:
	InputManager.request_open_map()
