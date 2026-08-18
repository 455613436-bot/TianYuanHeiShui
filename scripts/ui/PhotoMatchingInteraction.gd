extends CanvasLayer
class_name PhotoMatchingInteraction
## 多图片场景匹配任务：显示场景局部，并要求玩家为每张图选择所属地点。

signal submitted(result: Dictionary)
signal closed

const DIALOGUE_BACKGROUND := preload("res://assets/ui/dialogue_panel.png")

var _overlay: Control
var _panel: TextureRect
var _content: VBoxContainer
var _title_label: Label
var _instruction_label: RichTextLabel
var _rows_scroll: ScrollContainer
var _rows_box: VBoxContainer
var _status_label: Label
var _submit_button: Button
var _close_button: Button

var _rows: Array[Dictionary] = []
var _active_interaction_id := ""
var _attempt_state_id := ""
var _submitted := false


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_shell()


func open_task(
	interaction_id: String,
	title: String,
	instruction: String,
	snippets: Array,
	options: Array,
	attempt_state_id: String
) -> void:
	_reset()
	_active_interaction_id = interaction_id
	_attempt_state_id = attempt_state_id
	_title_label.text = title
	_instruction_label.text = instruction
	_rows_scroll.show()
	_status_label.hide()
	_submit_button.show()
	_close_button.show()
	for index in range(snippets.size()):
		var snippet: Variant = snippets[index]
		if snippet is Dictionary:
			_add_matching_row(index, snippet as Dictionary, options)
	_update_submit_state()
	_overlay.show()
	_close_button.grab_focus()


func open_notice(title: String, text: String) -> void:
	_reset()
	_title_label.text = title
	_instruction_label.text = text
	_rows_scroll.hide()
	_status_label.hide()
	_submit_button.hide()
	_close_button.show()
	_overlay.show()
	_close_button.grab_focus()


func set_result_note(note: String) -> void:
	var clean := note.strip_edges()
	if clean.is_empty():
		return
	_status_label.text += ("\n\n" if not _status_label.text.is_empty() else "") + clean
	_status_label.show()


func _build_shell() -> void:
	_overlay = Control.new()
	_overlay.name = "PhotoMatchingOverlay"
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
	_panel.name = "PhotoMatchingPanel"
	_panel.texture = DIALOGUE_BACKGROUND
	_panel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_panel.stretch_mode = TextureRect.STRETCH_SCALE
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -540.0
	_panel.offset_top = -330.0
	_panel.offset_right = 540.0
	_panel.offset_bottom = 330.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(_panel)

	_content = VBoxContainer.new()
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.offset_left = 42.0
	_content.offset_top = 28.0
	_content.offset_right = -42.0
	_content.offset_bottom = -28.0
	_content.add_theme_constant_override("separation", 10)
	_panel.add_child(_content)

	_title_label = Label.new()
	_title_label.custom_minimum_size = Vector2(0, 42)
	_title_label.add_theme_font_size_override("font_size", 30)
	_title_label.add_theme_color_override("font_color", Color(0.11, 0.075, 0.035, 1.0))
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(_title_label)

	_instruction_label = RichTextLabel.new()
	_instruction_label.bbcode_enabled = true
	_instruction_label.fit_content = true
	_instruction_label.custom_minimum_size = Vector2(0, 56)
	_instruction_label.add_theme_font_size_override("normal_font_size", 18)
	_instruction_label.add_theme_color_override("default_color", Color(0.20, 0.15, 0.09, 1.0))
	_content.add_child(_instruction_label)

	_rows_scroll = ScrollContainer.new()
	_rows_scroll.custom_minimum_size = Vector2(0, 390)
	_rows_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(_rows_scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 8)
	_rows_scroll.add_child(_rows_box)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(0, 44)
	_status_label.add_theme_font_size_override("font_size", 17)
	_status_label.add_theme_color_override("font_color", Color(0.35, 0.55, 0.25, 1.0))
	_content.add_child(_status_label)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 14)
	_content.add_child(actions)

	_submit_button = Button.new()
	_submit_button.text = "提交匹配"
	_submit_button.custom_minimum_size = Vector2(180, 44)
	_submit_button.add_theme_font_size_override("font_size", 18)
	_submit_button.pressed.connect(_submit_task)
	actions.add_child(_submit_button)

	_close_button = Button.new()
	_close_button.text = "关闭"
	_close_button.custom_minimum_size = Vector2(140, 44)
	_close_button.add_theme_font_size_override("font_size", 18)
	_close_button.pressed.connect(close_interaction)
	actions.add_child(_close_button)


