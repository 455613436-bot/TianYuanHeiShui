extends CanvasLayer
class_name ClueBookPopup
## 通用资料线索册：展示已发现的图片线索，并请求外部复用资料查看器。

signal view_requested(entry: Dictionary)
signal present_requested(entry: Dictionary)
signal action_requested(entry: Dictionary)
signal closed

const ROW_MIN_HEIGHT := 112.0
const THUMBNAIL_SIZE := Vector2(112, 82)

var _overlay: Control
var _list_box: VBoxContainer
var _empty_label: Label
var _hint_label: Label
var _title_label: Label
var _allow_present := false
var _action_mode := false
var _action_label := "使用"


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_shell()


func open_ui(entries: Array[Dictionary], allow_present: bool = false) -> void:
	_allow_present = allow_present
	_action_mode = false
	if _title_label != null:
		_title_label.text = "线索册"
	if _empty_label != null:
		_empty_label.text = "线索册中还没有资料。探索场景中的可交互物品吧。"
	if _hint_label != null:
		_hint_label.text = (
			"点击“查看”可重新阅读；点击“出示”可将线索交给当前 NPC 查看。"
			if _allow_present
			else "记录在调查中发现的资料与线索。点击“查看”可重新阅读。"
		)
	_rebuild(entries)
	_overlay.show()


## 复用线索册卡片布局展示技能、任务等通用操作列表。
func open_action_list(entries: Array[Dictionary], title: String, hint: String, action_label: String = "使用") -> void:
	_allow_present = false
	_action_mode = true
	_action_label = action_label.strip_edges() if not action_label.strip_edges().is_empty() else "使用"
	if _title_label != null:
		_title_label.text = title
	if _hint_label != null:
		_hint_label.text = hint
	if _empty_label != null:
		_empty_label.text = "当前场景没有可用项目。"
	_rebuild(entries)
	_overlay.show()


func close_ui() -> void:
	if _overlay != null:
		_overlay.hide()
	closed.emit()


func _build_shell() -> void:
	_overlay = Control.new()
	_overlay.name = "ClueBookOverlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	add_child(_overlay)

	var backdrop := ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.01, 0.01, 0.015, 0.68)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.gui_input.connect(_on_backdrop_input)
	_overlay.add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(760, 520)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.10, 0.09, 0.075, 0.98)
	panel_style.border_color = Color(0.68, 0.55, 0.32, 0.9)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(8)
	panel_style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	_title_label = Label.new()
	_title_label.text = "线索册"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_font_size_override("font_size", 27)
	_title_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.68, 1.0))
	header.add_child(_title_label)
	var close_button := Button.new()
	close_button.text = "关闭 (Esc)"
	close_button.custom_minimum_size = Vector2(96, 36)
	close_button.pressed.connect(close_ui)
	header.add_child(close_button)

	_hint_label = Label.new()
	_hint_label.text = "记录在调查中发现的资料与线索。点击“查看”可重新阅读。"
	_hint_label.add_theme_font_size_override("font_size", 14)
	_hint_label.add_theme_color_override("font_color", Color(0.78, 0.75, 0.66, 1.0))
	box.add_child(_hint_label)

	_empty_label = Label.new()
	_empty_label.text = "线索册中还没有资料。探索场景中的可交互物品吧。"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_label.add_theme_font_size_override("font_size", 17)
	_empty_label.add_theme_color_override("font_color", Color(0.72, 0.70, 0.65, 1.0))
	box.add_child(_empty_label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(720, 395)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 10)
	scroll.add_child(_list_box)


func _rebuild(entries: Array[Dictionary]) -> void:
	for child in _list_box.get_children():
		child.queue_free()
	_empty_label.visible = entries.is_empty()
	_list_box.get_parent().visible = not entries.is_empty()
	for entry in entries:
		_list_box.add_child(_build_row(entry))


func _build_row(entry: Dictionary) -> Control:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_MIN_HEIGHT)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row_style := StyleBoxFlat.new()
	row_style.bg_color = Color(0.17, 0.15, 0.11, 0.9)
	row_style.border_color = Color(0.42, 0.34, 0.22, 0.85)
	row_style.set_border_width_all(1)
	row_style.set_corner_radius_all(6)
	row_style.set_content_margin_all(10)
	row.add_theme_stylebox_override("panel", row_style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	row.add_child(hbox)

	var thumbnail_box := PanelContainer.new()
	thumbnail_box.custom_minimum_size = THUMBNAIL_SIZE
	var thumbnail_style := StyleBoxFlat.new()
	thumbnail_style.bg_color = Color(0.04, 0.035, 0.03, 1.0)
	thumbnail_style.border_color = Color(0.48, 0.38, 0.24, 1.0)
	thumbnail_style.set_border_width_all(1)
	thumbnail_box.add_theme_stylebox_override("panel", thumbnail_style)
	hbox.add_child(thumbnail_box)
	var image_path := String(entry.get("image_path", ""))
	var texture := load(image_path) as Texture2D if not image_path.is_empty() else null
	if texture != null:
		var thumbnail := TextureRect.new()
		thumbnail.texture = texture
		thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumbnail.mouse_filter = Control.MOUSE_FILTER_IGNORE
		thumbnail_box.add_child(thumbnail)
	else:
		var placeholder := Label.new()
		placeholder.text = String(entry.get("badge", "技能" if _action_mode else ("教程" if String(entry.get("entry_type", "")) == "text_pages" else "资料")))
		placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		placeholder.add_theme_font_size_override("font_size", 20)
		thumbnail_box.add_child(placeholder)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_theme_constant_override("separation", 6)
	hbox.add_child(text_box)
	var title := Label.new()
	title.text = String(entry.get("title", "未命名资料"))
	title.add_theme_font_size_override("font_size", 21)
	title.add_theme_color_override("font_color", Color(1.0, 0.93, 0.72, 1.0))
	text_box.add_child(title)
	var summary := Label.new()
	summary.text = String(entry.get("summary", ""))
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	summary.add_theme_font_size_override("font_size", 14)
	summary.add_theme_color_override("font_color", Color(0.82, 0.80, 0.74, 1.0))
	text_box.add_child(summary)

	if _allow_present:
		var present_button := Button.new()
		present_button.text = "出示"
		present_button.tooltip_text = "把这条线索出示给当前交谈的 NPC"
		present_button.custom_minimum_size = Vector2(88, 40)
		present_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		present_button.pressed.connect(func() -> void:
			present_requested.emit(entry.duplicate(true))
		)
		hbox.add_child(present_button)
	if _action_mode:
		var action_button := Button.new()
		action_button.text = _action_label
		action_button.tooltip_text = String(entry.get("action_tooltip", "%s这个项目" % _action_label))
		action_button.custom_minimum_size = Vector2(88, 40)
		action_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		action_button.pressed.connect(func() -> void:
			action_requested.emit(entry.duplicate(true))
			close_ui()
		)
		hbox.add_child(action_button)
		return row

	var view_button := Button.new()
	view_button.text = "查看"
	view_button.tooltip_text = "重新查看这份资料"
	view_button.custom_minimum_size = Vector2(88, 40)
	view_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	view_button.pressed.connect(func() -> void:
		view_requested.emit(entry.duplicate(true))
	)
	hbox.add_child(view_button)
	return row


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close_ui()


func _unhandled_input(event: InputEvent) -> void:
	if _overlay == null or not _overlay.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		close_ui()
		get_viewport().set_input_as_handled()
