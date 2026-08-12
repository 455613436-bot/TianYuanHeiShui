extends CanvasLayer
class_name SceneItemInteraction
## 通用场景物品交互界面：支持资料预览和选项/输入交互，以及每天一次的属性检定。

signal choice_selected(interaction_id: String, choice_id: String, result: Dictionary)

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
var _document_image: TextureRect
var _document_zoom := 1.0


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_shell()


func open_document(title: String, image_texture: Texture2D) -> void:
	_reset_to_choice_layout()
	_active_interaction_id = ""
	_title_label.text = title
	_body_label.text = "滚动鼠标滚轮可缩放资料。"
	_choice_row.hide()
	_input.hide()
	_status_label.hide()
	_panel.custom_minimum_size = Vector2(880, 0)
	_panel.offset_left = -440.0
	_panel.offset_right = 440.0
	_panel.offset_top = -300.0
	_panel.offset_bottom = 300.0
	_document_zoom = 1.0
	_document_image = TextureRect.new()
	_document_image.name = "DocumentImage"
	_document_image.texture = image_texture
	_document_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_document_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_document_image.custom_minimum_size = Vector2(0, 390)
	_document_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_document_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_document_image)
	_show()


func open_choice(config: Dictionary) -> void:
	_reset_to_choice_layout()
	_active_interaction_id = String(config.get("id", ""))
	_title_label.text = String(config.get("title", "交互"))
	_body_label.text = String(config.get("description", ""))
	_input.placeholder_text = String(config.get("input_placeholder", ""))
	_input.visible = bool(config.get("allow_input", false))
	for raw_choice in config.get("choices", []):
		if raw_choice is Dictionary:
			_add_choice_button(raw_choice)
	_show()


func close_interaction() -> void:
	if _overlay != null:
		_overlay.hide()
	_active_interaction_id = ""


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
	_title_label.add_theme_font_size_override("font_size", 25)
	_title_label.add_theme_color_override("font_color", Color(0.16, 0.12, 0.08, 1.0))
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(_title_label)

	_body_label = RichTextLabel.new()
	_body_label.bbcode_enabled = true
	_body_label.fit_content = true
	_body_label.custom_minimum_size = Vector2(0, 70)
	_body_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_label.add_theme_font_size_override("normal_font_size", 20)
	_body_label.add_theme_color_override("default_color", Color(0.16, 0.12, 0.08, 1.0))
	_content.add_child(_body_label)

	_input = LineEdit.new()
	_input.visible = false
	_input.custom_minimum_size = Vector2(0, 38)
	_input.add_theme_font_size_override("font_size", 18)
	_content.add_child(_input)

	_choice_row = HFlowContainer.new()
	_choice_row.custom_minimum_size = Vector2(0, 44)
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
	if _document_image != null:
		_document_image.queue_free()
		_document_image = null
	for child in _choice_row.get_children():
		child.queue_free()
	_panel.custom_minimum_size = Vector2.ZERO
	_panel.offset_left = -390.0
	_panel.offset_right = 390.0
	_panel.offset_top = -150.0
	_panel.offset_bottom = 150.0
	_choice_row.show()
	_status_label.hide()


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
		_show_status("[color=#8a4a3c]今天已经尝试过了，明天再来吧。[/color]")
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
	_show_status("[color=%s]%s[/color]" % ["#387c52" if bool(result.get("passed", false)) else "#9b443a", message])
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
	if _document_image != null and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_document_zoom = minf(_document_zoom + 0.1, 2.5)
			_document_image.scale = Vector2.ONE * _document_zoom
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_document_zoom = maxf(_document_zoom - 0.1, 0.5)
			_document_image.scale = Vector2.ONE * _document_zoom
			get_viewport().set_input_as_handled()
