extends Control
## 属性分配界面：使用调查员档案素材，把 10 点分配到四项属性。

const NEXT_SCENE_PATH := "res://scenes/locations/TemporaryDorm.tscn"
const ROW_SIZE := Vector2(441, 71)
const ROW_STEP := 72.0
const ROW_TEXTURES := {
	"strength": preload("res://assets/ui/attribute_allocation/row_strength.png"),
	"agility": preload("res://assets/ui/attribute_allocation/row_agility.png"),
	"intellect": preload("res://assets/ui/attribute_allocation/row_intellect.png"),
	"charisma": preload("res://assets/ui/attribute_allocation/row_charisma.png"),
}
const MINUS_TEXTURE := preload("res://assets/ui/attribute_allocation/button_minus.png")
const PLUS_TEXTURE := preload("res://assets/ui/attribute_allocation/button_plus.png")
const UI_FONT := preload("res://assets/fonts/SourceHanSerifSC-SemiBold.otf")

@onready var remaining_label: Label = $Paper/Content/RemainingFrame/RemainingLabel
@onready var start_btn: TextureButton = $Paper/Content/Footer/StartBtn
@onready var rows_container: Control = $Paper/Content/Rows
@onready var reset_btn: TextureButton = $Paper/Content/Footer/ResetBtn
@onready var tip_label: Label = $Paper/Content/TipLabel

var _values: Dictionary = {}
var _rows: Dictionary = {}


func _ready() -> void:
	if GameState.attributes_allocated():
		call_deferred("_go_next")
		return

	var starter := {"strength": 3, "agility": 3, "intellect": 2, "charisma": 2}
	for key in GameState.ATTRIBUTE_KEYS:
		_values[key] = int(starter.get(key, 0))
		_build_row(key)

	start_btn.pressed.connect(_on_start_pressed)
	reset_btn.pressed.connect(_on_reset_pressed)
	_configure_large_button(start_btn)
	_configure_large_button(reset_btn)
	_refresh_all()
	start_btn.grab_focus()


func _build_row(key: String) -> void:
	var row_index := _rows.size()
	var row := Control.new()
	row.name = "%sRow" % key.capitalize()
	row.position = Vector2(0, row_index * ROW_STEP)
	row.size = ROW_SIZE
	rows_container.add_child(row)

	var artwork := TextureRect.new()
	artwork.name = "Artwork"
	artwork.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	artwork.mouse_filter = Control.MOUSE_FILTER_IGNORE
	artwork.texture = ROW_TEXTURES.get(key)
	artwork.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	artwork.stretch_mode = TextureRect.STRETCH_SCALE
	row.add_child(artwork)

	var minus_btn := _create_adjust_button(MINUS_TEXTURE, Rect2(290, 9, 49, 48))
	minus_btn.name = "Minus"
	minus_btn.tooltip_text = "减少%s" % GameState.ATTRIBUTE_LABELS.get(key, key)
	minus_btn.pressed.connect(_adjust.bind(key, -1))
	row.add_child(minus_btn)

	var value_label := Label.new()
	value_label.name = "Value"
	value_label.position = Vector2(340, 4)
	value_label.size = Vector2(51, 54)
	value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.add_theme_font_override("font", UI_FONT)
	value_label.add_theme_font_size_override("font_size", 31)
	value_label.add_theme_color_override("font_color", Color(0.16, 0.09, 0.03, 1.0))
	row.add_child(value_label)

	var plus_btn := _create_adjust_button(PLUS_TEXTURE, Rect2(392, 9, 49, 48))
	plus_btn.name = "Plus"
	plus_btn.tooltip_text = "增加%s" % GameState.ATTRIBUTE_LABELS.get(key, key)
	plus_btn.pressed.connect(_adjust.bind(key, 1))
	row.add_child(plus_btn)

	_rows[key] = {
		"value_label": value_label,
		"minus": minus_btn,
		"plus": plus_btn,
	}


func _create_adjust_button(texture: Texture2D, rect: Rect2) -> TextureButton:
	var button := TextureButton.new()
	button.position = rect.position
	button.size = rect.size
	button.texture_normal = texture
	button.ignore_texture_size = true
	button.stretch_mode = TextureButton.STRETCH_SCALE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_entered.connect(_set_button_hover.bind(button, true))
	button.mouse_exited.connect(_set_button_hover.bind(button, false))
	return button


func _configure_large_button(button: TextureButton) -> void:
	button.mouse_entered.connect(_set_button_hover.bind(button, true))
	button.mouse_exited.connect(_set_button_hover.bind(button, false))
	button.focus_entered.connect(_set_button_hover.bind(button, true))
	button.focus_exited.connect(_set_button_hover.bind(button, false))


func _set_button_hover(button: TextureButton, hovered: bool) -> void:
	if button.disabled:
		button.modulate = Color(0.66, 0.62, 0.56, 0.72)
	else:
		button.modulate = Color(1.08, 1.05, 0.92, 1.0) if hovered else Color.WHITE


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
	remaining_label.add_theme_color_override(
		"font_color",
		Color(0.22, 0.30, 0.16, 1.0) if remaining == 0 else Color(0.38, 0.20, 0.07, 1.0)
	)

	for key in GameState.ATTRIBUTE_KEYS:
		var row: Dictionary = _rows.get(key, {})
		if row.is_empty():
			continue
		var value := int(_values.get(key, 0))
		(row["value_label"] as Label).text = str(value)
		var minus_button := row["minus"] as TextureButton
		var plus_button := row["plus"] as TextureButton
		minus_button.disabled = value <= GameState.ATTRIBUTE_MIN
		plus_button.disabled = value >= GameState.ATTRIBUTE_MAX or remaining <= 0
		_set_button_hover(minus_button, false)
		_set_button_hover(plus_button, false)

	start_btn.disabled = remaining != 0
	_set_button_hover(start_btn, false)
	tip_label.visible = false


func _on_reset_pressed() -> void:
	for key in GameState.ATTRIBUTE_KEYS:
		_values[key] = 0
	_refresh_all()


func _on_start_pressed() -> void:
	if _remaining() != 0:
		return
	if not GameState.set_attributes(_values, true):
		tip_label.text = "分配数据不合法，请检查后重试。"
		tip_label.visible = true
		return
	_go_next()


func _go_next() -> void:
	var target := NEXT_SCENE_PATH
	if not ResourceLoader.exists(target):
		target = GameState.DEFAULT_MAP_RETURN_SCENE
	get_tree().change_scene_to_file(target)
