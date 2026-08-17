extends Node
## Headless regression smoke test for authored dialogue typewriter pages.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()
	var dialogue_scene := load("res://scenes/ui/DialogueUI.tscn") as PackedScene
	var dialogue := dialogue_scene.instantiate()
	get_tree().root.add_child(dialogue)
	await get_tree().process_frame
	dialogue.set("current_npc", NpcRegistry.get_dialogue_profile("mysterious_hermit"))
	dialogue.call("_play_fixed_story_event", {
		"id": "fixed_story_typewriter_test",
		"once": false,
		"pages": ["甲乙", "丙丁"],
		"choices": ["继续交谈"],
		"effects": {},
	}, "mysterious_hermit")
	if not bool(dialogue.get("_fixed_typewriter_running")):
		_fail("First authored page did not start typing")
		return
	await get_tree().create_timer(0.30).timeout
	var history: Array = dialogue.get("history") as Array
	if bool(dialogue.get("_fixed_typewriter_running")) or String((history[-1] as Dictionary).get("text", "")) != "甲乙":
		_fail("First authored page did not finish through the typewriter")
		return
	if TimeSystem.total_minutes() != 550:
		_fail("Each completed authored NPC page did not advance time by 10 minutes")
		return
	var choice_buttons: Array[Button] = dialogue.get("choice_buttons") as Array[Button]
	if choice_buttons.is_empty() or not bool(choice_buttons[0].get_meta("fixed_event_advance", false)):
		_fail("Continue button was not enabled after the first page")
		return
	choice_buttons[0].pressed.emit()
	await get_tree().create_timer(0.30).timeout
	if not (dialogue.get("_active_fixed_event") as Dictionary).is_empty():
		_fail("Final authored page did not complete the event")
		return
	if bool(choice_buttons[0].get_meta("fixed_event_advance", false)):
		_fail("Continue metadata leaked into the event's final choices")
		return
	if TimeSystem.total_minutes() != 560:
		_fail("Final authored NPC page did not advance time by 10 minutes")
		return

	print("FIXED_STORY_TYPEWRITER_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("FIXED_STORY_TYPEWRITER_SMOKE_FAILED: " + message)
	get_tree().quit(1)