func _add_matching_row(index: int, snippet: Dictionary, options: Array) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 126)
	row.add_theme_constant_override("separation", 12)
	_rows_box.add_child(row)

	var label := Label.new()
	label.text = String(snippet.get("label", "局部 %d" % (index + 1)))
	label.custom_minimum_size = Vector2(62, 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	row.add_child(label)

	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(250, 118)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = _build_region_texture(snippet)
	row.add_child(preview)

	var choice := OptionButton.new()
	choice.custom_minimum_size = Vector2(240, 44)
	choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	choice.add_item("请选择场景")
	var row_options: Array = options.duplicate(true)
	row_options.shuffle()
	for raw_option in row_options:
		if raw_option is not Dictionary:
			continue
		var option: Dictionary = raw_option
		choice.add_item(String(option.get("label", option.get("id", "未知场景"))))
		choice.set_item_metadata(choice.item_count - 1, String(option.get("id", "")))
	choice.item_selected.connect(func(_selected: int) -> void:
		_update_submit_state()
	)
	row.add_child(choice)

	_rows.append({
		"choice": choice,
		"answer_id": String(snippet.get("answer_id", "")),
	})


func _build_region_texture(snippet: Dictionary) -> Texture2D:
	var image_path := String(snippet.get("image_path", "")).strip_edges()
	var source := load(image_path) as Texture2D
	if source == null:
		return null
	var region: Rect2 = snippet.get("region", Rect2(0, 0, source.get_width(), source.get_height()))
	var atlas := AtlasTexture.new()
	atlas.atlas = source
	atlas.region = region
	return atlas


func _update_submit_state() -> void:
	if _submit_button == null:
		return
	_submit_button.disabled = _submitted or not _all_rows_filled()


func _all_rows_filled() -> bool:
	if _rows.is_empty():
		return false
	for row in _rows:
		var choice: OptionButton = row.get("choice") as OptionButton
		if choice == null or choice.selected <= 0:
			return false
	return true


func _submit_task() -> void:
	if _submitted or not _all_rows_filled():
		return
	_submitted = true
	var attempt_day := TimeSystem.current_day
	var correct_count := 0
	for row in _rows:
		var choice: OptionButton = row.get("choice") as OptionButton
		var selected_id := String(choice.get_item_metadata(choice.selected))
		if selected_id == String(row.get("answer_id", "")):
			correct_count += 1
	var total := _rows.size()
	var passed := correct_count == total
	GameState.set_investigation_state(_attempt_state_id, {
		"day": attempt_day,
		"correct": correct_count,
		"total": total,
		"passed": passed,
	})
	TimeSystem.on_dialogue_turn_completed()
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	for row in _rows:
		var choice: OptionButton = row.get("choice") as OptionButton
		choice.disabled = true
	_submit_button.disabled = true
	_status_label.text = (
		"全部匹配正确！"
		if passed
		else "本次有 %d/%d 张匹配正确。今天不能再次尝试，明天可以重新核对。" % [correct_count, total]
	)
	_status_label.add_theme_color_override(
		"font_color",
		Color(0.25, 0.60, 0.30, 1.0) if passed else Color(0.70, 0.32, 0.20, 1.0)
	)
	_status_label.show()
	submitted.emit({
		"interaction_id": _active_interaction_id,
		"passed": passed,
		"correct": correct_count,
		"total": total,
		"day": attempt_day,
	})


func close_interaction() -> void:
	if _overlay != null:
		_overlay.hide()
	closed.emit()


func _reset() -> void:
	if _rows_box != null:
		for child in _rows_box.get_children():
			child.queue_free()
	_rows.clear()
	_active_interaction_id = ""
	_attempt_state_id = ""
	_submitted = false
	if _status_label != null:
		_status_label.text = ""
		_status_label.hide()


func _on_dimmer_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close_interaction()


func _unhandled_input(event: InputEvent) -> void:
	if _overlay == null or not _overlay.visible:
		return
	if event.is_action_pressed("cancel_or_back"):
		close_interaction()
		get_viewport().set_input_as_handled()
