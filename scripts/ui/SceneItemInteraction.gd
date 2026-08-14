extends CanvasLayer
class_name SceneItemInteraction
## 通用场景物品交互界面：支持资料预览和选项/输入交互，以及每天一次的属性检定。

signal choice_selected(interaction_id: String, choice_id: String, result: Dictionary)
signal paged_text_completed(interaction_id: String)
signal document_closed()

const DIALOGUE_BACKGROUND := preload("res://assets/ui/dialogue_panel.png")
const CHOICE_BACKGROUND := preload("res://assets/ui/choice_bg.png")
const CHOICE_HOVER_BACKGROUND := preload("res://assets/ui/choice_bg_hover.png")

var _overlay: Control
var _panel: TextureRect
var _content: VBoxContainer
var _title_label: Label
var _body_label: RichTextLabel
var _choice_row: HFlowContainer
var _input: LineEdit
var _status_label: RichTextLabel
var _close_button: Button
var _active_interaction_id := ""
var _document_viewport: Control
var _document_image: TextureRect
var _document_base_size := Vector2.ZERO
var _document_pan := Vector2.ZERO
var _document_zoom := 1.0
var _document_dragging := false
var _paged_text: Array[String] = []
var _paged_text_index := 0
var _paged_text_interaction_id := ""
var _paged_text_archive_entry: Dictionary = {}
var _document_clue_entry: Dictionary = {}
var _register_document_clue_on_close := false


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_shell()


func open_document(title: String, image_texture: Texture2D, clue_entry: Dictionary = {}, register_clue: bool = true, register_on_close: bool = false, description: String = "") -> void:
	_reset_to_choice_layout()
	_active_interaction_id = ""
	_document_clue_entry = clue_entry.duplicate(true)
	_register_document_clue_on_close = register_on_close and not clue_entry.is_empty()
	if register_clue and not register_on_close and not clue_entry.is_empty() and GameState.add_document_clue(clue_entry):
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		SceneItemInteraction.show_content_added_toast(String(clue_entry.get("title", title)), "线索册")
	_title_label.text = title
	_body_label.visible = not description.strip_edges().is_empty()
	_body_label.text = description
	_choice_row.hide()
	_input.hide()
	_status_label.hide()
	_panel.custom_minimum_size = Vector2(880, 0)
	_panel.offset_left = -440.0
	_panel.offset_right = 440.0
	_panel.offset_top = -300.0
	_panel.offset_bottom = 300.0
	_document_zoom = 1.0
	_document_pan = Vector2.ZERO
	_document_dragging = false

	_document_viewport = Control.new()
	_document_viewport.name = "DocumentViewport"
	_document_viewport.custom_minimum_size = Vector2(0, 390)
	_document_viewport.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_document_viewport.clip_contents = true
	_document_viewport.mouse_filter = Control.MOUSE_FILTER_STOP
	_document_viewport.mouse_default_cursor_shape = Control.CURSOR_DRAG
	_document_viewport.gui_input.connect(_on_document_viewport_input)
	_document_viewport.resized.connect(_on_document_viewport_resized)
	_content.add_child(_document_viewport)

	_document_image = TextureRect.new()
	_document_image.name = "DocumentImage"
	_document_image.texture = image_texture
	_document_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_document_image.stretch_mode = TextureRect.STRETCH_SCALE
	_document_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_document_viewport.add_child(_document_image)
	_show()
	call_deferred("_reset_document_view")


func open_choice(config: Dictionary) -> void:
	_reset_to_choice_layout()
	_active_interaction_id = String(config.get("id", ""))
	_title_label.text = String(config.get("title", "交互"))
	_body_label.show()
	_body_label.text = String(config.get("description", ""))
	_input.placeholder_text = String(config.get("input_placeholder", ""))
	_input.visible = bool(config.get("allow_input", false))
	for raw_choice in config.get("choices", []):
		if raw_choice is Dictionary:
			_add_choice_button(raw_choice)
	_show()


func open_paged_text(title: String, pages: Array[String], interaction_id: String = "", archive_entry: Dictionary = {}) -> void:
	_reset_to_choice_layout()
	if pages.is_empty():
		return
	_paged_text = pages.duplicate()
	_paged_text_index = 0
	_paged_text_interaction_id = interaction_id
	_paged_text_archive_entry = archive_entry.duplicate(true)
	_active_interaction_id = interaction_id
	_title_label.text = title
	_body_label.show()
	_input.hide()
	_status_label.hide()
	_show_paged_text_page()
	_show()


