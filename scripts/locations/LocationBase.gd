extends Control
## 地图地点的共享占位场景。后续可用真正的探索场景替换各地点文件。

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"

@export var location_number: String = "?"
@export var location_name: String = "未命名地点"
## 该地点在 locations.json 里的 id；留空则由 NpcSpawner 按 scene path 反查
@export var location_id: String = ""
@export_multiline var location_description: String = "该地点仍在建设中。"
@export var background_texture: Texture2D
## 同一地点的第二个视角；设置后会自动生成场景切换按键。
@export var alternate_background_texture: Texture2D
@export var alternate_view_label: String = "切换至后方"
@export var accent_color: Color = Color(0.45, 0.58, 0.36)

var _showing_alternate_view := false
var _view_toggle_button: Button

@onready var content_panel: Panel = $Content
@onready var number_label: Label = $Content/NumberLabel
@onready var title_label: Label = $Content/TitleLabel
@onready var description_label: Label = $Content/DescriptionLabel
@onready var status_label: Label = $Content/StatusLabel if has_node("Content/StatusLabel") else null
@onready var return_button: Button = $ReturnMapButton
@onready var accent: ColorRect = $Accent
@onready var background: TextureRect = $BackgroundTexture
@onready var npc_spawner: Node2D = $NpcSpawner if has_node("NpcSpawner") else null
@onready var presence_bar: CanvasLayer = $NpcPresenceBar if has_node("NpcPresenceBar") else null


func _ready() -> void:
	resized.connect(_apply_responsive_layout)
	GameState.restore_current_scene()
	background.texture = background_texture
	background.visible = background_texture != null
	background.modulate = Color.WHITE
	number_label.text = location_number
	title_label.text = location_name
	description_label.text = location_description
	accent.color = accent_color
	# 有背景图时隐藏占位 Content 面板（场景已接入真背景，不再显示"待开发"）
	content_panel.visible = background_texture == null and alternate_background_texture == null
	if alternate_background_texture != null:
		_create_view_toggle_button()
	return_button.pressed.connect(_open_map)
	return_button.grab_focus()
	# 把 location_id 传给 spawner（若已指定）
	if npc_spawner != null and location_id != "":
		npc_spawner.location_id = location_id
	if presence_bar != null:
		presence_bar.location_id = location_id
		# M4：点击 NPC 头像 → 切换私聊
		if presence_bar.has_signal("npc_selected"):
			presence_bar.npc_selected.connect(_on_presence_npc_selected)
		# M6：召集公聊
		if presence_bar.has_signal("group_chat_requested"):
			presence_bar.group_chat_requested.connect(_on_group_chat_requested)
	call_deferred("_apply_responsive_layout")


## M6：NpcPresenceBar 上的"召集所有人谈话"按钮触发 → 打开 GroupChatUI
func _on_group_chat_requested() -> void:
	var gc_ui := get_node_or_null("GroupChatUI")
	if gc_ui == null:
		return
	var loc_id := location_id
	if loc_id == "":
		var scene := get_tree().current_scene
		loc_id = NpcRegistry.location_id_for_scene(String(scene.scene_file_path)) if scene != null else ""
	if loc_id == "":
		return
	var npc_ids := NpcRegistry.get_npcs_at(loc_id)
	if npc_ids.size() < 2:
		return
	# 获取内嵌的 GroupChatCoordinator 节点
	var coord := gc_ui.get_node_or_null("GroupChatCoordinator")
	if coord == null:
		return
	if not gc_ui.has_method("set_coordinator"):
		return
	gc_ui.set_coordinator(coord)
	gc_ui.open(loc_id, npc_ids)


## NpcPresenceBar 上选中某 NPC → 走 NpcInteractable 路径打开私聊
func _on_presence_npc_selected(npc_id: String) -> void:
	var ui := get_tree().get_first_node_in_group("dialogue_ui")
	if ui == null or (ui.has_method("is_open") and ui.is_open()):
		return
	# 在 spawner 里找到该 NPC 节点
	if npc_spawner == null:
		return
	for child in npc_spawner.get_children():
		if child is Node2D and child.has_method("on_player_interact"):
			if String(child.get("npc_id")) == npc_id:
				child.on_player_interact(self)
				return


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
	if is_instance_valid(_view_toggle_button):
		_view_toggle_button.offset_left = safe_margin
		_view_toggle_button.offset_right = safe_margin + minf(188.0, size.x * 0.36)
		_view_toggle_button.offset_top = safe_margin
		_view_toggle_button.offset_bottom = safe_margin + 52.0


func _create_view_toggle_button() -> void:
	if is_instance_valid(_view_toggle_button):
		return
	_view_toggle_button = Button.new()
	_view_toggle_button.name = "ViewToggleButton"
	_view_toggle_button.text = alternate_view_label
	_view_toggle_button.tooltip_text = "切换同一地点的前后视角"
	_view_toggle_button.add_theme_font_size_override("font_size", 18)
	_view_toggle_button.pressed.connect(_toggle_background_view)
	add_child(_view_toggle_button)


func _toggle_background_view() -> void:
	_showing_alternate_view = not _showing_alternate_view
	background.texture = alternate_background_texture if _showing_alternate_view else background_texture
	if is_instance_valid(_view_toggle_button):
		_view_toggle_button.text = "切换至前方" if _showing_alternate_view else alternate_view_label


func _open_map() -> void:
	InputManager.request_open_map()
