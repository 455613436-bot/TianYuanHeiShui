extends Node
## Headless regression smoke test for the clue-book presentation flow.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
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
	GameState.trigger_event("wu_xuan_factory_notice_completed")
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
