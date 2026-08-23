extends Node2D
## Main
## 村口广场场景（第 0 号地点）。
##
## M2 后 NPC 由 NpcSpawner 数据驱动生成，立绘也由 spawner 统一管理。
## 场景只负责：背景 + 返回地图按钮 + DialogueUI + PresenceBar + GroupChatUI。

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"
const ITEM_BAG_POPUP_SCENE := preload("res://scenes/ui/ItemBagPopup.tscn")

## 村长 NPC 的 profile 路径（兜底用，spawner 未就绪时）
const NPC_ID := "wu_zhiyuan"
const NPC_MD_PATH := "res://data/npcs/wu_zhiyuan.md"
const NPC_JSON_PATH := "res://data/npcs/wu_zhiyuan.json"

@onready var npc_spawner: Node = $NpcSpawner
@onready var presence_bar: CanvasLayer = $NpcPresenceBar if has_node("NpcPresenceBar") else null
@onready var return_map_button: BaseButton = $HUD/ReturnMapButton


func _ready() -> void:
	GameState.restore_current_scene()
	return_map_button.pressed.connect(_open_map)
	if not InputManager.inventory_requested.is_connected(_on_inventory_requested):
		InputManager.inventory_requested.connect(_on_inventory_requested)
	if presence_bar != null and presence_bar.has_signal("npc_selected"):
		presence_bar.npc_selected.connect(_on_presence_npc_selected)
	if presence_bar != null and presence_bar.has_signal("group_chat_requested"):
		presence_bar.group_chat_requested.connect(_on_group_chat_requested)
	print("[Main] 村口广场场景就绪。")


## M6：NpcPresenceBar 上的"召集所有人谈话"按钮触发 → 打开 GroupChatUI
func _on_group_chat_requested() -> void:
	var gc_ui := get_node_or_null("GroupChatUI")
	if gc_ui == null:
		return
	var loc_id := "village_square"
	var npc_ids := NpcRegistry.get_npcs_at(loc_id)
	if npc_ids.size() < 2:
		return
	var coord := gc_ui.get_node_or_null("GroupChatCoordinator")
	if coord == null or not gc_ui.has_method("set_coordinator"):
		return
	gc_ui.set_coordinator(coord)
	gc_ui.open(loc_id, npc_ids)


## NpcPresenceBar 上选中某 NPC → 走 NpcInteractable 路径打开私聊
func _on_presence_npc_selected(npc_id: String) -> void:
	if _is_dialogue_open():
		return
	for child in npc_spawner.get_children():
		if child is Node2D and child.has_method("on_player_interact"):
			if String(child.get("npc_id")) == npc_id:
				child.on_player_interact(self)
				return


func _is_dialogue_open() -> bool:
	var ui := get_tree().get_first_node_in_group("dialogue_ui")
	if ui == null:
		return false
	if ui.has_method("is_open"):
		return ui.is_open()
	return false


func _on_inventory_requested() -> void:
	var popup := ITEM_BAG_POPUP_SCENE.instantiate()
	add_child(popup)
	popup.open_ui(GameState.inventory, [], false)


func _open_map() -> void:
	InputManager.request_open_map()
