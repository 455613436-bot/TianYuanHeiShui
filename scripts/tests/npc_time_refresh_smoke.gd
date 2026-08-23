extends Node
## Headless regression smoke test for the Taoist temple's day/night mask refresh.


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

	var front_nodes: Array = temple.get("_taoist_front_nodes")
	var rear_nodes: Array = temple.get("_taoist_rear_nodes")
	if front_nodes.size() < 2 or rear_nodes.size() < 2:
		_fail("Taoist temple day/night mask nodes were not initialized")
		return
	var day_button := front_nodes[0] as Button
	var night_button := rear_nodes[0] as Button
	if day_button == null or night_button == null or not day_button.visible or night_button.visible:
		_fail("Daytime Li Leshui presence was not initialized correctly")
		return

	TimeSystem.advance_minutes(10)
	await _wait_for_refresh()
	if day_button.visible:
		_fail("Daytime Taoist mask remained visible after 19:00")
		return
	temple.set("_taoist_in_rear_room", true)
	temple.call("_refresh_taoist_temple_state")
	if not night_button.visible:
		_fail("Nighttime Taoist mask was not visible in the unlocked rear room")
		return

	# 19:00 on day 1 -> 09:00 on day 2, when the daytime temple state resumes.
	TimeSystem.advance_minutes(14 * 60)
	await _wait_for_refresh()
	if not day_button.visible or night_button.visible:
		_fail("Taoist masks did not switch back to daytime presence at 09:00")
		return

	temple.queue_free()
	print("NPC_TIME_REFRESH_SMOKE_OK")
	get_tree().quit(0)


func _wait_for_refresh() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _fail(message: String) -> void:
	push_error("NPC_TIME_REFRESH_SMOKE_FAILED: " + message)
	get_tree().quit(1)
