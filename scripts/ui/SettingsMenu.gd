extends CanvasLayer
## Global display settings menu.

const SETTINGS_VERSION := 1
const SETTINGS_PATH := "user://settings.json"
const TITLE_SCREEN_SCENE := "res://scenes/ui/TitleScreen.tscn"
const DISPLAY_PANEL_MAX_HEIGHT := 470.0
const SAVE_PANEL_MAX_HEIGHT := 680.0
const AUDIO_PANEL_MAX_HEIGHT := 540.0
const RESOLUTIONS := [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

@onready var panel: PanelContainer = $Dimmer/Panel
@onready var title_label: Label = $Dimmer/Panel/VBox/Title
@onready var tabs: TabContainer = $Dimmer/Panel/VBox/Tabs
@onready var display_options: GridContainer = $Dimmer/Panel/VBox/Tabs/Display/Options
@onready var resolution_label: Label = $Dimmer/Panel/VBox/Tabs/Display/Options/ResolutionLabel
@onready var resolution_option: OptionButton = $Dimmer/Panel/VBox/Tabs/Display/Options/ResolutionOption
@onready var mode_label: Label = $Dimmer/Panel/VBox/Tabs/Display/Options/ModeLabel
@onready var mode_option: OptionButton = $Dimmer/Panel/VBox/Tabs/Display/Options/ModeOption
@onready var apply_button: Button = $Dimmer/Panel/VBox/Tabs/Display/ApplyButton
@onready var status_label: Label = $Dimmer/Panel/VBox/Tabs/Display/StatusLabel
@onready var hint_label: Label = $Dimmer/Panel/VBox/Tabs/Display/HintLabel
@onready var master_volume_slider: HSlider = $Dimmer/Panel/VBox/Tabs/AudioSettings/AudioOptions/MasterVolumeSlider
@onready var master_volume_value: Label = $Dimmer/Panel/VBox/Tabs/AudioSettings/AudioOptions/MasterVolumeValue
@onready var bgm_volume_slider: HSlider = $Dimmer/Panel/VBox/Tabs/AudioSettings/AudioOptions/BgmVolumeSlider
@onready var bgm_volume_value: Label = $Dimmer/Panel/VBox/Tabs/AudioSettings/AudioOptions/BgmVolumeValue
@onready var sfx_volume_slider: HSlider = $Dimmer/Panel/VBox/Tabs/AudioSettings/AudioOptions/SfxVolumeSlider
@onready var sfx_volume_value: Label = $Dimmer/Panel/VBox/Tabs/AudioSettings/AudioOptions/SfxVolumeValue
@onready var mute_check: CheckButton = $Dimmer/Panel/VBox/Tabs/AudioSettings/MuteCheck
@onready var reset_audio_button: Button = $Dimmer/Panel/VBox/Tabs/AudioSettings/ResetAudioButton
@onready var audio_status_label: Label = $Dimmer/Panel/VBox/Tabs/AudioSettings/AudioStatusLabel
@onready var save_list: VBoxContainer = $Dimmer/Panel/VBox/Tabs/SaveManagement/Scroll/List
@onready var global_status_label: Label = $Dimmer/Panel/VBox/GlobalStatusLabel
@onready var main_menu_button: Button = $Dimmer/Panel/VBox/MainMenuButton
@onready var close_button: Button = $Dimmer/Panel/VBox/CloseButton
@onready var save_confirm: ConfirmationDialog = $SaveConfirm
@onready var load_confirm: ConfirmationDialog = $LoadConfirm

var _was_paused := false
var _slot_rows: Array[Dictionary] = []
var _pending_slot := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("settings_menu")
	title_label.text = "设置（Esc / B）"
	tabs.set_tab_title(0, "显示设置")
	tabs.set_tab_title(1, "声音设置")
	tabs.set_tab_title(2, "存档管理")
	resolution_label.text = "分辨率"
	mode_label.text = "窗口模式"
	apply_button.text = "应用显示设置"
	status_label.text = ""
	hint_label.text = "游戏进度会自动保存；也可以在“存档管理”中使用 5 个手动槽位。"
	global_status_label.text = ""
	main_menu_button.text = "返回主菜单"
	close_button.text = "返回游戏（Esc / B）"
	for resolution in RESOLUTIONS:
		resolution_option.add_item("%d × %d" % [resolution.x, resolution.y])
	mode_option.add_item("窗口模式")
	mode_option.add_item("无边框窗口")
	mode_option.add_item("全屏模式")
	_configure_display_options_for_platform()
	_configure_audio_options()
	apply_button.pressed.connect(_on_apply_pressed)
	tabs.tab_changed.connect(_on_tab_changed)
	master_volume_slider.value_changed.connect(_on_master_volume_changed)
	bgm_volume_slider.value_changed.connect(_on_bgm_volume_changed)
	sfx_volume_slider.value_changed.connect(_on_sfx_volume_changed)
	mute_check.toggled.connect(_on_mute_toggled)
	reset_audio_button.pressed.connect(_on_reset_audio_pressed)
	main_menu_button.pressed.connect(_on_main_menu_pressed)
	close_button.pressed.connect(close_top_ui)
	save_confirm.confirmed.connect(_on_save_confirmed)
	load_confirm.confirmed.connect(_on_load_confirmed)
	_build_save_slot_rows()
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
	_refresh_save_slots()
	_refresh_audio_options()
	close_button.grab_focus()


func close_top_ui() -> void:
	if not visible:
		return
	_close_settings_ui()


func _close_settings_ui() -> void:
	visible = false
	get_tree().paused = _was_paused


func _on_tab_changed(_tab_index: int) -> void:
	_apply_responsive_layout()
	if tabs.current_tab == 1:
		_refresh_audio_options()


func _configure_audio_options() -> void:
	mute_check.text = "静音"
	reset_audio_button.text = "恢复默认音量"
	for slider in [master_volume_slider, bgm_volume_slider, sfx_volume_slider]:
		slider.min_value = 0.0
		slider.max_value = 100.0
		slider.step = 1.0
	_refresh_audio_options()


func _refresh_audio_options() -> void:
	var settings: Dictionary = AudioManager.get_audio_settings()
	master_volume_slider.set_value_no_signal(float(settings.get("master_volume", 100.0)))
	bgm_volume_slider.set_value_no_signal(float(settings.get("bgm_volume", 100.0)))
	sfx_volume_slider.set_value_no_signal(float(settings.get("sfx_volume", 100.0)))
	mute_check.set_pressed_no_signal(bool(settings.get("muted", false)))
	_update_audio_volume_labels()
	if _is_web_runtime() and not AudioManager.is_web_audio_unlocked():
		audio_status_label.text = "网页声音尚未启用：点击游戏画面即可开启。"
	else:
		audio_status_label.text = "音量设置会自动保存。"


func _update_audio_volume_labels() -> void:
	master_volume_value.text = "%d%%" % roundi(master_volume_slider.value)
	bgm_volume_value.text = "%d%%" % roundi(bgm_volume_slider.value)
	sfx_volume_value.text = "%d%%" % roundi(sfx_volume_slider.value)


func _on_master_volume_changed(value: float) -> void:
	AudioManager.set_master_volume(value)
	_update_audio_volume_labels()


func _on_bgm_volume_changed(value: float) -> void:
	AudioManager.set_bgm_volume(value)
	_update_audio_volume_labels()


func _on_sfx_volume_changed(value: float) -> void:
	AudioManager.set_sfx_volume(value)
	_update_audio_volume_labels()


func _on_mute_toggled(pressed: bool) -> void:
	AudioManager.set_muted(pressed)


func _on_reset_audio_pressed() -> void:
	AudioManager.reset_audio_settings()
	_refresh_audio_options()


func _on_apply_pressed() -> void:
	if _is_web_runtime():
		_apply_web_display_settings()
		return
	_apply_display_settings(true)
	status_label.text = "显示设置已应用并保存。"


func _on_main_menu_pressed() -> void:
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.scene_file_path == TITLE_SCREEN_SCENE:
		_close_settings_ui()
		return
	# 返回主菜单前刷新一次自动存档，确保“继续游戏”恢复到离开前的状态。
	var availability: Dictionary = GameState.get_manual_save_availability()
	if bool(availability.get("allowed", false)):
		GameState.save_game(GameState.AUTO_SAVE_PATH)
	visible = false
	get_tree().paused = false
	get_tree().change_scene_to_file(TITLE_SCREEN_SCENE)


func _build_save_slot_rows() -> void:
	for child in save_list.get_children():
		child.queue_free()
	_slot_rows.clear()
	for slot in range(1, GameState.MANUAL_SAVE_SLOT_COUNT + 1):
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, 64)
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var save_button := Button.new()
		save_button.text = "保存"
		save_button.custom_minimum_size = Vector2(76, 44)
		save_button.pressed.connect(_on_save_slot_pressed.bind(slot))
		var load_button := Button.new()
		load_button.text = "读取"
		load_button.custom_minimum_size = Vector2(76, 44)
		load_button.pressed.connect(_on_load_slot_pressed.bind(slot))
		row.add_child(label)
		row.add_child(save_button)
		row.add_child(load_button)
		save_list.add_child(row)
		_slot_rows.append({"label": label, "save": save_button, "load": load_button})