func _show_paged_text_page() -> void:
	for child in _choice_row.get_children():
		child.queue_free()
	if _paged_text.is_empty() or _paged_text_index >= _paged_text.size():
		return
	_body_label.text = _paged_text[_paged_text_index]
	var button := Button.new()
	var is_last_page := _paged_text_index >= _paged_text.size() - 1
	button.text = "完成" if is_last_page else "确认"
	button.custom_minimum_size = Vector2(150, 42)
	button.add_theme_font_size_override("font_size", 19)
	button.add_theme_color_override("font_color", Color(0.16, 0.12, 0.08, 1.0))
	button.add_theme_stylebox_override("normal", _choice_style(CHOICE_BACKGROUND))
	button.add_theme_stylebox_override("hover", _choice_style(CHOICE_HOVER_BACKGROUND))
	button.add_theme_stylebox_override("pressed", _choice_style(CHOICE_BACKGROUND))
	button.pressed.connect(_advance_paged_text)
	_choice_row.add_child(button)


func _advance_paged_text() -> void:
	if _paged_text_index < _paged_text.size() - 1:
		_paged_text_index += 1
		_show_paged_text_page()
		return
	if not _paged_text_archive_entry.is_empty() and GameState.add_document_clue(_paged_text_archive_entry):
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		SceneItemInteraction.show_content_added_toast(String(_paged_text_archive_entry.get("title", _title_label.text)), "线索册")
	paged_text_completed.emit(_paged_text_interaction_id)
	close_interaction()


func close_interaction() -> void:
	var closing_document := _document_viewport != null
	var deferred_clue_entry := _document_clue_entry.duplicate(true)
	var should_register := _register_document_clue_on_close
	if _overlay != null:
		_overlay.hide()
	_active_interaction_id = ""
	_document_clue_entry = {}
	_register_document_clue_on_close = false
	if should_register and GameState.add_document_clue(deferred_clue_entry):
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		SceneItemInteraction.show_content_added_toast(String(deferred_clue_entry.get("title", "资料")), "线索册")
	if closing_document:
		document_closed.emit()


## 通用顶部加入通知，今后的线索、背包物品和技能系统均可复用。
## 独立使用高层 CanvasLayer，保证不会被资料阅读器的暗幕或其他弹窗压暗。
static func show_content_added_toast(content_title: String, destination: String) -> void:
	var scene_tree := Engine.get_main_loop() as SceneTree
	if scene_tree == null or scene_tree.current_scene == null:
		return
	var toast_layer := CanvasLayer.new()
	toast_layer.name = "ContentAddedToastLayer"
	toast_layer.layer = 100
	scene_tree.current_scene.add_child(toast_layer)

	var toast := PanelContainer.new()
	toast.name = "ContentAddedToast"
	toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast.offset_left = -250.0
	toast.offset_top = 28.0
	toast.offset_right = 250.0
	toast.offset_bottom = 78.0
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var toast_style := StyleBoxFlat.new()
	toast_style.bg_color = Color(0.08, 0.12, 0.14, 0.98)
	toast_style.border_color = Color(0.72, 0.92, 1.0, 1.0)
	toast_style.set_border_width_all(2)
	toast_style.set_corner_radius_all(8)
	toast.add_theme_stylebox_override("panel", toast_style)
	var label := Label.new()
	label.text = "%s 已加入%s" % [content_title, destination]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 19)
	label.add_theme_color_override("font_color", Color(0.9, 0.97, 1.0, 1.0))
	toast.add_child(label)
	toast_layer.add_child(toast)
	var tween := toast_layer.create_tween()
	tween.tween_interval(2.4)
	tween.tween_property(toast, "modulate:a", 0.0, 0.65)
	tween.tween_callback(toast_layer.queue_free)


