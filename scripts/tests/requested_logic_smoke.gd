extends Node
## Regression coverage for the August scene/dialogue fixes.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()

	GameState.set_investigation_state("lin_deshan:diary_level", 1)
	var lin_profile := NpcRegistry.get_dialogue_profile("lin_deshan")
	var lin_event := NpcStoryEvent.find_event(lin_profile, "lin_deshan_diary_level_one")
	if lin_event.is_empty() or not NpcStoryEvent.is_available(lin_profile, lin_event):
		_fail("Lin Deshan diary event is not deterministically available; events=%s state=%s" % [str(lin_profile.get("fixed_story_events", [])), str(GameState.get_investigation_state("lin_deshan:diary_level", -1))])
		return
	lin_profile["_forced_opening_event_id"] = "lin_deshan_diary_level_one"
	var dialogue := (load("res://scenes/ui/DialogueUI.tscn") as PackedScene).instantiate()
	add_child(dialogue)
	await get_tree().process_frame
	dialogue.open_dialogue(lin_profile)
	if String((dialogue.get("_active_fixed_event") as Dictionary).get("id", "")) != "lin_deshan_diary_level_one":
		_fail("Lin Deshan diary completion opened LLM dialogue instead of authored text")
		return
	dialogue.queue_free()

	GameState.set_quest_stage("gong_toolbox", 2)
	GameState.add_item("gong_toolbox")
	var gong_event := NpcStoryEvent.find_available_event(NpcRegistry.get_dialogue_profile("gong_zhong"), "dialogue_open")
	if String(gong_event.get("id", "")) != "gong_toolbox_completed":
		_fail("Toolbox possession did not skip Gong Zhong's first-meeting event")
		return

	GameState.reset_for_new_game()
	GameState.trigger_clue("factory_withdrawal_notice")
	GameState.set_quest_stage("wu_xuan_photo_location_match", 2)
	var wu_xuan_profile := NpcRegistry.get_dialogue_profile("wu_xuan")
	var premature_notice_event := NpcStoryEvent.find_presented_clue_event(wu_xuan_profile, ["factory_withdrawal_notice"])
	if String(premature_notice_event.get("id", "")) == "wu_xuan_factory_notice_presented":
		_fail("Presenting the factory notice before Wu Xuan publishes the task advanced the story")
		return
	var photo_event := NpcStoryEvent.find_available_event(wu_xuan_profile, "dialogue_open")
	if String(photo_event.get("id", "")) != "wu_xuan_photo_match_completed":
		_fail("Wu Xuan photo completion event was not available")
		return
	NpcStoryEvent.apply_event(photo_event)
	if GameState.get_quest_stage("wu_xuan_factory_notice") != 1:
		_fail("Merely holding the factory notice completed Wu Xuan's newly published task")
		return
	var presented_notice_event := NpcStoryEvent.find_presented_clue_event(wu_xuan_profile, ["factory_withdrawal_notice"])
	if String(presented_notice_event.get("id", "")) != "wu_xuan_factory_notice_presented":
		_fail("Explicitly presenting the factory notice did not select its authored progression event")
		return
	var notice_pages := NpcStoryEvent.get_pages(presented_notice_event)
	if notice_pages.size() != 4 or not notice_pages[1].contains("已归档") or not notice_pages[3].contains("限定查阅"):
		_fail("Wu Xuan's factory-notice follow-up was not merged into the presented event")
		return
	NpcStoryEvent.apply_event(presented_notice_event)
	if GameState.get_quest_stage("wu_xuan_factory_notice") != 2:
		_fail("Explicitly presenting the factory notice did not advance Wu Xuan's task")
		return
	if not GameState.has_item("village_committee_archive_access") or not GameState.has_clue("wu_xuan_archive_tampering_suspected"):
		_fail("The merged factory-notice event did not grant its archive rewards")
		return

	GameState.set_quest_stage("hermit_pollution_investigation", 1)
	GameState.trigger_clue("water_contamination_proof")
	GameState.trigger_event("hermit_first_meeting")
	var hermit_event := NpcStoryEvent.find_available_event(NpcRegistry.get_dialogue_profile("mysterious_hermit"), "dialogue_open")
	if String(hermit_event.get("id", "")) != "hermit_pollution_evidence_presented":
		_fail("Held pollution evidence did not trigger the hermit event")
		return

	GameState.set_investigation_state("night_li_rear_room_unlocked", true)
	var night_li_profile := NpcRegistry.get_dialogue_profile("li_leshui_night")
	var night_li_first := NpcStoryEvent.find_available_event(night_li_profile, "dialogue_open")
	var first_pages_text := " ".join(night_li_first.get("pages", []))
	if String(night_li_first.get("id", "")) != "li_leshui_night_first_meeting" or not first_pages_text.contains("反被它吞噬") or not first_pages_text.contains("旧水尺"):
		_fail("Night Taoist rear-room first meeting was not the authored JSON story")
		return
	GameState.trigger_event("li_leshui_night_first_meeting")
	GameState.add_item("old_water_gauge")
	var water_event := NpcStoryEvent.find_available_event(night_li_profile, "dialogue_open")
	if String(water_event.get("id", "")) != "li_leshui_night_water_gauge_returned":
		_fail("Held bronze water gauge did not trigger the night Taoist event")
		return
	GameState.add_item("li_leshui_talisman")
	var hermit_attack := SkillSystem.get_attack_preview("mysterious_hermit")
	if int(hermit_attack.get("seal_reduction", 0)) != 5:
		_fail("Li Leshui's talisman did not reduce hermit attack difficulty by five")
		return
	var taoist_attack := SkillSystem.get_attack_preview("li_leshui_night")
	if int(taoist_attack.get("seal_reduction", 0)) != 0:
		_fail("Li Leshui's talisman incorrectly reduced Taoist attack difficulty")
		return
	GameState.water_contact_count = 6
	GameState.water_contact_days[str(TimeSystem.current_day)] = true
	var corruption_report: Dictionary = GameState.call("_apply_morning_status", TimeSystem.current_day)
	if String(corruption_report.get("ending_id", "")) != "pollution_follower":
		_fail("Maximum water-contact corruption did not schedule the pollution ending")
		return

	var interaction := SceneItemInteraction.new()
	add_child(interaction)
	await get_tree().process_frame
	interaction.open_choice({
		"id": "image_smoke",
		"title": "Image smoke",
		"description": "Image should be visible",
		"image_texture": load("res://assets/documents/swimming.png"),
		"allow_input": true,
		"choices": [{"id": "leave", "label": "Leave", "close": true}],
	})
	if interaction.get("_document_viewport") == null or interaction.get("_document_image") == null:
		_fail("Choice image viewport was not created")
		return
	interaction.queue_free()

	GameState.reset_for_new_game()
	TimeSystem.advance_to_today(19 * 60)
	var chief_scene := (load("res://scenes/locations/VillageChiefHouse.tscn") as PackedScene).instantiate()
	add_child(chief_scene)
	await get_tree().process_frame
	var chief_nodes: Dictionary = chief_scene.get("_village_chief_nodes")
	if String((chief_scene.get_node("BackgroundTexture") as TextureRect).texture.resource_path) != "res://assets/scenes/village_chief_house_night.png":
		_fail("Village chief house did not enter its night background immediately")
		return
	if (chief_nodes["chief"]["button"] as Button).visible:
		_fail("Village chief mask remained visible at night")
		return
	if not (chief_nodes["television"]["button"] as Button).visible or not (chief_nodes["safe"]["button"] as Button).visible:
		_fail("Village chief house item masks were unavailable at night")
		return
	if not is_instance_valid(GameState.get("_night_return_dialog")) or not GameState.get("_night_return_dialog").has_method("open_paged_text"):
		_fail("Night return prompt did not reuse SceneItemInteraction")
		return
	chief_scene.queue_free()
	GameState.call("_dismiss_night_return_dialog")

	GameState.reset_for_new_game()
	TimeSystem.advance_minutes(2 * TimeSystem.MINUTES_PER_DAY + (16 * 60 + 50) - 9 * 60)
	if not NpcRegistry.is_mysterious_hermit_road_time():
		_fail("Hermit was absent during the configured daily appearance window")
		return
	GameState.set_investigation_state("field_path:mysterious_hermit_met_day", TimeSystem.current_day)
	if NpcRegistry.is_mysterious_hermit_road_time():
		_fail("Hermit remained available after the daily conversation was used")
		return

	GameState.reset_for_new_game()
	var construction := (load("res://scenes/locations/ConstructionSite.tscn") as PackedScene).instantiate()
	add_child(construction)
	await get_tree().process_frame
	NpcRegistry.kill_npc("gong_zhong", "smoke test")
	await get_tree().process_frame
	if String((construction.get_node("BackgroundTexture") as TextureRect).texture.resource_path) != "res://assets/scenes/construction_site_empty.png":
		_fail("Construction site did not switch to its empty background")
		return
	var gong_hotspot: Dictionary = (construction.get("_scene_npc_hotspots") as Dictionary).get("gong_zhong", {})
	if not gong_hotspot.is_empty() and (gong_hotspot["button"] as Button).visible:
		_fail("Gong Zhong mask remained visible after death")
		return
	if int(construction.call("_parse_taoist_trust_modifier", "MODIFIER +4：理由包含污染证据。", "")) != 4:
		_fail("Night Taoist LLM modifier output could not be parsed")
		return
	construction.call("_on_morning_report_completed", "", {"ending_id": "pollution_follower"})
	if not GameState.is_game_ended() or GameState.get_ending_id() != "pollution_follower":
		_fail("Confirmed maximum-corruption report did not start the pollution ending")
		return
	get_tree().paused = false

	print("REQUESTED_LOGIC_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("REQUESTED_LOGIC_SMOKE_FAILED: " + message)
	get_tree().quit(1)