func _refresh_save_slots() -> void:
	var availability: Dictionary = GameState.get_manual_save_availability()
	var current_scene := get_tree().current_scene
	var is_title := current_scene != null and current_scene.scene_file_path == TITLE_SCREEN_SCENE
	var can_save := bool(availability.get("allowed", false)) and not is_title
	for index in range(_slot_rows.size()):
		var slot := index + 1
		var metadata: Dictionary = GameState.get_save_metadata(GameState.get_manual_save_path(slot))
		var row: Dictionary = _slot_rows[index]
		var label: Label = row["label"]
		var save_button: Button = row["save"]
		var load_button: Button = row["load"]
		label.text = _format_slot_metadata(slot, metadata)
		save_button.disabled = not can_save
		save_button.tooltip_text = "" if can_save else String(availability.get("reason", "当前阶段不能保存。"))
		load_button.disabled = not bool(metadata.get("valid", false))
		load_button.tooltip_text = "读取该存档" if not load_button.disabled else ("存档损坏" if bool(metadata.get("exists", false)) else "空槽位")


func _format_slot_metadata(slot: int, metadata: Dictionary) -> String:
	if not bool(metadata.get("exists", false)):
		return "槽位 %d｜空存档" % slot
	if not bool(metadata.get("valid", false)):
		return "槽位 %d｜存档损坏" % slot
	var minute := int(metadata.get("minute_of_day", 0))
	var game_time := "第%d天 %02d:%02d" % [int(metadata.get("day", 1)), minute / 60, minute % 60]
	var location := String(metadata.get("location_name", "未知地点"))
	var saved_at := String(metadata.get("saved_at_text", ""))
	return "槽位 %d｜%s｜%s\n%s" % [slot, game_time, location, saved_at]