func _build_shell() -> void:
	_overlay = Control.new()
	_overlay.name = "SceneItemInteractionOverlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	add_child(_overlay)

	var dimmer := ColorRect.new()
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dimmer.color = Color(0.02, 0.04, 0.05, 0.72)
	dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	dimmer.gui_input.connect(_on_dimmer_input)
	_overlay.add_child(dimmer)

	_panel = TextureRect.new()
	_panel.name = "InteractionPanel"
	_panel.texture = DIALOGUE_BACKGROUND
	_panel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_panel.stretch_mode = TextureRect.STRETCH_SCALE
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -390.0
	_panel.offset_top = -150.0
	_panel.offset_right = 390.0
	_panel.offset_bottom = 150.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(_panel)

	_content = VBoxContainer.new()
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.offset_left = 48.0
	_content.offset_top = 32.0
	_content.offset_right = -48.0
	_content.offset_bottom = -30.0
	_content.add_theme_constant_override("separation", 10)
	_panel.add_child(_content)

	_title_label = Label.new()
	_title_label.custom_minimum_size = Vector2(0, 42)
	_title_label.add_theme_font_size_override("font_size", 32)
	_title_label.add_theme_color_override("font_color", Color(0.11, 0.075, 0.035, 1.0))
	_title_label.add_theme_color_override("font_outline_color", Color(0.92, 0.78, 0.47, 0.72))
	_title_label.add_theme_constant_override("outline_size", 1)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_content.add_child(_title_label)

	_body_label = RichTextLabel.new()
	_body_label.bbcode_enabled = true
	_body_label.fit_content = true
	_body_label.custom_minimum_size = Vector2(0, 70)
	_body_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_label.add_theme_font_size_override("normal_font_size", 19)
	_body_label.add_theme_color_override("default_color", Color(0.20, 0.15, 0.09, 1.0))
	_content.add_child(_body_label)

	_input = LineEdit.new()
	_input.visible = false
	_input.custom_minimum_size = Vector2(0, 38)
	_input.add_theme_font_size_override("font_size", 18)
	_content.add_child(_input)

	_choice_row = HFlowContainer.new()
	_choice_row.custom_minimum_size = Vector2(0, 44)
	_choice_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_choice_row.alignment = FlowContainer.ALIGNMENT_CENTER
	_choice_row.add_theme_constant_override("h_separation", 12)
	_choice_row.add_theme_constant_override("v_separation", 8)
	_content.add_child(_choice_row)

	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.visible = false
	_status_label.custom_minimum_size = Vector2(0, 52)
	_status_label.add_theme_font_size_override("normal_font_size", 17)
	_content.add_child(_status_label)

	_close_button = Button.new()
	_close_button.text = "×"
	_close_button.tooltip_text = "关闭"
	_close_button.anchor_left = 1.0
	_close_button.anchor_right = 1.0
	_close_button.offset_left = -50.0
	_close_button.offset_top = 8.0
	_close_button.offset_right = -10.0
	_close_button.offset_bottom = 46.0
	_close_button.add_theme_font_size_override("font_size", 26)
	_close_button.pressed.connect(close_interaction)
	_panel.add_child(_close_button)


func _reset_to_choice_layout() -> void:
	_paged_text = []
	_paged_text_index = 0
	_paged_text_interaction_id = ""
	_paged_text_archive_entry = {}
	_document_clue_entry = {}
	_register_document_clue_on_close = false
	if _document_viewport != null:
		_document_viewport.queue_free()
		_document_viewport = null
		_document_image = null
		_document_base_size = Vector2.ZERO
		_document_pan = Vector2.ZERO
		_document_dragging = false
	for child in _choice_row.get_children():
		child.queue_free()
	_panel.custom_minimum_size = Vector2.ZERO
	_panel.offset_left = -390.0
	_panel.offset_right = 390.0
	_panel.offset_top = -150.0
	_panel.offset_bottom = 150.0
	_choice_row.show()
	_status_label.hide()


func _reset_document_view() -> void:
	if _document_viewport == null or _document_image == null or _document_image.texture == null:
		return
	var source_size := _document_image.texture.get_size()
	if source_size.x <= 0.0 or source_size.y <= 0.0 or _document_viewport.size.x <= 0.0 or _document_viewport.size.y <= 0.0:
		return
	var fit_scale := minf(_document_viewport.size.x / source_size.x, _document_viewport.size.y / source_size.y)
	_document_base_size = source_size * fit_scale
	_document_zoom = 1.0
	_document_pan = Vector2.ZERO
	_apply_document_transform()


