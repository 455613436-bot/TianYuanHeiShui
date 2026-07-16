extends Control
## 属性分配界面：把 ATTRIBUTE_TOTAL_POINTS 点分配到四维，每维 0-5。
## 按下"开始冒险"后写入 GameState 并切到首场景。

const NEXT_SCENE_PATH := "res://scenes/map/WorldMap.tscn"

@onready var remaining_label: Label = $Panel/VBox/HeaderRow/RemainingLabel
@onready var start_btn: Button = $Panel/VBox/Footer/StartBtn
@onready var rows_container: VBoxContainer = $Panel/VBox/Rows
@onready var reset_btn: Button = $Panel/VBox/Footer/ResetBtn
@onready var tip_label: Label = $Panel/VBox/TipLabel

var _values: Dictionary = {}
var _rows: Dictionary = {}  # key -> {label, value_label, minus, plus}


func _ready() -> void:
	# 若已经分配过，直接跳过（避免重复弹出）
	if GameState.attributes_allocated():
		call_deferred("_go_next")
		return

	for key in GameState.ATTRIBUTE_KEYS:
		_values[key] = 0

	# 建议起手每项 2 或 3（视觉起点更友好）
	var starter := {"strength": 3, "agility": 3, "intellect": 2, "charisma": 2}
	if starter.values().reduce(func(a, b): return a + b, 0) == GameState.ATTRIBUTE_TOTAL_POINTS:
		_values = starter.duplicate(true)

	for key in GameState.ATTRIBUTE_KEYS:
		_build_row(key)
	start_btn.pressed.connect(_on_start_pressed)
	reset_btn.pressed.connect(_on_reset_pressed)
	_refresh_all()


func _build_row(key: String) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 56)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 20)

	var label := Label.new()
	label.text = "%s（%s）" % [GameState.ATTRIBUTE_LABELS.get(key, key), _description_for(key)]
	label.custom_minimum_size = Vector2(360, 0)
	label.add_theme_font_size_override("font_size", 22)
	row.add_child(label)

	var minus_btn := Button.new()
	minus_btn.text = "−"
	minus_btn.custom_minimum_size = Vector2(48, 48)
	minus_btn.add_theme_font_size_override("font_size", 28)
	minus_btn.pressed.connect(func(): _adjust(key, -1))
	row.add_child(minus_btn)

	var value_label := Label.new()
	value_label.text = "0"
	value_label.custom_minimum_size = Vector2(52, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value_label.add_theme_font_size_override("font_size", 32)
	value_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.7))
	row.add_child(value_label)

	var plus_btn := Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size = Vector2(48, 48)
	plus_btn.add_theme_font_size_override("font_size", 28)
	plus_btn.pressed.connect(func(): _adjust(key, +1))
	row.add_child(plus_btn)

	rows_container.add_child(row)
	_rows[key] = {
		"label": label,
		"value_label": value_label,
		"minus": minus_btn,
		"plus": plus_btn,
	}


func _description_for(key: String) -> String:
	match key:
		"strength": return "对抗、威胁、破门等硬碰硬"
		"agility": return "潜行、扒窃、闪避、快速动作"
		"intellect": return "观察、推理、专业知识、拆解"
		"charisma": return "说服、忽悠、恳求、社交周旋"
	return ""


func _adjust(key: String, delta: int) -> void:
	var current := int(_values.get(key, 0))
	var target := clampi(current + delta, GameState.ATTRIBUTE_MIN, GameState.ATTRIBUTE_MAX)
	if target == current:
		return
	if delta > 0 and _spent() + (target - current) > GameState.ATTRIBUTE_TOTAL_POINTS:
		return
	_values[key] = target
	_refresh_all()


func _spent() -> int:
	var total := 0
	for key in GameState.ATTRIBUTE_KEYS:
		total += int(_values.get(key, 0))
	return total


func _remaining() -> int:
	return GameState.ATTRIBUTE_TOTAL_POINTS - _spent()


func _refresh_all() -> void:
	var remaining := _remaining()
	remaining_label.text = "剩余点数：%d / %d" % [remaining, GameState.ATTRIBUTE_TOTAL_POINTS]
	if remaining == 0:
		remaining_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	else:
		remaining_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.55))

	for key in GameState.ATTRIBUTE_KEYS:
		var row: Dictionary = _rows.get(key, {})
		if row.is_empty():
			continue
		var v := int(_values.get(key, 0))
		(row["value_label"] as Label).text = str(v)
		(row["minus"] as Button).disabled = v <= GameState.ATTRIBUTE_MIN
		(row["plus"] as Button).disabled = v >= GameState.ATTRIBUTE_MAX or remaining <= 0

	start_btn.disabled = remaining != 0
	if remaining == 0:
		tip_label.text = "确认分配后不可更改。"
		tip_label.add_theme_color_override("font_color", Color(0.75, 1.0, 0.8))
	else:
		tip_label.text = "把剩余点数分配完毕后即可开始冒险。"
		tip_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))


func _on_reset_pressed() -> void:
	for key in GameState.ATTRIBUTE_KEYS:
		_values[key] = 0
	_refresh_all()


func _on_start_pressed() -> void:
	if _remaining() != 0:
		return
	var ok := GameState.set_attributes(_values, true)
	if not ok:
		tip_label.text = "分配数据不合法，请检查后重试。"
		tip_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
		return
	_go_next()


func _go_next() -> void:
	var target := NEXT_SCENE_PATH
	if not ResourceLoader.exists(target):
		target = GameState.DEFAULT_MAP_RETURN_SCENE
	get_tree().change_scene_to_file(target)
