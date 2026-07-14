extends Control
## 田原村地图选择界面。
## 热点位置使用相对于原始地图的归一化坐标，因此窗口缩放后仍能对齐。

const MAP_PIXEL_SIZE := Vector2(1518.0, 969.0)
const HOTSPOT_SIZE := Vector2(82.0, 82.0)
const DEFAULT_RETURN_SCENE := "res://scenes/main/Main.tscn"

const LOCATIONS := [
	{
		"number": "0",
		"name": "村口广场",
		"description": "外乡人进入田原村的第一站，可以遇见村长与湖边老人。",
		"position": Vector2(0.137, 0.468),
		"scene": "res://scenes/main/Main.tscn",
	},
	{
		"number": "2",
		"name": "村委会",
		"description": "蓝瓦白墙的村务中心，保管着村庄档案与重要物品。",
		"position": Vector2(0.296, 0.431),
		"scene": "res://scenes/locations/VillageCommittee.tscn",
	},
	{
		"number": "3",
		"name": "村长家",
		"description": "村长吴志源的住处，也许藏着不愿示人的秘密。",
		"position": Vector2(0.303, 0.263),
		"scene": "res://scenes/locations/VillageChiefHouse.tscn",
	},
	{
		"number": "4",
		"name": "旧工地",
		"description": "停工多年的施工区域，事故留下的痕迹仍未消失。",
		"position": Vector2(0.495, 0.306),
		"scene": "res://scenes/locations/ConstructionSite.tscn",
	},
	{
		"number": "5",
		"name": "北侧农田",
		"description": "受到村民精心照料的田地，作物生长得异常旺盛。",
		"position": Vector2(0.752, 0.094),
		"scene": "res://scenes/locations/Farmland.tscn",
	},
	{
		"number": "6",
		"name": "湖边码头",
		"description": "小船停靠在思源湖边，湖水深处似乎隐藏着什么。",
		"position": Vector2(0.677, 0.473),
		"scene": "res://scenes/locations/LakesideDock.tscn",
	},
	{
		"number": "7",
		"name": "后山入口",
		"description": "通往密林与山洞的小路，越往里走越令人不安。",
		"position": Vector2(0.178, 0.694),
		"scene": "res://scenes/locations/BackMountain.tscn",
	},
]

@onready var bottom_panel: Panel = $BottomPanel
@onready var top_shade: ColorRect = $TopShade
@onready var location_label: Label = $BottomPanel/LocationLabel
@onready var hint_label: Label = $BottomPanel/HintLabel

var _hotspots: Array[Button] = []


func _ready() -> void:
	add_to_group("world_map")
	GameState.restore_current_scene()
	for location in LOCATIONS:
		_create_hotspot(location)
	resized.connect(_on_resized)
	call_deferred("_on_resized")
	location_label.text = "选择一个地点"
	hint_label.text = "移动鼠标查看地点 · 点击进入"

func _create_hotspot(location: Dictionary) -> void:
	var button := Button.new()
	button.name = "Location%s" % location["number"]
	button.text = String(location["number"])
	button.tooltip_text = "%s\n%s" % [location["name"], location["description"]]
	button.custom_minimum_size = HOTSPOT_SIZE
	button.size = HOTSPOT_SIZE
	button.pivot_offset = HOTSPOT_SIZE * 0.5
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.z_index = 5
	button.set_meta("map_position", location["position"])
	button.add_theme_font_size_override("font_size", 28)
	button.add_theme_color_override("font_color", Color(1.0, 0.95, 0.72))
	button.add_theme_color_override("font_hover_color", Color(0.12, 0.08, 0.02))
	button.add_theme_stylebox_override("normal", _make_hotspot_style(Color(0.05, 0.04, 0.03, 0.38), Color(1.0, 0.96, 0.78, 0.9)))
	button.add_theme_stylebox_override("hover", _make_hotspot_style(Color(1.0, 0.78, 0.18, 0.82), Color(1.0, 0.94, 0.55, 1.0), 5))
	button.add_theme_stylebox_override("pressed", _make_hotspot_style(Color(0.95, 0.45, 0.08, 0.9), Color.WHITE, 5))
	button.add_theme_stylebox_override("focus", _make_hotspot_style(Color(1.0, 0.78, 0.18, 0.45), Color.WHITE, 5))
	button.pressed.connect(_enter_location.bind(location))
	button.mouse_entered.connect(_on_hotspot_entered.bind(button, location))
	button.mouse_exited.connect(_on_hotspot_exited.bind(button))
	add_child(button)
	_hotspots.append(button)


func _make_hotspot_style(background: Color, border: Color, width: int = 3) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(41)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	style.shadow_size = 7
	return style


func _on_resized() -> void:
	_apply_responsive_layout()
	_layout_hotspots()


func _apply_responsive_layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var safe_margin := clampf(size.x * 0.08, 16.0, 180.0)
	bottom_panel.offset_left = safe_margin
	bottom_panel.offset_right = -safe_margin
	bottom_panel.offset_bottom = -clampf(size.y * 0.025, 12.0, 24.0)
	bottom_panel.offset_top = bottom_panel.offset_bottom - clampf(size.y * 0.15, 96.0, 126.0)
	var top_half_width := minf(220.0, size.x * 0.45)
	top_shade.offset_left = -top_half_width
	top_shade.offset_right = top_half_width
	var hotspot_diameter := clampf(minf(size.x, size.y) * 0.105, 52.0, 82.0)
	for button in _hotspots:
		button.custom_minimum_size = Vector2.ONE * hotspot_diameter
		button.size = Vector2.ONE * hotspot_diameter
		button.pivot_offset = button.size * 0.5
		button.add_theme_font_size_override("font_size", int(clampf(hotspot_diameter * 0.34, 18.0, 28.0)))

func _layout_hotspots() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var fit_scale: float = minf(size.x / MAP_PIXEL_SIZE.x, size.y / MAP_PIXEL_SIZE.y)
	var displayed_size := MAP_PIXEL_SIZE * fit_scale
	var map_origin := (size - displayed_size) * 0.5
	for button in _hotspots:
		var normalized_position: Vector2 = button.get_meta("map_position")
		button.position = map_origin + normalized_position * displayed_size - button.size * 0.5


func _on_hotspot_entered(button: Button, location: Dictionary) -> void:
	button.scale = Vector2(1.12, 1.12)
	location_label.text = "%s  ·  %s" % [location["number"], location["name"]]
	hint_label.text = String(location["description"])


func _on_hotspot_exited(button: Button) -> void:
	button.scale = Vector2.ONE
	location_label.text = "选择一个地点"
	hint_label.text = "移动鼠标查看地点 · 点击进入"


func is_ui_open() -> bool:
	return true


func close_top_ui() -> void:
	_close_map()


func _close_map() -> void:
	var error := GameState.close_world_map()
	if error != OK:
		location_label.text = "无法关闭地图"
		hint_label.text = "返回场景加载失败：%s" % error_string(error)

func _enter_location(location: Dictionary) -> void:
	var scene_path := String(location["scene"])
	var error := GameState.enter_location(scene_path)
	if error != OK:
		location_label.text = "无法进入 %s" % location["name"]
		hint_label.text = "场景加载失败：%s" % error_string(error)