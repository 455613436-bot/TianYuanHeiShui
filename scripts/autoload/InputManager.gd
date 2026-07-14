extends Node
## Central keyboard routing. Only the highest-priority open UI handles a key.

signal journal_requested
signal inventory_requested

const UI_PRIORITY_GROUPS := [
	"settings_menu",
	"dialogue_ui",
	"investigation_ui",
	"world_map",
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func request_open_map() -> void:
	_handle_map()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (not event.pressed or event.echo):
		return
	if event.is_action_pressed("cancel_or_back"):
		_handle_cancel()
		_consume()
		return
	if event.is_action_pressed("open_map"):
		_handle_map()
		_consume()
		return
	if event.is_action_pressed("open_journal"):
		if _top_open_ui() == null:
			journal_requested.emit()
		_consume()
		return
	if event.is_action_pressed("open_inventory"):
		if _top_open_ui() == null:
			inventory_requested.emit()
		_consume()

func _handle_cancel() -> void:
	var top_ui := _top_open_ui()
	if top_ui != null:
		_close_ui(top_ui)
		return
	_open_settings()


func _handle_map() -> void:
	var top_ui := _top_open_ui()
	if top_ui != null:
		if top_ui.is_in_group("world_map"):
			_close_ui(top_ui)
		# Other overlays own the keyboard while open; M is consumed without opening a map.
		return
	GameState.open_world_map()


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


func _consume() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()
