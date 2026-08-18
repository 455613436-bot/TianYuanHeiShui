extends Node
## Headless regression smoke test for day/night NPC refresh and stale-node guards.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()
	# Start at day 1, 18:50 so the first ten-minute tick crosses the day/night boundary.
	TimeSystem.advance_minutes((18 * 60 + 50) - 9 * 60)

	var temple_scene := load("res://scenes/locations/TaoistTemple.tscn") as PackedScene
	if temple_scene == null:
		_fail("Taoist temple scene could not be loaded")
		return
	var temple := temple_scene.instantiate()
	get_tree().root.add_child(temple)
	await _wait_for_refresh()

	var spawner := temple.get_node_or_null("NpcSpawner")
	if spawner == null:
		_fail("Taoist temple has no NpcSpawner")
		return
	if not _has_npc(spawner, "li_leshui_day") or _has_npc(spawner, "li_leshui_night"):
		_fail("Daytime Li Leshui presence was not initialized correctly")
		return

	var stale_day_node: Node = _find_npc(spawner, "li_leshui_day")
	TimeSystem.advance_minutes(10)
	if stale_day_node != null and temple.has_node("DialogueUI"):
		stale_day_node.call("on_player_interact", temple)
		var dialogue_ui := temple.get_node("DialogueUI")
		if dialogue_ui.has_method("is_open") and dialogue_ui.is_open():
			_fail("Stale daytime NPC opened a dialogue after 19:00")
			return
	await _wait_for_refresh()

	if _has_npc(spawner, "li_leshui_day") or not _has_npc(spawner, "li_leshui_night"):
		_fail("NPC nodes did not switch to the nighttime presence at 19:00")
		return

	# 19:00 on day 1 -> 06:00 on day 2.
	TimeSystem.advance_minutes(11 * 60)
	await _wait_for_refresh()
	if not _has_npc(spawner, "li_leshui_day") or _has_npc(spawner, "li_leshui_night"):
		_fail("NPC nodes did not switch back to daytime presence at 06:00")
		return

	temple.queue_free()
	print("NPC_TIME_REFRESH_SMOKE_OK")
	get_tree().quit(0)


func _wait_for_refresh() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _find_npc(spawner: Node, npc_id: String) -> Node:
	for child in spawner.get_children():
		if String(child.get("npc_id")) == npc_id:
			return child
	return null


func _has_npc(spawner: Node, npc_id: String) -> bool:
	return _find_npc(spawner, npc_id) != null


func _fail(message: String) -> void:
	push_error("NPC_TIME_REFRESH_SMOKE_FAILED: " + message)
	get_tree().quit(1)
