extends Node
## Central keyboard routing. Only the highest-priority open UI handles a key.

const SCENE_ITEM_INTERACTION_SCRIPT := preload("res://scripts/ui/SceneItemInteraction.gd")

signal journal_requested
signal inventory_requested

const UI_PRIORITY_GROUPS := [
	"settings_menu",
	"modal_ui",
	"investigation_ui",
	"dialogue_ui",
	"world_map",
]

const GAMEPLAY_SCENE_PREFIXES := [
	"res://scenes/main/",
	"res://scenes/locations/",
	"res://scenes/map/",
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func request_open_map() -> void:
	_handle_map()


func request_open_inventory() -> void:
	_handle_persistent_page("inventory")


func request_open_journal() -> void:
	_handle_persistent_page("journal")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (not event.pressed or event.echo):
		return
	if event.is_action_pressed("cancel_or_back"):
		# B 是全屏时 Esc 的替代返回键；文本输入期间必须保留给英文/拼音输入。
		if _is_text_entry_focused() and _is_b_key(event):
			return
		_handle_cancel()
		_consume()
		return
	if event.is_action_pressed("open_map"):
		if _is_text_entry_focused():
			return
		_handle_map()
		_consume()
		return
	if event.is_action_pressed("open_journal"):
		if _is_text_entry_focused():
			return
		_handle_persistent_page("journal")
		_consume()
		return
	if event.is_action_pressed("open_inventory"):
		if _is_text_entry_focused():
			return
		_handle_persistent_page("inventory")
		_consume()


func _handle_cancel() -> void:
	var top_ui := _top_open_ui()
	if top_ui != null:
		_close_ui(top_ui)
		return
	_open_settings()


func _handle_map() -> void:
	if not _is_gameplay_scene():
		return
	var top_ui := _top_open_ui()
	if top_ui != null and top_ui.is_in_group("settings_menu"):
		return
	if top_ui != null and top_ui.is_in_group("world_map"):
		_close_ui(top_ui)
		return
	if not GameState.can_open_world_map():
		return
	if GameState.night_rest_required:
		_show_map_blocked_message("今晚的调查已经结束，请留在临时宿舍休息，明早 09:00 再继续。")
		return
	if TimeSystem.is_night_outing_time() and not GameState.has_item("lantern"):
		_show_map_blocked_message("路太黑了，现在还不具备夜间出门的能力。", "夜路太黑")
		return
	if not _close_optional_overlays_for_navigation():
		return
	var dialogue_ui := _dialogue_ui()
	if dialogue_ui != null and _is_ui_open(dialogue_ui):
		if dialogue_ui.has_method("prepare_for_map_navigation"):
			dialogue_ui.prepare_for_map_navigation()
		else:
			_close_ui(dialogue_ui)
	GameState.open_world_map()


func _handle_persistent_page(page: String) -> void:
	if not _is_gameplay_scene():
		return
	var top_ui := _top_open_ui()
	if top_ui != null and top_ui.is_in_group("settings_menu"):
		return
	if top_ui != null and top_ui.is_in_group("modal_ui"):
		return
	if top_ui != null and top_ui.is_in_group("investigation_ui"):
		if _page_matches(top_ui, page):
			_close_ui(top_ui)
		return
	if top_ui != null and top_ui.is_in_group("world_map"):
		return
	var dialogue_ui := _dialogue_ui()
	if dialogue_ui == null:
		if page == "inventory":
			inventory_requested.emit()
		else:
			journal_requested.emit()
		return
	if page == "inventory" and dialogue_ui.has_method("open_inventory_page"):
		dialogue_ui.open_inventory_page()
	elif page == "journal" and dialogue_ui.has_method("open_journal_page"):
		dialogue_ui.open_journal_page()


func _page_matches(node: Node, page: String) -> bool:
	if node.has_method("shortcut_page_id"):
		return String(node.shortcut_page_id()) == page
	return false


func _close_optional_overlays_for_navigation() -> bool:
	for group_name in ["modal_ui", "investigation_ui"]:
		for node in get_tree().get_nodes_in_group(group_name):
			if not _is_ui_open(node):
				continue
			if node.has_method("can_close_for_navigation") and not bool(node.can_close_for_navigation()):
				return false
			_close_ui(node)
	return true


func _show_map_blocked_message(message: String, title: String = "今晚必须休息") -> void:
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("_show_scene_message"):
		scene.call("_show_scene_message", title, message)
		return
	if scene == null:
		return
	var interaction := SCENE_ITEM_INTERACTION_SCRIPT.new()
	interaction.name = "MapBlockedInteraction"
	scene.add_child(interaction)
	var pages: Array[String] = [message]
	interaction.open_paged_text(title, pages)


func _open_settings() -> void:
	for node in get_tree().get_nodes_in_group("settings_menu"):
		if node.has_method("open_ui"):
			node.open_ui()
			return
	push_warning("[InputManager] settings_menu is not available")


func has_blocking_ui() -> bool:
	return _top_open_ui() != null


func _top_open_ui() -> Node:
	for group_name in UI_PRIORITY_GROUPS:
		for node in get_tree().get_nodes_in_group(group_name):
			if _is_ui_open(node):
				return node
	return null


func _is_ui_open(node: Node) -> bool:
	if node.has_method("is_ui_open"):
		return bool(node.is_ui_open())
	if node.has_method("is_open"):
		return bool(node.is_open())
	return node is CanvasItem and node.visible


func _close_ui(node: Node) -> void:
	if node.has_method("close_top_ui"):
		node.close_top_ui()
	elif node.has_method("close_dialogue"):
		node.close_dialogue()
	elif node.has_method("close_ui"):
		node.close_ui()


func _dialogue_ui() -> Node:
	for node in get_tree().get_nodes_in_group("dialogue_ui"):
		return node
	return null


func _is_gameplay_scene() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var scene_path := String(scene.scene_file_path)
	for prefix in GAMEPLAY_SCENE_PREFIXES:
		if scene_path.begins_with(prefix):
			return true
	return false


func _is_text_entry_focused() -> bool:
	var viewport := get_viewport()
	if viewport == null:
		return false
	var focus_owner := viewport.gui_get_focus_owner()
	return focus_owner is LineEdit or focus_owner is TextEdit


func _is_b_key(event: InputEvent) -> bool:
	return event is InputEventKey and ((event as InputEventKey).keycode == KEY_B or (event as InputEventKey).physical_keycode == KEY_B)


func _consume() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()
