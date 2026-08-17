extends Node
## Headless regression smoke test for the field-path hermit schedule.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()
	# Day 2 at 16:50: the schedule must not have started yet.
	TimeSystem.advance_minutes(TimeSystem.MINUTES_PER_DAY + (16 * 60 + 50 - 9 * 60))
	if NpcRegistry.is_mysterious_hermit_road_time():
		_fail("Hermit appeared before day 3")
		return
	# Day 3 at 16:49.
	TimeSystem.advance_minutes(TimeSystem.MINUTES_PER_DAY - 1)
	var field_scene := load("res://scenes/locations/FieldPath.tscn") as PackedScene
	if field_scene == null:
		_fail("Field path scene could not be loaded")
		return
	var field := field_scene.instantiate()
	get_tree().root.add_child(field)
	await get_tree().process_frame
	var man_button: Button = field.get_node("RoadMysteriousHermitHotspot") as Button
	if man_button.visible:
		_fail("Hermit was visible before 16:50")
		return

	TimeSystem.advance_minutes(1)
	if not man_button.visible or not NpcRegistry.is_mysterious_hermit_road_time():
		_fail("Hermit did not appear on day 3 at 16:50")
		return
	var background: TextureRect = field.get_node("BackgroundTexture") as TextureRect
	if background.texture == null or String(background.texture.resource_path) != "res://assets/scenes/field_path_with_man.png":
		_fail("Field path did not switch to the occupied background")
		return

	# Entering the scene while the schedule is already active must also keep the
	# occupied background; this catches generic presence refresh overwrites.
	field.queue_free()
	await get_tree().process_frame
	field = field_scene.instantiate()
	get_tree().root.add_child(field)
	await get_tree().process_frame
	man_button = field.get_node("RoadMysteriousHermitHotspot") as Button
	background = field.get_node("BackgroundTexture") as TextureRect
	if not man_button.visible or String(background.texture.resource_path) != "res://assets/scenes/field_path_with_man.png":
		_fail("Entering during the active window desynchronized the mask and background")
		return

	man_button.pressed.emit()
	await get_tree().process_frame
	var dialogue_ui: Node = field.get_node("DialogueUI")
	if not dialogue_ui.is_open() or String((dialogue_ui.get("current_npc") as Dictionary).get("id", "")) != "mysterious_hermit":
		_fail("Road mask did not open the mysterious hermit dialogue")
		return
	var fixed_pages: Array[String] = dialogue_ui.get("_fixed_event_pages") as Array[String]
	var dialogue_history: Array = dialogue_ui.get("history") as Array
	if fixed_pages.is_empty() or dialogue_history.is_empty() or not bool(dialogue_ui.get("_fixed_typewriter_running")):
		_fail("Authored story text did not enter the typewriter flow")
		return
	var partial_text := String((dialogue_history[-1] as Dictionary).get("text", ""))
	if partial_text.length() >= fixed_pages[0].length():
		_fail("Authored story page appeared all at once instead of typing")
		return

	# Reaching 18:00 during the dialogue latches the occupied scene until exit.
	TimeSystem.advance_minutes(70)
	if NpcRegistry.is_mysterious_hermit_road_time():
		_fail("Base schedule still considered 18:00 inside the window")
		return
	if not man_button.visible or not bool(field.get("_road_hermit_departure_deferred")):
		_fail("Active dialogue did not defer the hermit's departure")
		return
	dialogue_ui.close_dialogue()
	TimeSystem.advance_minutes(10)
	if not man_button.visible:
		_fail("Hermit disappeared before the player left the scene")
		return

	field.queue_free()
	await get_tree().process_frame
	var reentered_field := field_scene.instantiate()
	get_tree().root.add_child(reentered_field)
	await get_tree().process_frame
	var reentered_button: Button = reentered_field.get_node("RoadMysteriousHermitHotspot") as Button
	if reentered_button.visible:
		_fail("Hermit remained after leaving and re-entering past 18:00")
		return

	print("ROAD_HERMIT_SCHEDULE_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("ROAD_HERMIT_SCHEDULE_SMOKE_FAILED: " + message)
	get_tree().quit(1)
