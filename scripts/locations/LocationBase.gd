extends Control
## 地图地点的共享占位场景。后续可用真正的探索场景替换各地点文件。

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"

@export var location_number: String = "?"
@export var location_name: String = "未命名地点"
@export_multiline var location_description: String = "该地点仍在建设中。"
@export var background_texture: Texture2D
@export var accent_color: Color = Color(0.45, 0.58, 0.36)

@onready var number_label: Label = $Content/NumberLabel
@onready var title_label: Label = $Content/TitleLabel
@onready var description_label: Label = $Content/DescriptionLabel
@onready var return_button: Button = $ReturnMapButton
@onready var accent: ColorRect = $Accent
@onready var background: TextureRect = $BackgroundTexture


func _ready() -> void:
	background.texture = background_texture
	background.visible = background_texture != null
	number_label.text = location_number
	title_label.text = location_name
	description_label.text = location_description
	accent.color = accent_color
	return_button.pressed.connect(_open_map)
	return_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") or _is_map_shortcut(event):
		get_viewport().set_input_as_handled()
		_open_map()


func _is_map_shortcut(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
		and (event.keycode == KEY_M or event.physical_keycode == KEY_M)


func _open_map() -> void:
	var current_scene := get_tree().current_scene
	if current_scene != null:
		GameState.remember_map_return_scene(current_scene.scene_file_path)
	get_tree().change_scene_to_file(MAP_SCENE)
