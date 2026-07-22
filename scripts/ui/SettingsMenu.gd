extends CanvasLayer
## Global settings menu with a separate save/load slot dialog.

const SETTINGS_VERSION := 1
const SETTINGS_PATH := "user://settings.json"
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
@onready var save_button: Button = $Dimmer/Panel/VBox/SaveLoadRow/SaveButton
@onready var load_button: Button = $Dimmer/Panel/VBox/SaveLoadRow/LoadButton
@onready var status_label: Label = $Dimmer/Panel/VBox/StatusLabel
@onready var hint_label: Label = $Dimmer/Panel/VBox/HintLabel
@onready var close_button: Button = $Dimmer/Panel/VBox/CloseButton

@onready var save_dialog: ColorRect = $SaveDialog
@onready var save_dialog_panel: PanelContainer = $SaveDialog/Panel
@onready var save_dialog_title: Label = $SaveDialog/Panel/VBox/Title
@onready var slot_list: VBoxContainer = $SaveDialog/Panel/VBox/SlotList
@onready var save_dialog_status: Label = $SaveDialog/Panel/VBox/Status
@onready var save_dialog_close: Button = $SaveDialog/Panel/VBox/CloseButton

var _was_paused := false
var _save_dialog_mode := "save"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("settings_menu")
	title_label.text = "设置"
	resolution_label.text = "分辨率"
	mode_label.text = "窗口模式"
	apply_button.text = "应用显示设置"
	save_button.text = "保存游戏"
	load_button.text = "读取存档"
	hint_label.text = "每 5 分钟自动存档  ·  自动存档不会覆盖手动存档"
	close_button.text = "返回游戏"
	save_dialog_close.text = "关闭存档窗口"
	for resolution in RESOLUTIONS:
		resolution_option.add_item("%d × %d" % [resolution.x, resolution.y])
	mode_option.add_item("窗口模式")
	mode_option.add_item("无边框窗口")
	mode_option.add_item("全屏模式")
	apply_button.pressed.connect(_on_apply_pressed)
	save_button.pressed.connect(_open_save_dialog.bind("save"))
	load_button.pressed.connect(_open_save_dialog.bind("load"))
	close_button.pressed.connect(close_top_ui)
	save_dialog_close.pressed.connect(_close_save_dialog)
	GameState.save_completed.connect(_on_game_saved)
	get_viewport().size_changed.connect(_apply_responsive_layout)
	_load_preferences()
	save_dialog.visible = false
	visible = false
	_update_save_summary()
	call_deferred("_apply_responsive_layout")


func is_ui_open() -> bool:
	return visible


func open_ui() -> void:
	if visible:
		return
	_was_paused = get_tree().paused
	visible = true
	save_dialog.visible = false
	get_tree().paused = true
	_update_save_summary()
	_apply_responsive_layout()
	close_button.grab_focus()


func close_top_ui() -> void:
	if not visible:
		return
	if save_dialog.visible:
		_close_save_dialog()
		return
	_close_settings_ui()


func _close_settings_ui() -> void:
	save_dialog.visible = false
	visible = false
	get_tree().paused = _was_paused


func _on_apply_pressed() -> void:
	_apply_display_settings(true)
	status_label.text = "显示设置已应用并保存。"


func _open_save_dialog(mode: String) -> void:
	_save_dialog_mode = "load" if mode == "load" else "save"
	save_dialog_title.text = "读取存档" if _save_dialog_mode == "load" else "保存游戏"
	save_dialog_status.text = (
		"选择要读取的存档。"
		if _save_dialog_mode == "load"
		else "选择一个手动槽位保存；自动存档不可手动覆盖。"
	)
	_refresh_slot_rows()
	save_dialog.visible = true
	_apply_responsive_layout()
	save_dialog_close.grab_focus()


func _close_save_dialog() -> void:
	save_dialog.visible = false
	_update_save_summary()
	if visible:
		save_button.grab_focus()


func _refresh_slot_rows() -> void:
	for child in slot_list.get_children():
		slot_list.remove_child(child)
		child.queue_free()
	_add_slot_row("自动存档", GameState.AUTO_SAVE_PATH, true)
	for slot in range(1, GameState.MANUAL_SAVE_SLOT_COUNT + 1):
		_add_slot_row("手动存档 %d" % slot, GameState.get_manual_save_path(slot), false)


