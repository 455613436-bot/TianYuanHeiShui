extends Node
## Headless regression smoke test for the abandoned clinic's permanent open state.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()
	if SkillSystem.is_medical_exam_unlocked():
		_fail("Medical exam started unlocked")
		return
	if _skill_list_contains("medical_exam"):
		_fail("Locked medical exam appeared in the NPC skill list")
		return

	var clinic_scene := load("res://scenes/locations/AbandonedClinic.tscn") as PackedScene
	if clinic_scene == null:
		_fail("Abandoned clinic scene could not be loaded")
		return
	var clinic := clinic_scene.instantiate()
	get_tree().root.add_child(clinic)
	await get_tree().process_frame
	if not clinic.has_node("ClinicDoorHotspot") or clinic.has_node("ClinicFileHotspot"):
		_fail("Locked clinic did not show only the door interaction")
		return

	var door_ui: SceneItemInteraction = clinic.get_node("ClinicDoorInteraction") as SceneItemInteraction
	door_ui.choice_selected.emit("abandoned_clinic_door_lock", "use_clinic_key", {})
	await get_tree().process_frame
	if not bool(GameState.get_investigation_state("abandoned_clinic_door_unlocked", false)):
		_fail("Unlocking the clinic did not persist its state")
		return
	if not clinic.has_node("ClinicFileHotspot") or not clinic.has_node("ClinicEquipmentHotspot"):
		_fail("Open clinic interactions were not created immediately")
		return
	var background: TextureRect = clinic.get_node("BackgroundTexture") as TextureRect
	if background.texture == null or String(background.texture.resource_path) != "res://assets/scenes/abandoned_clinic_open.png":
		_fail("Clinic background did not switch to the open-door image")
		return

	var file_ui: SceneItemInteraction = clinic.get_node("ClinicFileInteraction") as SceneItemInteraction
	clinic.call("_open_clinic_files", clinic.get_node("ClinicFileHighlight"), file_ui)
	file_ui.call("_advance_paged_text")
	file_ui.call("_advance_paged_text")
	if not GameState.has_clue("abandoned_clinic_medical_records"):
		_fail("Clinic records were not added to the clue book")
		return

	var equipment_ui: SceneItemInteraction = clinic.get_node("ClinicEquipmentInteraction") as SceneItemInteraction
	clinic.call("_learn_medical_exam", clinic.get_node("ClinicEquipmentHighlight"), equipment_ui)
	if not SkillSystem.is_medical_exam_unlocked() or not _skill_list_contains("medical_exam"):
		_fail("Clinic equipment did not unlock medical exam")
		return

	clinic.queue_free()
	await get_tree().process_frame
	var restored_clinic := clinic_scene.instantiate()
	get_tree().root.add_child(restored_clinic)
	await get_tree().process_frame
	if restored_clinic.has_node("ClinicDoorHotspot") or not restored_clinic.has_node("ClinicFileHotspot"):
		_fail("Open clinic state was not restored on scene re-entry")
		return

	print("CLINIC_UNLOCK_SMOKE_OK")
	get_tree().quit(0)


func _skill_list_contains(skill_id: String) -> bool:
	for skill in SkillSystem.skills_for_target(true, "village_committee"):
		if String(skill.get("id", "")) == skill_id:
			return true
	return false


func _fail(message: String) -> void:
	push_error("CLINIC_UNLOCK_SMOKE_FAILED: " + message)
	get_tree().quit(1)
