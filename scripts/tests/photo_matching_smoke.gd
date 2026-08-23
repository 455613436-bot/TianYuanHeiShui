extends Node
## Headless regression smoke test for the scene-photo matching task.

var _result: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()

	var ui := PhotoMatchingInteraction.new()
	get_tree().root.add_child(ui)
	await get_tree().process_frame

	var snippets := [
		{
			"label": "局部 A",
			"image_path": "res://assets/scenes/village_chief_house.png",
			"region": Rect2(900, 150, 360, 300),
			"answer_id": "village_chief_house",
		},
		{
			"label": "局部 B",
			"image_path": "res://assets/scenes/lakeside_dock.png",
			"region": Rect2(0, 470, 480, 350),
			"answer_id": "lakeside_dock",
		},
	]
	var options := [
		{"id": "village_chief_house", "label": "村长家"},
		{"id": "lakeside_dock", "label": "湖边码头"},
		{"id": "taoist_temple", "label": "道观"},
	]
	ui.submitted.connect(func(result: Dictionary) -> void:
		_result = result
	)
	ui.open_task(
		"photo_matching_smoke",
		"旧照片地点匹配",
		"请选择每张局部图所属的场景。",
		snippets,
		options,
		"item_check:photo_matching_smoke"
	)
	await get_tree().process_frame

	var dropdowns: Array[OptionButton] = []
	for node in ui.find_children("*", "OptionButton", true, false):
		if node is OptionButton:
			dropdowns.append(node as OptionButton)
	if dropdowns.size() != snippets.size():
		_fail("Matching task did not render one dropdown per snippet")
		return
	for index in range(dropdowns.size()):
		var dropdown := dropdowns[index]
		var answer_id := String(snippets[index].get("answer_id", ""))
		for item_index in range(dropdown.item_count):
			if str(dropdown.get_item_metadata(item_index)) == answer_id:
				dropdown.select(item_index)
				dropdown.item_selected.emit(item_index)
				break
	ui.call("_update_submit_state")
	var submit_button: Button = null
	for node in ui.find_children("*", "Button", true, false):
		if node is Button and String((node as Button).text) == "提交匹配":
			submit_button = node as Button
			break
	if submit_button == null or submit_button.disabled:
		_fail("Matching task did not enable submit after all selections")
		return
	submit_button.pressed.emit()

	if not bool(_result.get("passed", false)) or int(_result.get("correct", 0)) != 2:
		_fail("Correct scene selections did not complete the matching task")
		return
	var attempt: Variant = GameState.get_investigation_state("item_check:photo_matching_smoke", {})
	if not attempt is Dictionary or int((attempt as Dictionary).get("day", 0)) != TimeSystem.current_day:
		_fail("Matching attempt day was not persisted")
		return

	ui.open_task(
		"photo_matching_smoke",
		"旧照片地点匹配",
		"请选择每张局部图所属的场景。",
		snippets,
		options,
		"item_check:photo_matching_smoke"
	)
	await get_tree().process_frame
	var retry_submit_button: Button = null
	for node in ui.find_children("*", "Button", true, false):
		if node is Button and String((node as Button).text) == "提交匹配":
			retry_submit_button = node as Button
			break
	if not ui.get_node("PhotoMatchingOverlay").visible or not bool(ui.get("_submitted")) or retry_submit_button == null or not retry_submit_button.disabled:
		_fail("The same-day matching attempt was not blocked")
		return

	ui.queue_free()
	print("PHOTO_MATCHING_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("PHOTO_MATCHING_SMOKE_FAILED: " + message)
	get_tree().quit(1)