func _apply_document_transform() -> void:
	if _document_viewport == null or _document_image == null:
		return
	var scaled_size := _document_base_size * _document_zoom
	var max_pan := Vector2(
		maxf(0.0, (scaled_size.x - _document_viewport.size.x) * 0.5),
		maxf(0.0, (scaled_size.y - _document_viewport.size.y) * 0.5)
	)
	_document_pan.x = clampf(_document_pan.x, -max_pan.x, max_pan.x)
	_document_pan.y = clampf(_document_pan.y, -max_pan.y, max_pan.y)
	_document_image.size = scaled_size
	_document_image.position = (_document_viewport.size - scaled_size) * 0.5 + _document_pan


func _on_document_viewport_resized() -> void:
	if _document_zoom <= 1.0:
		_reset_document_view()
	else:
		var source_size := _document_image.texture.get_size() if _document_image != null and _document_image.texture != null else Vector2.ZERO
		if source_size.x <= 0.0 or source_size.y <= 0.0 or _document_viewport.size.x <= 0.0 or _document_viewport.size.y <= 0.0:
			return
		var fit_scale := minf(_document_viewport.size.x / source_size.x, _document_viewport.size.y / source_size.y)
		_document_base_size = source_size * fit_scale
		_apply_document_transform()


func _on_document_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_document_zoom = minf(_document_zoom + 0.15, 3.0)
			_apply_document_transform()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_document_zoom = maxf(_document_zoom - 0.15, 1.0)
			_apply_document_transform()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_document_dragging = event.pressed and _document_zoom > 1.0
			_document_viewport.mouse_default_cursor_shape = Control.CURSOR_DRAG if _document_dragging else Control.CURSOR_ARROW
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _document_dragging:
		_document_pan += event.relative
		_apply_document_transform()
		get_viewport().set_input_as_handled()


func _add_choice_button(choice: Dictionary) -> void:
	var button := Button.new()
	button.text = String(choice.get("label", "继续"))
	button.custom_minimum_size = Vector2(150, 42)
	button.add_theme_font_size_override("font_size", 19)
	button.add_theme_color_override("font_color", Color(0.16, 0.12, 0.08, 1.0))
	button.add_theme_stylebox_override("normal", _choice_style(CHOICE_BACKGROUND))
	button.add_theme_stylebox_override("hover", _choice_style(CHOICE_HOVER_BACKGROUND))
	button.add_theme_stylebox_override("pressed", _choice_style(CHOICE_BACKGROUND))
	button.pressed.connect(func() -> void:
		_handle_choice(choice)
	)
	_choice_row.add_child(button)


func _choice_style(texture: Texture2D) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = texture
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	return style


func _handle_choice(choice: Dictionary) -> void:
	var choice_id := String(choice.get("id", ""))
	if bool(choice.get("close", false)):
		choice_selected.emit(_active_interaction_id, choice_id, {})
		close_interaction()
		return
	if String(choice.get("type", "")) == "check":
		_run_daily_check(choice)
		return
	choice_selected.emit(_active_interaction_id, choice_id, {"input": _input.text.strip_edges()})


func _run_daily_check(choice: Dictionary) -> void:
	if _active_interaction_id.is_empty():
		return
	var state_key := "item_check:%s" % _active_interaction_id
	var check_state: Variant = GameState.get_investigation_state(state_key, {})
	if check_state is Dictionary and int(check_state.get("day", 0)) == TimeSystem.current_day:
		_show_status("[color=indian_red]今天已经尝试过了，明天再来吧。[/color]")
		return
	var result := CheckSystem.perform_check(
		String(choice.get("attribute", "敏捷")),
		int(choice.get("difficulty", 1)),
		0,
		String(choice.get("reason", ""))
	)
	GameState.set_investigation_state(state_key, {"day": TimeSystem.current_day})
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	var message := CheckSystem.result_to_display_text(result)
	var outcome_key := "success_text" if bool(result.get("passed", false)) else "failure_text"
	var outcome := String(choice.get(outcome_key, ""))
	if not outcome.is_empty():
		message += "\n" + outcome
	var status_color := "sea_green" if bool(result.get("passed", false)) else "indian_red"
	_show_status("[color=%s]%s[/color]" % [status_color, message])
	choice_selected.emit(_active_interaction_id, String(choice.get("id", "")), result)


func _show_status(message: String) -> void:
	_status_label.text = message
	_status_label.show()


func _show() -> void:
	_overlay.show()


func _on_dimmer_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close_interaction()


func _unhandled_input(event: InputEvent) -> void:
	if _overlay == null or not _overlay.visible:
		return
	if event.is_action_pressed("cancel_or_back"):
		close_interaction()
		get_viewport().set_input_as_handled()
		return