func _on_save_slot_pressed(slot: int) -> void:
	var availability: Dictionary = GameState.get_manual_save_availability()
	if not bool(availability.get("allowed", false)):
		global_status_label.text = String(availability.get("reason", "当前阶段不能保存。"))
		_refresh_save_slots()
		return
	_pending_slot = slot
	var metadata: Dictionary = GameState.get_save_metadata(GameState.get_manual_save_path(slot))
	if bool(metadata.get("exists", false)):
		save_confirm.dialog_text = "槽位 %d 已有存档，确定覆盖吗？" % slot
		save_confirm.popup_centered()
		return
	_save_pending_slot()


func _on_save_confirmed() -> void:
	_save_pending_slot()


func _save_pending_slot() -> void:
	if _pending_slot < 1 or _pending_slot > GameState.MANUAL_SAVE_SLOT_COUNT:
		return
	var slot := _pending_slot
	_pending_slot = 0
	var error := GameState.save_game(GameState.get_manual_save_path(slot), true)
	global_status_label.text = "槽位 %d 保存成功。" % slot if error == OK else "保存失败：%s" % error_string(error)
	_refresh_save_slots()


func _on_load_slot_pressed(slot: int) -> void:
	var metadata: Dictionary = GameState.get_save_metadata(GameState.get_manual_save_path(slot))
	if not bool(metadata.get("valid", false)):
		global_status_label.text = "该槽位为空或已经损坏。"
		_refresh_save_slots()
		return
	_pending_slot = slot
	load_confirm.dialog_text = "读取槽位 %d 后会放弃当前未保存的进度，确定继续吗？" % slot
	load_confirm.popup_centered()


