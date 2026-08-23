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
	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	dialogue.call("_on_dialogue_fast_forward_input", right_click)
	if not bool(dialogue.get("_fixed_typewriter_running")):
		_fail("Right click unexpectedly fast-forwarded authored dialogue")
		return
	var left_click := InputEventMouseButton.new()
	left_click.button_index = MOUSE_BUTTON_LEFT
	left_click.pressed = true
	dialogue.call("_on_dialogue_fast_forward_input", left_click)
	if bool(dialogue.get("_fixed_typewriter_running")):
		_fail("Dialogue text-area left click rejected fast-forward")
		return
	await get_tree().process_frame
	var history: Array = dialogue.get("history") as Array
	if bool(dialogue.get("_fixed_typewriter_running")) or String((history[-1] as Dictionary).get("text", "")) != "甲乙":
		_fail("First authored page did not finish through fast-forward")
		return
	if TimeSystem.total_minutes() != 550:
		_fail("Fast-forwarded authored page did not advance time exactly once")
		return
	if bool(dialogue.call("request_fast_forward")) or TimeSystem.total_minutes() != 550:
		_fail("Repeated click re-completed the first authored page")
		return
	var choice_buttons: Array[Button] = dialogue.get("choice_buttons") as Array[Button]
	if choice_buttons.is_empty() or not bool(choice_buttons[0].get_meta("fixed_event_advance", false)):
		_fail("Continue button was not enabled after the first page")
		return
	choice_buttons[0].pressed.emit()
	await get_tree().process_frame
	if not bool(dialogue.call("request_fast_forward")):
		_fail("Final authored page rejected fast-forward")
		return
	await get_tree().process_frame
	if not (dialogue.get("_active_fixed_event") as Dictionary).is_empty():
		_fail("Final authored page did not complete the event")
		return
	if bool(choice_buttons[0].get_meta("fixed_event_advance", false)):
		_fail("Continue metadata leaked into the event's final choices")
		return
	if TimeSystem.total_minutes() != 560:
		_fail("Final authored NPC page did not advance time by 10 minutes")
		return

	dialogue.call("_submit_fixed_choice_reply", "追问", "戊己")
	if not bool(dialogue.get("_fixed_choice_typewriter_running")):
		_fail("Fixed choice reply did not start typing")
		return
	if not bool(dialogue.call("request_fast_forward")):
		_fail("Fixed choice reply rejected fast-forward")
		return
	await get_tree().process_frame
	history = dialogue.get("history") as Array
	if bool(dialogue.get("_fixed_choice_typewriter_running")) or String((history[-1] as Dictionary).get("text", "")) != "戊己":
		_fail("Fixed choice reply did not reveal its complete text")
		return
	if TimeSystem.total_minutes() != 570:
		_fail("Fast-forwarded fixed choice reply did not advance time exactly once")
		return
	if bool(dialogue.call("request_fast_forward")) or TimeSystem.total_minutes() != 570:
		_fail("Repeated click re-completed the fixed choice reply")
		return

	print("FIXED_STORY_TYPEWRITER_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("FIXED_STORY_TYPEWRITER_SMOKE_FAILED: " + message)
	get_tree().quit(1)