func _add_slot_row(slot_name: String, path: String, is_auto: bool) -> void:
	var metadata := GameState.get_save_metadata(path)
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 64)
	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	row.add_child(content)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_label := Label.new()
	name_label.text = slot_name
	name_label.add_theme_font_size_override("font_size", 18)
	var detail_label := Label.new()
	detail_label.text = _slot_detail(metadata)
	detail_label.modulate = Color(0.72, 0.76, 0.72)
	detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text_box.add_child(name_label)
	text_box.add_child(detail_label)
	content.add_child(text_box)

	var action_button := Button.new()
	action_button.custom_minimum_size = Vector2(112, 48)
	if _save_dialog_mode == "save":
		action_button.text = "自动保存" if is_auto else "保存"
		action_button.disabled = is_auto
	else:
		action_button.text = "读取"
		action_button.disabled = (
			not bool(metadata.get("exists", false))
			or not bool(metadata.get("valid", false))
		)
	action_button.pressed.connect(_on_slot_action.bind(path, slot_name, is_auto))
	content.add_child(action_button)
	slot_list.add_child(row)


func _slot_detail(metadata: Dictionary) -> String:
	if not bool(metadata.get("exists", false)):
		return "空存档"
	if not bool(metadata.get("valid", false)):
		return "存档损坏或版本不兼容"
	var saved_at := String(metadata.get("saved_at_text", "")).strip_edges()
	if saved_at.is_empty():
		saved_at = "旧版本存档"
	var player := String(metadata.get("player_name", "")).strip_edges()
	return saved_at if player.is_empty() else "%s  ·  %s" % [saved_at, player]


func _on_slot_action(path: String, slot_name: String, is_auto: bool) -> void:
	if _save_dialog_mode == "save":
		if is_auto:
			save_dialog_status.text = "自动存档不能手动覆盖。"
			return
		var save_error := GameState.save_game(path)
		_refresh_slot_rows()
		save_dialog_status.text = (
			"%s保存成功。" % slot_name
			if save_error == OK
			else "%s保存失败：%s" % [slot_name, error_string(save_error)]
		)
		return

	var metadata := GameState.get_save_metadata(path)
	if not bool(metadata.get("exists", false)) or not bool(metadata.get("valid", false)):
		save_dialog_status.text = "%s无法读取。" % slot_name
		return
	_close_settings_ui()
	var load_error := GameState.load_game(path)
	if load_error != OK:
		open_ui()
		_open_save_dialog("load")
		save_dialog_status.text = "读档失败：%s" % error_string(load_error)


func _on_game_saved(path: String) -> void:
	_update_save_summary()
	if save_dialog.visible:
		_refresh_slot_rows()
		if path == GameState.AUTO_SAVE_PATH:
			save_dialog_status.text = "自动存档已在后台更新。"


func _update_save_summary() -> void:
	var manual_count := 0
	for slot in range(1, GameState.MANUAL_SAVE_SLOT_COUNT + 1):
		var metadata := GameState.get_save_metadata(GameState.get_manual_save_path(slot))
		if bool(metadata.get("exists", false)) and bool(metadata.get("valid", false)):
			manual_count += 1
	var auto_metadata := GameState.get_save_metadata(GameState.AUTO_SAVE_PATH)
	var auto_text := "已有" if bool(auto_metadata.get("valid", false)) else "暂无"
	status_label.text = "手动存档 %d/5  ·  自动存档%s" % [manual_count, auto_text]


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
	var panel_height := minf(580.0, viewport_size.y - 32.0)
	panel.offset_left = -panel_width * 0.5
	panel.offset_right = panel_width * 0.5
	panel.offset_top = -panel_height * 0.5
	panel.offset_bottom = panel_height * 0.5

	var dialog_width := minf(780.0, viewport_size.x - 32.0)
	var dialog_height := minf(660.0, viewport_size.y - 32.0)
	save_dialog_panel.offset_left = -dialog_width * 0.5
	save_dialog_panel.offset_right = dialog_width * 0.5
	save_dialog_panel.offset_top = -dialog_height * 0.5
	save_dialog_panel.offset_bottom = dialog_height * 0.5