func _on_load_confirmed() -> void:
	if _pending_slot < 1 or _pending_slot > GameState.MANUAL_SAVE_SLOT_COUNT:
		return
	var slot := _pending_slot
	_pending_slot = 0
	visible = false
	get_tree().paused = false
	var error := GameState.load_game(GameState.get_manual_save_path(slot), true)
	if error == OK:
		return
	visible = true
	get_tree().paused = true
	global_status_label.text = "读取失败：%s" % error_string(error)
	_refresh_save_slots()


func _apply_display_settings(save_preferences: bool) -> void:
	if _is_web_runtime():
		return
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
	if _is_web_runtime():
		resolution_option.select(_get_web_display_size_index())
		mode_option.select(1 if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else 0)
		return
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


func _configure_display_options_for_platform(force_web: Variant = null) -> void:
	var is_web := _is_web_runtime() if force_web == null else bool(force_web)
	if not is_web:
		return
	display_options.visible = true
	apply_button.visible = true
	resolution_label.text = "画面尺寸"
	resolution_option.clear()
	resolution_option.add_item("自动（最高 1920 × 1080）")
	resolution_option.add_item("1280 × 720")
	resolution_option.add_item("1600 × 900")
	resolution_option.add_item("1920 × 1080")
	resolution_option.select(_get_web_display_size_index() if _is_web_runtime() else 0)
	resolution_option.disabled = false
	mode_label.text = "显示模式"
	mode_option.clear()
	mode_option.add_item("浏览器窗口")
	mode_option.add_item("浏览器全屏")
	mode_option.select(1 if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else 0)
	hint_label.text = "所选尺寸超过浏览器空间时会自动缩小；选择全屏后若浏览器询问权限，请允许。\n浏览器全屏时，Esc 会退出全屏；请使用 B 键返回游戏。"


func _apply_web_display_settings() -> void:
	if DisplayServer.get_name() == "headless":
		return
	JavaScriptBridge.eval("window.tianyuanSetDisplaySize && window.tianyuanSetDisplaySize(%d);" % resolution_option.selected)
	if mode_option.selected == 1:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		status_label.text = "显示尺寸已应用，已请求进入浏览器全屏。"
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		status_label.text = "显示尺寸已应用。"


func _get_web_display_size_index() -> int:
	if not _is_web_runtime():
		return 0
	var value: Variant = JavaScriptBridge.eval("window.tianyuanGetDisplaySize ? window.tianyuanGetDisplaySize() : 0;")
	if value is int or value is float:
		return clampi(int(value), 0, 3)
	return 0


func _is_web_runtime() -> bool:
	return OS.has_feature("web")


func _apply_responsive_layout() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var panel_width := minf(700.0, viewport_size.x - 32.0)
	var preferred_height := DISPLAY_PANEL_MAX_HEIGHT
	if tabs.current_tab == 2:
		preferred_height = SAVE_PANEL_MAX_HEIGHT
	elif tabs.current_tab == 1:
		preferred_height = AUDIO_PANEL_MAX_HEIGHT
	var panel_height := minf(preferred_height, viewport_size.y - 32.0)
	panel.offset_left = -panel_width * 0.5
	panel.offset_right = panel_width * 0.5
	panel.offset_top = -panel_height * 0.5
	panel.offset_bottom = panel_height * 0.5
