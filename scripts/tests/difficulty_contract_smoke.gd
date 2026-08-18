extends Node
## Headless regression smoke test for the 1-25 raw difficulty contract.

var _captured_result: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()

	var capped := CheckSystem.perform_check("力量", 30, 0, "raw difficulty cap")
	if int(capped.get("raw_difficulty", 0)) != CheckSystem.RAW_DIFFICULTY_MAX:
		_fail("Raw difficulty 30 did not clamp to the contract maximum")
		return

	var preview := SkillSystem.get_attack_preview("li_leshui_day")
	if int(preview.get("base_difficulty", 0)) != CheckSystem.RAW_DIFFICULTY_MAX:
		_fail("High-difficulty attack preview is outside the raw difficulty contract")
		return

	var attack := SkillSystem.perform_attack_check("li_leshui_day")
	if int(attack.get("raw_difficulty", 0)) != int(preview.get("base_difficulty", 0)):
		_fail("Attack execution and preview use different raw difficulties")
		return
	if int(attack.get("final_difficulty", 0)) != int(preview.get("final_difficulty", 0)):
		_fail("Attack execution and preview use different final difficulties")
		return

	var clinic_scene := load("res://scenes/locations/AbandonedClinic.tscn") as PackedScene
	if clinic_scene == null:
		_fail("Abandoned clinic scene could not be loaded")
		return
	var clinic := clinic_scene.instantiate()
	get_tree().root.add_child(clinic)
	await get_tree().process_frame
	var door := clinic.get_node_or_null("ClinicDoorHotspot") as Button
	var door_ui := clinic.get_node_or_null("ClinicDoorInteraction") as SceneItemInteraction
	if door == null or door_ui == null:
		_fail("Clinic door interaction was not created")
		return

	_captured_result = {}
	door_ui.choice_selected.connect(func(_interaction_id: String, _choice_id: String, result: Dictionary) -> void:
		_captured_result = result
	)
	door.pressed.emit()
	await get_tree().process_frame
	var pry_button: Button = null
	for node in door_ui.find_children("*", "Button", true, false):
		if node is Button and String((node as Button).text).contains("撬锁"):
			pry_button = node as Button
			break
	if pry_button == null:
		_fail("Clinic pry-lock choice was not rendered")
		return
	pry_button.pressed.emit()
	if int(_captured_result.get("raw_difficulty", 0)) != CheckSystem.RAW_DIFFICULTY_MAX:
		_fail("Clinic pry-lock path still passes a difficulty above 25")
		return

	clinic.queue_free()
	print("DIFFICULTY_CONTRACT_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("DIFFICULTY_CONTRACT_SMOKE_FAILED: " + message)
	get_tree().quit(1)
