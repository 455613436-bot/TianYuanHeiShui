extends CanvasLayer
## NpcPresenceBar
## 场景 HUD 顶部横条：显示"这里还有谁"。
## - 点击某个 NPC 头像 = 切换私聊对象（关闭当前对话、开新对象的私聊）
## - 当当前地点 NPC >= 2 时，右侧亮起"召集所有人谈话"按钮 → 进入公聊模式（M6）
##
## 挂载：作为 Main.tscn / LocationBase.tscn 的子节点（CanvasLayer, layer=8）

signal npc_selected(npc_id: String)
signal group_chat_requested()

const NPC_SCRIPT := preload("res://scripts/entities/NpcInteractable.gd")

@onready var bar_panel: Panel = $BarPanel
@onready var presence_container: HBoxContainer = $BarPanel/Scroll/PresenceRow
@onready var group_chat_btn: Button = $BarPanel/GroupChatBtn
@onready var clock_label: Label = $ClockLabel

## 当前地点 id；留空则按 scene path 反查
var location_id: String = ""
var _current_npc_buttons: Dictionary = {} # npc_id -> Button


func _ready() -> void:
	layer = 8
	group_chat_btn.visible = false
	group_chat_btn.disabled = true
	group_chat_btn.pressed.connect(func(): group_chat_requested.emit())
	# 时钟刷新
	TimeSystem.minute_changed.connect(func(_d, _m): _update_clock())
	_update_clock()
	call_deferred("_refresh")


func get_location_id() -> String:
	if location_id != "":
		return location_id
	var scene := get_tree().current_scene
	if scene == null:
		return ""
	return NpcRegistry.location_id_for_scene(String(scene.scene_file_path))


func _process(_delta: float) -> void:
	# 每帧检查是否需要刷新（NPC 可能因 schedule 变动）
	# 用一个简单的脏标记：若 presence_container 子节点数与实际不符就刷新
	var loc_id := get_location_id()
	if loc_id == "":
		return
	var actual := NpcRegistry.get_npcs_at(loc_id).size()
	if actual != _current_npc_buttons.size():
		call_deferred("_refresh")


func _update_clock() -> void:
	if clock_label != null:
		clock_label.text = TimeSystem.format_clock()


## 外部可主动调（场景 _ready 后、对话关闭后）
func _refresh() -> void:
	for child in presence_container.get_children():
		child.queue_free()
	_current_npc_buttons.clear()
	var loc_id := get_location_id()
	if loc_id == "":
		bar_panel.visible = false
		return
	bar_panel.visible = true
	var npc_ids := NpcRegistry.get_npcs_at(loc_id)
	for npc_id in npc_ids:
		var btn := Button.new()
		btn.text = NpcRegistry.get_short_name(npc_id)
		btn.tooltip_text = "与 %s 私聊" % NpcRegistry.get_display_name(npc_id)
		btn.custom_minimum_size = Vector2(96, 36)
		btn.add_theme_font_size_override("font_size", 16)
		btn.pressed.connect(func(): npc_selected.emit(npc_id))
		presence_container.add_child(btn)
		_current_npc_buttons[npc_id] = btn
	# 公聊按钮：>= 2 个 NPC 才亮起
	group_chat_btn.visible = npc_ids.size() >= 2
	group_chat_btn.disabled = npc_ids.size() < 2


## 当前地点 NPC 数量
func npc_count() -> int:
	var loc_id := get_location_id()
	if loc_id == "":
		return 0
	return NpcRegistry.get_npcs_at(loc_id).size()
