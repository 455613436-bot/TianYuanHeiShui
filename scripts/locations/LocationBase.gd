extends Control
## 地图地点的共享占位场景。后续可用真正的探索场景替换各地点文件。

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"

@export var location_number: String = "?"
@export var location_name: String = "未命名地点"
@export_multiline var location_description: String = "该地点仍在建设中。"
@export var background_texture: Texture2D
@export var accent_color: Color = Color(0.45, 0.58, 0.36)

@onready var content_panel: Panel = $Content
@onready var number_label: Label = $Content/NumberLabel
@onready var title_label: Label = $Content/TitleLabel
@onready var description_label: Label = $Content/DescriptionLabel
@onready var return_button: Button = $ReturnMapButton
@onready var accent: ColorRect = $Accent
@onready var background: TextureRect = $BackgroundTexture


func _ready() -> void:
	resized.connect(_apply_responsive_layout)
	GameState.restore_current_scene()
	background.texture = background_texture
	background.visible = background_texture != null
	number_label.text = location_number
	title_label.text = location_name
	description_label.text = location_description
	accent.color = accent_color
	return_button.pressed.connect(_open_map)
	return_button.grab_focus()
	call_deferred("_apply_responsive_layout")


func _apply_responsive_layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var safe_margin := clampf(size.x * 0.06, 16.0, 64.0)
	var panel_width := minf(780.0, size.x - safe_margin * 2.0)
	var panel_height := minf(440.0, size.y - 120.0)
	content_panel.offset_left = -panel_width * 0.5
	content_panel.offset_right = panel_width * 0.5
	content_panel.offset_top = -panel_height * 0.5
	content_panel.offset_bottom = panel_height * 0.5
	return_button.offset_left = -minf(214.0, size.x * 0.42)
	return_button.offset_right = -safe_margin
	return_button.offset_top = safe_margin
	return_button.offset_bottom = safe_margin + 52.0

func _open_map() -> void:
	InputManager.request_open_map()
