extends Node2D
## NpcSpawner
## 数据驱动的 NPC 生成器。挂在场景根节点下，根据当前地点 id
## 从 NpcRegistry 动态实例化 `NpcInteractable` 节点。
##
## 用法：
##   在 Main.tscn / LocationBase.tscn 根下添加一个 NpcSpawner 节点，
##   通过 @export location_id 或场景元数据指定地点 id。
##   若不指定，spawner 会按 current_scene_path 反查 locations.json。

const NPC_INTERACTABLE_SCENE := "res://scenes/entities/NpcInteractable.tscn"
const NPC_SCRIPT := preload("res://scripts/entities/NpcInteractable.gd")
const MoodPortraitUtil := preload("res://scripts/ui/MoodPortrait.gd")

## 当前地点 id；留空则按 scene path 反查
@export var location_id: String = ""
## NPC 立绘图层的水平起点与间距（用于多 NPC 水平排列）
@export var portrait_start_x: float = 0.0
@export var portrait_spacing: float = 360.0
@export var portrait_y: float = 0.0

## 已经生成的 NPC 节点：npc_id -> NpcInteractable
var _spawned: Dictionary = {}


func _ready() -> void:
	# 场景切换后 registry 可能还没就绪（autoload 顺序），用 call_deferred 等一帧
	call_deferred("_spawn_npcs")
	# 监听位置变化，动态更新（NPC 走了就隐藏节点，新来的就生成）
	NpcRegistry.npc_moved.connect(_on_npc_moved)


func get_location_id() -> String:
	if location_id != "":
		return location_id
	# 用当前场景路径反查
	var scene := get_tree().current_scene
	if scene == null:
		return ""
	var path := String(scene.scene_file_path)
	return NpcRegistry.location_id_for_scene(path)


func _spawn_npcs() -> void:
	# 清掉旧的
	for node in _spawned.values():
		if is_instance_valid(node):
			(node as Node).queue_free()
	_spawned.clear()
	var loc_id := get_location_id()
	if loc_id == "":
		return
	GameState.mark_visited(loc_id)
	var npc_ids := NpcRegistry.get_npcs_at(loc_id)
	var index := 0
	for npc_id in npc_ids:
		var node := _instantiate_npc(npc_id, index)
		if node != null:
			_spawned[npc_id] = node
		index += 1


func _instantiate_npc(npc_id: String, layout_index: int) -> Node2D:
	var node: Node2D = null
	var scene_res: Resource = load(NPC_INTERACTABLE_SCENE) if ResourceLoader.exists(NPC_INTERACTABLE_SCENE) else null
	if scene_res is PackedScene:
		node = (scene_res as PackedScene).instantiate() as Node2D
	else:
		# 兜底：纯代码创建
		node = Node2D.new()
		node.set_script(NPC_SCRIPT)
	node.npc_id = npc_id
	# 让 NpcInteractable 自动从 NpcRegistry 取人设（而非固定路径）
	node.npc_md_path = "res://data/npcs/%s.md" % npc_id
	node.npc_json_path = "res://data/npcs/%s.json" % npc_id
	# 水平排列
	var x := portrait_start_x + portrait_spacing * float(layout_index)
	node.position = Vector2(x, portrait_y)
	add_child(node)
	# 给 NPC 创建可见的立绘按钮（让玩家能点击交互）
	_attach_portrait_button(node, npc_id, layout_index)
	return node


## 全身立绘相对视口高度的占比；默认 1280×720 下为 576px。
const PORTRAIT_VIEWPORT_HEIGHT_RATIO := 0.80
## 原始全身立绘为 768×1024，保持 3:4 宽高比例。
const PORTRAIT_ASPECT_RATIO := 0.75
## 立绘间距
const PORTRAIT_GAP := 40.0
## 单个 NPC 相对屏幕中心向右偏移的比例，0.25 即位于画面右侧四分之一位置。
const SINGLE_PORTRAIT_CENTER_OFFSET_RATIO := 0.25
## 立绘底部距屏幕底部的边距；调小会让角色略微下移。
const PORTRAIT_BOTTOM_MARGIN := 48.0


