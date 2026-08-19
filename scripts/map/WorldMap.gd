extends Control
## 田园村地图选择界面。
## 地图上的交互区由与底图等尺寸的透明 mask 提供，缩放后仍能逐像素对齐。

const MAP_PIXEL_SIZE := Vector2(1672.0, 941.0)
const MASK_HIGHLIGHT_SCRIPT := preload("res://scripts/ui/MaskInteractionHighlight.gd")

const LOCATION_MASKS: Dictionary = {
	"abandoned_clinic": "res://assets/maps/masks/map_hospital_mask.png",
	"lakeside_pavilion": "res://assets/maps/masks/map_pavillion_mask.png",
	"lakeside_dock": "res://assets/maps/masks/map_dock_mask.png",
	"carpenter_workshop": "res://assets/maps/masks/map_studio_mask.png",
	"construction_site": "res://assets/maps/masks/map_workingsite_mask.png",
	"taoist_temple": "res://assets/maps/masks/map_temple_mask.png",
	"back_mountain": "res://assets/maps/masks/map_cave_mask.png",
	"village_chief_house": "res://assets/maps/masks/map_chiefhouse_mask.png",
	"village_committee": "res://assets/maps/masks/map_committee_mask.png",
	"temporary_dorm": "res://assets/maps/masks/map_dorm_mask.png",
	"farmland": "res://assets/maps/masks/map_farm_mask.png",
	"field_path": "res://assets/maps/masks/map_road_mask.png",
}

@onready var bottom_panel: Panel = $BottomPanel
@onready var top_shade: ColorRect = $TopShade
@onready var subtitle_label: Label = $TopShade/Subtitle
@onready var location_label: Label = $BottomPanel/LocationLabel
@onready var hint_label: Label = $BottomPanel/HintLabel

var _locations: Array = []
var _mask_hotspots: Array[Dictionary] = []


func _ready() -> void:
	add_to_group("world_map")
	GameState.restore_current_scene()
	AudioManager.play_map_bgm()
	_load_locations()
	for raw_location: Variant in _locations:
		var location: Dictionary = raw_location as Dictionary
		_create_mask_hotspot(location)
	resized.connect(_on_resized)
	call_deferred("_on_resized")
	if GameState.night_rest_required:
		subtitle_label.text = "夜深了，只能回临时宿舍休息"
		location_label.text = "请前往临时宿舍"
		hint_label.text = "完成休息后，明天才能继续调查。"
	else:
		_reset_location_hint()


func _load_locations() -> void:
	_locations = NpcRegistry.all_locations()
	_locations.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var number_a: int = int(a.get("number", "99"))
		var number_b: int = int(b.get("number", "99"))
		if number_a != number_b:
			return number_a < number_b
		return String(a.get("id", "")) < String(b.get("id", "")))


func _create_mask_hotspot(location: Dictionary) -> void:
	var location_id: String = String(location.get("id", ""))
	var mask_path: String = String(LOCATION_MASKS.get(location_id, ""))
	if mask_path.is_empty():
		push_warning("地图地点缺少 mask：%s" % location_id)
		return

	var mask_resource: Resource = load(mask_path)
	var mask_texture: Texture2D = mask_resource as Texture2D
	if mask_texture == null:
		push_error("无法加载地图 mask：%s" % mask_path)
		return

	var highlight: MaskInteractionHighlight = MASK_HIGHLIGHT_SCRIPT.new()
	highlight.name = "%sHighlight" % location_id.to_pascal_case()
	highlight.z_index = 4
	highlight.configure(mask_texture, Color(0.28, 0.86, 1.0, 1.0), 0.32, 3.0)
	add_child(highlight)

	var button: TextureButton = TextureButton.new()
	button.name = "%sMaskButton" % location_id.to_pascal_case()
	button.texture_normal = mask_texture
	button.ignore_texture_size = true
	button.stretch_mode = TextureButton.STRETCH_SCALE
	button.self_modulate = Color(1.0, 1.0, 1.0, 0.0)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.z_index = 5
	button.tooltip_text = "%s\n%s" % [location.get("name", ""), location.get("description", "")]

	var mask_image: Image = mask_texture.get_image()
	if mask_image != null and not mask_image.is_empty():
		var click_mask: BitMap = BitMap.new()
		click_mask.create_from_image_alpha(mask_image, 0.1)
		button.texture_click_mask = click_mask
	else:
		push_error("地图 mask 没有可用图像数据：%s" % mask_path)
		highlight.queue_free()
		button.queue_free()
		return

	if not GameState.can_enter_location(location_id):
		button.mouse_default_cursor_shape = Control.CURSOR_ARROW
		button.tooltip_text = "%s\n天色已晚，请先回临时宿舍休息。" % location.get("name", "")

	button.pressed.connect(_enter_location.bind(location))
	button.mouse_entered.connect(_on_mask_entered.bind(highlight, location))
	button.mouse_exited.connect(_on_mask_exited.bind(highlight))
	add_child(button)
	_mask_hotspots.append({
		"button": button,
		"highlight": highlight,
	})


