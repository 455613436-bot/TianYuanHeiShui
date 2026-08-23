extends CanvasLayer
class_name AttributeRespecPopup
## 水潭专用属性重分配界面：总点数等于当前基础+永久成长总和，不包含每日临时修正。

signal completed(success: bool)

var _overlay: Control
var _remaining_label: Label
var _tip_label: Label
var _values: Dictionary = {}
var _rows: Dictionary = {}
var _total_points := 0


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("modal_ui")
	for key in GameState.ATTRIBUTE_KEYS:
		var value := int(GameState.attributes.get(key, 0))
		_values[key] = value
		_total_points += value
	_build_ui()
	_refresh()


func is_ui_open() -> bool:
	return _overlay != null and _overlay.visible


func close_top_ui() -> void:
	completed.emit(false)
	queue_free()


func can_close_for_navigation() -> bool:
	return true


func _build_ui() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dimmer := ColorRect.new()
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dimmer.color = Color(0.01, 0.04, 0.07, 0.88)
	_overlay.add_child(dimmer)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -360.0
	panel.offset_top = -275.0
	panel.offset_right = 360.0
	panel.offset_bottom = 275.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.12, 0.14, 0.98)
	style.border_color = Color(0.60, 0.88, 0.94, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", style)
	_overlay.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var title := Label.new()
	title.text = "水潭中的重置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color(0.84, 0.96, 1.0, 1.0))
	box.add_child(title)
	var description := Label.new()
	description.text = "冰冷的水包裹着你。你可以重新分配基础点数与锻炼获得的永久点数；当天临时加成不会计入。"
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	description.add_theme_font_size_override("font_size", 18)
	box.add_child(description)
	_remaining_label = Label.new()
	_remaining_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_remaining_label.add_theme_font_size_override("font_size", 20)
	box.add_child(_remaining_label)
	for key in GameState.ATTRIBUTE_KEYS:
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 18)
		var label := Label.new()
		label.text = String(GameState.ATTRIBUTE_LABELS.get(key, key))
		label.custom_minimum_size = Vector2(120, 42)
		label.add_theme_font_size_override("font_size", 22)
		row.add_child(label)
		var minus := Button.new()
		minus.text = "−"
		minus.custom_minimum_size = Vector2(46, 42)
		minus.add_theme_font_size_override("font_size", 24)
		minus.pressed.connect(func() -> void: _adjust(key, -1))
		row.add_child(minus)
		var value_label := Label.new()
		value_label.custom_minimum_size = Vector2(54, 42)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		value_label.add_theme_font_size_override("font_size", 28)
		row.add_child(value_label)
		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size = Vector2(46, 42)
		plus.add_theme_font_size_override("font_size", 24)
		plus.pressed.connect(func() -> void: _adjust(key, 1))
		row.add_child(plus)
		box.add_child(row)
		_rows[key] = {"minus": minus, "value": value_label, "plus": plus}
	_tip_label = Label.new()
	_tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip_label.add_theme_font_size_override("font_size", 17)
	box.add_child(_tip_label)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 18)
	var confirm := Button.new()
	confirm.text = "确认重置"
	confirm.custom_minimum_size = Vector2(150, 44)
	confirm.add_theme_font_size_override("font_size", 20)
	confirm.pressed.connect(_confirm)
	actions.add_child(confirm)
	var cancel := Button.new()
	cancel.text = "离开水潭"
	cancel.custom_minimum_size = Vector2(150, 44)
	cancel.add_theme_font_size_override("font_size", 20)
	cancel.pressed.connect(func() -> void:
		completed.emit(false)
		queue_free()
	)
	actions.add_child(cancel)
	box.add_child(actions)
	add_child(_overlay)


func _spent() -> int:
	var sum := 0
	for key in GameState.ATTRIBUTE_KEYS:
		sum += int(_values.get(key, 0))
	return sum


func _adjust(key: String, delta: int) -> void:
	var current := int(_values.get(key, 0))
	var target := clampi(current + delta, GameState.ATTRIBUTE_MIN, _total_points)
	if target == current:
		return
	if delta > 0 and _spent() + 1 > _total_points:
		return
	_values[key] = target
	_refresh()


func _refresh() -> void:
	var remaining := _total_points - _spent()
	_remaining_label.text = "可分配点数：%d / %d" % [remaining, _total_points]
	for key in GameState.ATTRIBUTE_KEYS:
		var row: Dictionary = _rows.get(key, {})
		var value := int(_values.get(key, 0))
		(row["value"] as Label).text = str(value)
		(row["minus"] as Button).disabled = value <= GameState.ATTRIBUTE_MIN
		(row["plus"] as Button).disabled = value >= _total_points or remaining <= 0
	_tip_label.text = "点数分配完毕后才能确认。" if remaining != 0 else "水面映出另一种可能的你。"


func _confirm() -> void:
	if _spent() != _total_points:
		return
	if GameState.respec_attributes(_values):
		completed.emit(true)
		queue_free()
