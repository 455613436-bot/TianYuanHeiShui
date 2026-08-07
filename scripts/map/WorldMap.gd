extends Control
## 田原村地图选择界面。
## 热点位置使用相对于原始地图的归一化坐标，因此窗口缩放后仍能对齐。
## M3：地点表改为从 NpcRegistry（data/locations.json）读取，不再硬编码。
## M4：每个热点下方叠加 NPC 徽章（未探索地点显示"？？？"）。

const MAP_PIXEL_SIZE := Vector2(1518.0, 969.0)
const HOTSPOT_SIZE := Vector2(82.0, 82.0)
const DEFAULT_RETURN_SCENE := "res://scenes/main/Main.tscn"

@onready var bottom_panel: Panel = $BottomPanel
@onready var top_shade: ColorRect = $TopShade
@onready var location_label: Label = $BottomPanel/LocationLabel
@onready var hint_label: Label = $BottomPanel/HintLabel

## 当前地点表（运行时从 NpcRegistry 取，按 number 顺序排序）
var _locations: Array = []
## 每个热点按钮下方的 NPC 徽章容器：loc_id -> HBoxContainer
var _badge_containers: Dictionary = {}
var _hotspots: Array[Button] = []


func _ready() -> void:
	add_to_group("world_map")
	GameState.restore_current_scene()
	_load_locations()
	for location in _locations:
		_create_hotspot(location)
	resized.connect(_on_resized)
	call_deferred("_on_resized")
	# M4：NPC 位置变化时刷新徽章
	NpcRegistry.npc_moved.connect(func(_id, _from, _to, _r): call_deferred("_refresh_all_badges"))
	call_deferred("_refresh_all_badges")
	location_label.text = "选择一个地点"
	hint_label.text = "移动鼠标查看地点 · 点击进入"


func _load_locations() -> void:
	_locations = NpcRegistry.all_locations()
	# 按 number 字段排序（数字小的在前）
	_locations.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var na := int(a.get("number", "99"))
		var nb := int(b.get("number", "99"))
		if na != nb:
			return na < nb
		return String(a.get("id", "")) < String(b.get("id", "")))


func _create_hotspot(location: Dictionary) -> void:
	var button := Button.new()
	button.name = "Location%s" % location.get("number", "?")
	button.text = String(location.get("number", "?"))
	button.tooltip_text = "%s\n%s" % [location.get("name", ""), location.get("description", "")]
	button.custom_minimum_size = HOTSPOT_SIZE
	button.size = HOTSPOT_SIZE
	button.pivot_offset = HOTSPOT_SIZE * 0.5
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.z_index = 5
	var pos_arr: Variant = location.get("map_position", [0.5, 0.5])
	var norm_pos := Vector2(0.5, 0.5)
	if pos_arr is Array and (pos_arr as Array).size() >= 2:
		norm_pos = Vector2(float(pos_arr[0]), float(pos_arr[1]))
	button.set_meta("map_position", norm_pos)
	button.set_meta("location_id", String(location.get("id", "")))
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
	# 在按钮下方放一个 NPC 徽章容器（M4）
	var badge_box := HBoxContainer.new()
	badge_box.name = "NpcBadges"
	badge_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_box.add_theme_constant_override("separation", 4)
	add_child(badge_box)
	_badge_containers[String(location.get("id", ""))] = badge_box


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
	# 徽章容器跟随热点下方
	for button in _hotspots:
		var loc_id: String = button.get_meta("location_id")
		var box = _badge_containers.get(loc_id)
		if box is Control:
			(box as Control).position = button.position + Vector2(0, button.size.y + 4)
			(box as Control).size = Vector2(button.size.x * 1.6, 22)


func _on_hotspot_entered(button: Button, location: Dictionary) -> void:
	button.scale = Vector2(1.12, 1.12)
	location_label.text = "%s  ·  %s" % [location.get("number", "?"), location.get("name", "")]
	hint_label.text = String(location.get("description", ""))


func _on_hotspot_exited(button: Button) -> void:
	button.scale = Vector2.ONE
	location_label.text = "选择一个地点"
	hint_label.text = "移动鼠标查看地点 · 点击进入"


# ─── M4：NPC 徽章 ──────────────────────────────────────────────────────────

## 刷新所有地点的徽章；未探索地点显示"？？？"，已探索显示该地点 NPC 名字条
func _refresh_all_badges() -> void:
	for loc_id in _badge_containers:
		_refresh_badge_for(loc_id)


func _refresh_badge_for(loc_id: String) -> void:
	var box = _badge_containers.get(loc_id)
	if not (box is HBoxContainer):
		return
	var container := box as HBoxContainer
	for child in container.get_children():
		child.queue_free()
	# 未探索地点 → 显示"？？？"
	if not GameState.has_visited(loc_id):
		var label := Label.new()
		label.text = "？？？"
		label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.9))
		label.add_theme_font_size_override("font_size", 14)
		container.add_child(label)
		return
	# 已探索 → 显示该地点 NPC 名字条
	var npc_ids := NpcRegistry.get_npcs_at(loc_id)
	if npc_ids.is_empty():
		var empty := Label.new()
		empty.text = "（无人）"
		empty.add_theme_color_override("font_color", Color(0.6, 0.6, 0.55, 0.7))
		empty.add_theme_font_size_override("font_size", 12)
		container.add_child(empty)
		return
	for npc_id in npc_ids:
		var badge := Label.new()
		badge.text = NpcRegistry.get_short_name(npc_id)
		badge.add_theme_color_override("font_color", Color(1.0, 0.92, 0.6, 1.0))
		badge.add_theme_font_size_override("font_size", 13)
		container.add_child(badge)


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
	var scene_path := String(location.get("scene", ""))
	var error := GameState.enter_location(scene_path)
	if error != OK:
		location_label.text = "无法进入 %s" % location.get("name", "")
		hint_label.text = "场景加载失败：%s" % error_string(error)