func _on_resized() -> void:
	_apply_responsive_layout()
	_layout_mask_hotspots()


func _apply_responsive_layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var safe_margin: float = clampf(size.x * 0.08, 16.0, 180.0)
	bottom_panel.offset_left = safe_margin
	bottom_panel.offset_right = -safe_margin
	bottom_panel.offset_bottom = -clampf(size.y * 0.025, 12.0, 24.0)
	bottom_panel.offset_top = bottom_panel.offset_bottom - clampf(size.y * 0.15, 96.0, 126.0)
	var top_half_width: float = minf(220.0, size.x * 0.45)
	top_shade.offset_left = -top_half_width
	top_shade.offset_right = top_half_width


func _layout_mask_hotspots() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var fit_scale: float = minf(size.x / MAP_PIXEL_SIZE.x, size.y / MAP_PIXEL_SIZE.y)
	var displayed_size: Vector2 = MAP_PIXEL_SIZE * fit_scale
	var map_origin: Vector2 = (size - displayed_size) * 0.5
	for entry: Dictionary in _mask_hotspots:
		var button: TextureButton = entry.get("button") as TextureButton
		var highlight: MaskInteractionHighlight = entry.get("highlight") as MaskInteractionHighlight
		if button != null:
			button.position = map_origin
			button.size = displayed_size
		if highlight != null:
			highlight.position = map_origin
			highlight.size = displayed_size


func _on_mask_entered(highlight: MaskInteractionHighlight, location: Dictionary) -> void:
	highlight.show_highlight()
	location_label.text = String(location.get("name", ""))
	if not GameState.can_enter_location(String(location.get("id", ""))):
		hint_label.text = "天色已晚，请先回临时宿舍休息。"
		return
	hint_label.text = String(location.get("description", ""))


func _on_mask_exited(highlight: MaskInteractionHighlight) -> void:
	highlight.hide_highlight()
	if GameState.night_rest_required:
		location_label.text = "请前往临时宿舍"
		hint_label.text = "完成休息后，明天才能继续调查。"
	else:
		_reset_location_hint()


func _reset_location_hint() -> void:
	location_label.text = "选择一个地点"
	hint_label.text = "移动鼠标查看地点 · 前往其他地点耗时 10 分钟"


func is_ui_open() -> bool:
	return true


func close_top_ui() -> void:
	_close_map()


func _close_map() -> void:
	var error: Error = GameState.close_world_map()
	if error != OK:
		location_label.text = "无法关闭地图"
		hint_label.text = "返回场景加载失败：%s" % error_string(error)


func _enter_location(location: Dictionary) -> void:
	var location_id: String = String(location.get("id", ""))
	if not GameState.can_enter_location(location_id):
		location_label.text = "今晚不能前往这里"
		hint_label.text = "请先回临时宿舍休息。"
		return
	var scene_path: String = String(location.get("scene", ""))
	var error: Error = GameState.enter_location(scene_path)
	if error != OK:
		location_label.text = "无法进入 %s" % location.get("name", "")
		hint_label.text = "场景加载失败：%s" % error_string(error)
