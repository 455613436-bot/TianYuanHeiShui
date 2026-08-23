extends CanvasLayer
## Global display settings menu.

const SETTINGS_VERSION := 1
const SETTINGS_PATH := "user://settings.json"
const TITLE_SCREEN_SCENE := "res://scenes/ui/TitleScreen.tscn"
const RESOLUTIONS := [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

@onready var panel: PanelContainer = $Dimmer/Panel
@onready var title_label: Label = $Dimmer/Panel/VBox/Title
@onready var resolution_label: Label = $Dimmer/Panel/VBox/Options/ResolutionLabel
@onready var resolution_option: OptionButton = $Dimmer/Panel/VBox/Options/ResolutionOption
@onready var mode_label: Label = $Dimmer/Panel/VBox/Options/ModeLabel
@onready var mode_option: OptionButton = $Dimmer/Panel/VBox/Options/ModeOption
@onready var apply_button: Button = $Dimmer/Panel/VBox/ApplyButton
@onready var status_label: Label = $Dimmer/Panel/VBox/StatusLabel
@onready var hint_label: Label = $Dimmer/Panel/VBox/HintLabel
@onready var main_menu_button: Button = $Dimmer/Panel/VBox/MainMenuButton
@onready var close_button: Button = $Dimmer/Panel/VBox/CloseButton

var _was_paused := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("settings_menu")
	title_label.text = "设置"
	resolution_label.text = "分辨率"
	mode_label.text = "窗口模式"
	apply_button.text = "应用显示设置"
	status_label.text = ""
	hint_label.text = "游戏进度会自动保存，返回主菜单后可从“继续游戏”恢复。"
	main_menu_button.text = "返回主菜单"
	close_button.text = "返回游戏"
	for resolution in RESOLUTIONS:
		resolution_option.add_item("%d × %d" % [resolution.x, resolution.y])
	mode_option.add_item("窗口模式")
	mode_option.add_item("无边框窗口")
	mode_option.add_item("全屏模式")
	apply_button.pressed.connect(_on_apply_pressed)
	main_menu_button.pressed.connect(_on_main_menu_pressed)
	close_button.pressed.connect(close_top_ui)
	get_viewport().size_changed.connect(_apply_responsive_layout)
	_load_preferences()
	visible = false
	call_deferred("_apply_responsive_layout")


func is_ui_open() -> bool:
	return visible


func open_ui() -> void:
	if visible:
		return
	_was_paused = get_tree().paused
	visible = true
	get_tree().paused = true
	_apply_responsive_layout()
	close_button.grab_focus()


func close_top_ui() -> void:
	if not visible:
		return
	_close_settings_ui()


func _close_settings_ui() -> void:
	visible = false
	get_tree().paused = _was_paused


func _on_apply_pressed() -> void:
	_apply_display_settings(true)
	status_label.text = "显示设置已应用并保存。"


func _on_main_menu_pressed() -> void:
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.scene_file_path == TITLE_SCREEN_SCENE:
		_close_settings_ui()
		return
	# 返回主菜单前刷新一次自动存档，确保“继续游戏”恢复到离开前的状态。
	GameState.save_game(GameState.AUTO_SAVE_PATH)
	visible = false
	get_tree().paused = false
	get_tree().change_scene_to_file(TITLE_SCREEN_SCENE)


func _apply_display_settings(save_preferences: bool) -> void:
	var resolution_index := clampi(resolution_option.selected, 0, RESOLUTIONS.size() - 1)
	var mode_index := clampi(mode_option.selected, 0, 2)
	var resolution: Vector2i = RESOLUTIONS[resolution_index]
	if DisplayServer.get_name() != "headless":
		if mode_index == 2:
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, mode_index == 1)
			DisplayServer.window_set_size(resolution)
			var screen_size := DisplayServer.screen_get_size()
			DisplayServer.window_set_position((screen_size - resolution) / 2)
	if save_preferences:
		_save_preferences(resolution_index, mode_index)


func _save_preferences(resolution_index: int, mode_index: int) -> void:
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		status_label.text = "无法保存显示设置。"
		return
	file.store_string(JSON.stringify({
		"settings_version": SETTINGS_VERSION,
		"resolution_index": resolution_index,
		"window_mode": mode_index,
	}, "	"))
	file.close()


func _load_preferences() -> void:
	var current_size := DisplayServer.window_get_size()
	var closest_index := 0
	var closest_distance := 1.0e20
	for index in range(RESOLUTIONS.size()):
		var distance := Vector2(RESOLUTIONS[index]).distance_squared_to(Vector2(current_size))
		if distance < closest_distance:
			closest_distance = distance
			closest_index = index
	resolution_option.select(closest_index)
	mode_option.select(0)
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	var parse_error := json.parse(file.get_as_text())
	file.close()
	if parse_error != OK or json.data is not Dictionary:
		return
	var data: Dictionary = json.data
	var version: Variant = data.get("settings_version", 0)
	if not (version is int or version is float) or int(version) != SETTINGS_VERSION:
		return
	var saved_resolution: Variant = data.get("resolution_index", closest_index)
	var saved_mode: Variant = data.get("window_mode", 0)
	if saved_resolution is int or saved_resolution is float:
		resolution_option.select(clampi(int(saved_resolution), 0, RESOLUTIONS.size() - 1))
	if saved_mode is int or saved_mode is float:
		mode_option.select(clampi(int(saved_mode), 0, 2))
	call_deferred("_apply_display_settings", false)


func _apply_responsive_layout() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var panel_width := minf(660.0, viewport_size.x - 32.0)
	var panel_height := minf(500.0, viewport_size.y - 32.0)
	panel.offset_left = -panel_width * 0.5
	panel.offset_right = panel_width * 0.5
	panel.offset_top = -panel_height * 0.5
	panel.offset_bottom = panel_height * 0.5