## 给 NpcInteractable 节点附加一个可见的 TextureButton 作为立绘。
## 优先用 NPC 的立绘 PNG，找不到用占位色块。
## 多人时按当前 NPC 总数居中排列。
func _attach_portrait_button(npc_node: Node2D, npc_id: String, layout_index: int) -> void:
	# 创建一个 CanvasLayer 容器放立绘按钮，避免被场景坐标影响
	var layer := CanvasLayer.new()
	layer.name = "PortraitLayer_%s" % npc_id
	layer.layer = 0
	npc_node.add_child(layer)

	# 计算当前地点 NPC 总数，用于居中排列
	var loc_id := get_location_id()
	var total_npcs := 1
	if loc_id != "":
		total_npcs = maxi(1, NpcRegistry.get_npcs_at(loc_id).size())

	var viewport_size := get_viewport_rect().size
	var portrait_height := maxf(1.0, viewport_size.y * PORTRAIT_VIEWPORT_HEIGHT_RATIO)
	var portrait_width := portrait_height * PORTRAIT_ASPECT_RATIO

	var btn := TextureButton.new()
	btn.name = "PortraitButton"
	# 场景中固定展示 NPC 的全身基础立绘；表情差分仅在对话框中切换。
	var portrait: Texture2D = null
	var base_portrait_path := "res://assets/portraits/%s.png" % npc_id
	if ResourceLoader.exists(base_portrait_path):
		var base_resource: Resource = load(base_portrait_path)
		if base_resource is Texture2D:
			portrait = base_resource
	if portrait == null:
		portrait = MoodPortraitUtil.load_or_generate(
			npc_id,
			MoodPortraitUtil.DEFAULT_MOOD,
			Vector2i(int(portrait_width), int(portrait_height))
		)
	btn.texture_normal = portrait
	btn.texture_hover = portrait
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT

	# 单人落在画面横向 3/4 处；多人维持居中排列。
	var center_x := 0.0
	if total_npcs == 1:
		center_x = viewport_size.x * SINGLE_PORTRAIT_CENTER_OFFSET_RATIO
	else:
		var total_width := float(total_npcs) * portrait_width + float(total_npcs - 1) * PORTRAIT_GAP
		center_x = -total_width * 0.5 + float(layout_index) * (portrait_width + PORTRAIT_GAP) + portrait_width * 0.5

	btn.anchor_left = 0.5
	btn.anchor_top = 1.0
	btn.anchor_right = 0.5
	btn.anchor_bottom = 1.0
	btn.offset_left = center_x - portrait_width * 0.5
	btn.offset_top = -portrait_height - PORTRAIT_BOTTOM_MARGIN
	btn.offset_right = center_x + portrait_width * 0.5
	btn.offset_bottom = -PORTRAIT_BOTTOM_MARGIN
	btn.tooltip_text = "与 %s 交谈" % NpcRegistry.get_display_name(npc_id)
	btn.modulate = Color(0.85, 0.85, 0.85, 1)
	# 点击 → 触发该 NPC 的 on_player_interact
	btn.pressed.connect(func():
		var ui := get_tree().get_first_node_in_group("dialogue_ui")
		if ui != null and ui.has_method("is_open") and ui.is_open():
			return
		if npc_node.has_method("on_player_interact"):
			npc_node.on_player_interact(get_tree().current_scene))
	# hover 高亮
	btn.mouse_entered.connect(func(): btn.modulate = Color(1, 1, 1, 1))
	btn.mouse_exited.connect(func(): btn.modulate = Color(0.85, 0.85, 0.85, 1))
	layer.add_child(btn)

	# 名字标签（立绘下方）
	var name_label := Label.new()
	name_label.text = NpcRegistry.get_short_name(npc_id)
	name_label.anchor_left = 0.5
	name_label.anchor_top = 1.0
	name_label.anchor_right = 0.5
	name_label.anchor_bottom = 1.0
	name_label.offset_left = center_x - portrait_width * 0.5
	name_label.offset_top = -PORTRAIT_BOTTOM_MARGIN + 5.0
	name_label.offset_right = center_x + portrait_width * 0.5
	name_label.offset_bottom = -PORTRAIT_BOTTOM_MARGIN + 35.0
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_color_override("font_color", Color(1, 0.92, 0.6, 1))
	name_label.add_theme_font_size_override("font_size", 22)
	layer.add_child(name_label)


func _on_npc_moved(npc_id: String, _from: String, to_loc: String, _reason: String) -> void:
	var loc_id := get_location_id()
	if loc_id == "":
		return
	# NPC 位置变化后，重新生成全部立绘（保证多人居中排列正确）
	# 用 call_deferred 避免 queue_free 和 signal 时序冲突
	call_deferred("_spawn_npcs")
