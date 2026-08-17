extends Node
## Headless regression smoke test for the mysterious hermit's staged quest.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()

	var profile: Dictionary = NpcRegistry.get_dialogue_profile("mysterious_hermit")
	if profile.is_empty():
		_fail("Mysterious hermit was not loaded as an active NPC profile")
		return
	if NpcRegistry.get_disclosure_level(profile) != 0:
		_fail("Mysterious hermit did not start at disclosure level 0")
		return
	if not ItemDB.exists("abandoned_clinic_key"):
		_fail("Abandoned clinic key was not registered in ItemDB")
		return
	if SkillSystem.is_skill_available_for_npc("persuade_ally", "wu_xuan"):
		_fail("Altar alliance skill was available before the evidence handoff")
		return

	var opening: Dictionary = NpcStoryEvent.find_available_event(profile, "dialogue_open")
	if String(opening.get("id", "")) != "hermit_first_meeting":
		_fail("First-meeting authored event was not selected")
		return
	NpcStoryEvent.apply_event(opening)
	if GameState.get_quest_stage("hermit_pollution_investigation") != 1:
		_fail("First meeting did not start the pollution investigation")
		return
	if not GameState.has_item("abandoned_clinic_key"):
		_fail("First meeting did not grant the abandoned clinic key")
		return
	var first_meeting_time: Variant = GameState.get_investigation_state("hermit_first_meeting_time", {})
	if first_meeting_time is not Dictionary:
		_fail("First meeting time was not recorded")
		return

	GameState.trigger_clue("dorm_shower_water_contamination")
	var evidence_ids: Array[String] = ["dorm_shower_water_contamination"]
	var too_early: Dictionary = NpcStoryEvent.find_presented_clue_event(profile, evidence_ids)
	if not too_early.is_empty():
		_fail("Pollution evidence was accepted before tomorrow at the same time")
		return

	TimeSystem.advance_minutes(TimeSystem.MINUTES_PER_DAY)
	var evidence_event: Dictionary = NpcStoryEvent.find_presented_clue_event(profile, evidence_ids)
	if String(evidence_event.get("id", "")) != "hermit_pollution_evidence_presented":
		_fail("Pollution evidence was not accepted after 24 in-game hours")
		return
	NpcStoryEvent.apply_event(evidence_event)
	if GameState.get_quest_stage("hermit_pollution_investigation") != 2:
		_fail("Evidence handoff did not complete the first-stage investigation")
		return
	if NpcRegistry.get_disclosure_level(profile) != 1:
		_fail("Evidence handoff did not unlock disclosure level 1")
		return
	if not SkillSystem.is_skill_available_for_npc("persuade_ally", "wu_xuan"):
		_fail("Evidence handoff did not unlock the altar alliance skill for villagers")
		return
	if SkillSystem.is_skill_available_for_npc("persuade_ally", "mysterious_hermit"):
		_fail("Altar alliance skill was incorrectly offered against the hermit")
		return
	if not GameState.has_clue("hermit_reveals_altar_plan"):
		_fail("Altar plan clue was not recorded")
		return

	print("HERMIT_PROGRESSION_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("HERMIT_PROGRESSION_SMOKE_FAILED: " + message)
	get_tree().quit(1)
