extends Node
## Headless regression smoke test for the clue-book presentation flow.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	GameState.trigger_clue("onboarding_strange_letter")
	var strange_letter_entry: Dictionary = {}
	for entry in GameState.get_clue_book_entries():
		if String(entry.get("id", "")) == "onboarding_strange_letter":
			strange_letter_entry = entry
			break
	if String(strange_letter_entry.get("title", "")) != "一封奇怪的信":
		_fail("The onboarding strange letter is not registered in ClueDB")
		return
	var letter_responses := {
		"li_leshui_day": ["li_leshui_day_strange_letter_presented", "这是我给你写的信"],
		"li_leshui_night": ["li_leshui_night_strange_letter_presented", "应该是白天的他写的"],
		"wu_xuan": ["wu_xuan_strange_letter_presented", "联名书比对字迹"],
		"gong_zhong": ["gong_zhong_strange_letter_presented", "没见过这封信"],
		"lin_deshan": ["lin_deshan_strange_letter_presented", "没见过这封信"],
		"mu_jiang": ["mu_jiang_strange_letter_presented", "没见过这封信"],
		"mysterious_hermit": ["mysterious_hermit_strange_letter_presented", "没见过这封信"],
		"niu_lanshan": ["niu_lanshan_strange_letter_presented", "没见过这封信"],
		"wu_zhiyuan": ["wu_zhiyuan_strange_letter_presented", "没见过这封信"],
		"yu_le": ["yu_le_strange_letter_presented", "没见过这封信"],
	}
	for npc_id: String in letter_responses:
		var letter_event := NpcStoryEvent.find_presented_clue_event(
			NpcRegistry.get_dialogue_profile(npc_id),
			["onboarding_strange_letter"] as Array[String]
		)
		var expected: Array = letter_responses[npc_id]
		if String(letter_event.get("id", "")) != String(expected[0]):
			_fail("%s has no authored strange-letter response" % npc_id)
			return
		if not "\n".join(NpcStoryEvent.get_pages(letter_event)).contains(String(expected[1])):
			_fail("%s strange-letter response text is incorrect" % npc_id)
			return

	var clue_catalog: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/clues.json"))
	if clue_catalog is not Dictionary or (clue_catalog as Dictionary).get("clues", {}) is not Dictionary:
		_fail("Could not parse the clue catalog for NPC ownership coverage")
		return
	for raw_clue_id in ((clue_catalog as Dictionary)["clues"] as Dictionary):
		var clue_id := String(raw_clue_id)
		var owner_id := _owner_for_clue(clue_id)
		if owner_id.is_empty():
			continue
		var owned_event := NpcStoryEvent.find_presented_clue_event(
			NpcRegistry.get_dialogue_profile(owner_id),
			[clue_id] as Array[String]
		)
		if owned_event.is_empty():
			_fail("Owned clue %s has no presented response on %s" % [clue_id, owner_id])
			return
		if NpcStoryEvent.get_pages(owned_event).is_empty():
			_fail("Owned clue %s selects an empty presented response" % clue_id)
			return
		if clue_id == "hermit_pollution_investigation_started" and not NpcStoryEvent.get_pages(owned_event)[0].contains("医院里有检测设备"):
			_fail("Hermit pollution-investigation response is incorrect")
			return

	# 归属线索回应不得抢占原有关键剧情：首次出示仍选择带推进效果的
	# fixed_story_event；该 once 事件完成后，才回落到逐线索立场回应。
	var yu_profile := NpcRegistry.get_dialogue_profile("yu_le")
	var banquet_story := NpcStoryEvent.find_presented_clue_event(
		yu_profile,
		["yu_le_2012_fish_banquet"] as Array[String]
	)
	if String(banquet_story.get("id", "")) != "yu_le_water_evidence_presented":
		_fail("Owned-clue fallback intercepted Yu Le's original banquet story event")
		return
	GameState.trigger_event("yu_le_water_evidence_presented")
	var banquet_fallback := NpcStoryEvent.find_presented_clue_event(
		yu_profile,
		["yu_le_2012_fish_banquet"] as Array[String]
	)
	if not String(banquet_fallback.get("id", "")).ends_with("yu_le_2012_fish_banquet"):
		_fail("Yu Le's banquet clue did not fall back to its authored stance response")
		return
	if not "\n".join(NpcStoryEvent.get_pages(banquet_fallback)).contains("二〇一二年"):
		_fail("Yu Le's banquet fallback does not reflect that clue's summary")
		return

	var wu_safe_response := NpcStoryEvent.find_presented_clue_event(
		NpcRegistry.get_dialogue_profile("wu_xuan"),
		["wu_xuan_safe_key_handover"] as Array[String]
	)
	if not "\n".join(NpcStoryEvent.get_pages(wu_safe_response)).contains("不知道保险柜里有什么"):
		_fail("Wu Xuan's safe-key clue selected a generic response")
		return

	var hermit_opening := NpcStoryEvent.find_event(NpcRegistry.get_dialogue_profile("mysterious_hermit"), "hermit_first_meeting")
	var opening_effects: Dictionary = hermit_opening.get("effects", {})
	if not (opening_effects.get("trigger_clues", []) as Array).has("yu_le_2012_fish_banquet"):
		_fail("Hermit first meeting does not award the 2012 fish-banquet clue")
		return
	NpcStoryEvent.apply_event(hermit_opening)
	if not GameState.has_clue("yu_le_2012_fish_banquet"):
		_fail("Hermit first meeting did not add the fish-banquet clue to the clue book")
		return

	GameState.reset_for_new_game()
	GameState.trigger_clue("got_village_map")
	if not GameState.add_document_clue({
		"id": "clue_order_document",
		"title": "排序测试资料",
		"summary": "用于确认资料与剧情线索按取得时间混合排列。",
		"pages": ["排序测试资料。"],
	}):
		_fail("Could not add clue-order test document")
		return
	GameState.trigger_clue("gong_water_anomaly_admitted")
	var ordered_entries := GameState.get_clue_book_entries()
	var ordered_ids: Array[String] = []
	for ordered_entry in ordered_entries:
		ordered_ids.append(String(ordered_entry.get("id", "")))
	if ordered_ids.slice(0, 3) != ["got_village_map", "clue_order_document", "gong_water_anomaly_admitted"]:
		_fail("Clue book is not ordered oldest-to-newest: %s" % str(ordered_ids))
		return

	GameState.reset_for_new_game()
	GameState.set_quest_stage("wu_xuan_factory_notice", 2)
	GameState.trigger_clue("gong_water_anomaly_admitted")

	var entries := GameState.get_clue_book_entries()
	var evidence_entry: Dictionary = {}
	for entry in entries:
		if String(entry.get("id", "")) == "gong_water_anomaly_admitted":
			evidence_entry = entry
			break
	if evidence_entry.is_empty():
		_fail("Story clue did not appear in the unified clue book")
		return
	if String(evidence_entry.get("title", "")) != "龚忠承认水源异常":
		_fail("ClueDB metadata was not applied")
		return

	var profile := NpcRegistry.get_dialogue_profile("wu_xuan")
	var event := NpcStoryEvent.find_presented_clue_event(
		profile,
		["gong_water_anomaly_admitted"] as Array[String]
	)
	if String(event.get("id", "")) != "wu_xuan_pollution_evidence_presented":
		_fail("Wu Xuan critical clue event was not selected")
		return

	var popup := ClueBookPopup.new()
	get_tree().root.add_child(popup)
	await get_tree().process_frame
	popup.open_ui(entries, true)
	var has_present_button := false
	for node in popup.find_children("*", "Button", true, false):
		if node is Button and (node as Button).text == "出示":
			has_present_button = true
			break
	if not has_present_button:
		_fail("Clue book did not render a present button")
		return

	# Exercise DialogueUI integration without contacting the provider: a seeded
	# history makes the dialogue wait for player input, then presentation must
	# immediately enter the authored two-page Wu Xuan event.
	MemoryStore.reset()
	MemoryStore.append_turn("wu_xuan", "你好", "你好。", [])
	var dialogue_scene := load("res://scenes/ui/DialogueUI.tscn") as PackedScene
	if dialogue_scene == null:
		_fail("DialogueUI scene could not be loaded")
		return
	var dialogue := dialogue_scene.instantiate()
	get_tree().root.add_child(dialogue)
	await get_tree().process_frame
	dialogue.open_dialogue(profile)
	dialogue.call("_on_clue_book_present_requested", evidence_entry)
	var active_event: Variant = dialogue.get("_active_fixed_event")
	if active_event is not Dictionary or String((active_event as Dictionary).get("id", "")) != "wu_xuan_pollution_evidence_presented":
		_fail("DialogueUI did not enter the authored critical clue event")
		return

	# A non-key clue must take the normal provider path with its safe catalog
	# summary included in the user turn, instead of selecting a fixed event.
	var mock_script: Script = load("res://scripts/llm/MockLLM.gd") as Script
	var mock_provider: Node = mock_script.new()
	mock_provider.name = "ClueSmokeMock"
	LLMService.set_provider(mock_provider)
	GameState.trigger_clue("got_village_map")
	var ordinary_entry: Dictionary = {}
	for entry in GameState.get_clue_book_entries():
		if String(entry.get("id", "")) == "got_village_map":
			ordinary_entry = entry
			break
	MemoryStore.append_turn("lin_deshan", "你好", "喝口水吧。", [])
	var ordinary_dialogue := dialogue_scene.instantiate()
	get_tree().root.add_child(ordinary_dialogue)
	await get_tree().process_frame
	ordinary_dialogue.open_dialogue(NpcRegistry.get_dialogue_profile("lin_deshan"))
	ordinary_dialogue.call("_on_clue_book_present_requested", ordinary_entry)
	var sent_text := String(ordinary_dialogue.get("_last_user_text"))
	if not sent_text.contains("【出示线索】思源村地图") or not sent_text.contains("路线参考"):
		_fail("Ordinary clue summary was not supplied to the LLM request")
		return
	var ordinary_active: Variant = ordinary_dialogue.get("_active_fixed_event")
	if ordinary_active is Dictionary and not (ordinary_active as Dictionary).is_empty():
		_fail("Ordinary clue incorrectly selected a fixed event")
		return

	print("CLUE_PRESENTATION_SMOKE_OK entries=%d event=%s" % [entries.size(), event.get("id", "")])
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("CLUE_PRESENTATION_SMOKE_FAILED: " + message)
	get_tree().quit(1)


func _owner_for_clue(clue_id: String) -> String:
	if clue_id.begins_with("wu_xuan_") or clue_id == "medical_exam_wu_xuan":
		return "wu_xuan"
	if clue_id.begins_with("wu_chief_") or (clue_id.begins_with("wu_") and not clue_id.begins_with("wu_xuan_")) or clue_id == "medical_exam_wu_zhiyuan":
		return "wu_zhiyuan"
	if clue_id.begins_with("hermit_") or clue_id.begins_with("mysterious_stranger_"):
		return "mysterious_hermit"
	if clue_id.begins_with("gong_") or clue_id == "medical_exam_gong_zhong":
		return "gong_zhong"
	if clue_id.begins_with("lin_") or clue_id == "medical_exam_lin_deshan":
		return "lin_deshan"
	if clue_id.begins_with("niu_"):
		return "niu_lanshan"
	if clue_id.begins_with("yu_le_"):
		return "yu_le"
	if clue_id.begins_with("mu_jiang_"):
		return "mu_jiang"
	if clue_id.begins_with("day_li_"):
		return "li_leshui_day"
	if clue_id.begins_with("night_li_"):
		return "li_leshui_night"
	return ""
