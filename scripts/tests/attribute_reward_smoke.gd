extends Node
## Headless regression smoke test for the committee computer intellect reward.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()
	if not GameState.set_attributes({
		"strength": 3,
		"agility": 2,
		"intellect": 4,
		"charisma": 1,
	}):
		_fail("Could not seed valid player attributes")
		return

	var committee_scene := load("res://scenes/locations/VillageCommittee.tscn") as PackedScene
	if committee_scene == null:
		_fail("Village committee scene could not be loaded")
		return
	var committee := committee_scene.instantiate()
	get_tree().root.add_child(committee)
	await get_tree().process_frame

	var interaction_ui := committee.get_node_or_null("CommitteeComputerInteraction") as SceneItemInteraction
	if interaction_ui == null:
		_fail("Committee computer interaction was not created")
		return

	GameState.add_item("village_committee_computer_game_access")
	var before := GameState.get_attribute("intellect")
	committee.call("_on_committee_computer_choice", "committee_computer", "play_game", {}, interaction_ui)
	await get_tree().process_frame

	if GameState.get_attribute("intellect") != before + 1:
		_fail("Committee game did not increase intellect")
		return
	if GameState.attributes.has("intelligence"):
		_fail("Invalid intelligence attribute key was created")
		return
	if not bool(GameState.get_investigation_state("wu_xuan_computer_game_completed", false)):
		_fail("Committee game completion state was not persisted")
		return
	if GameState.grant_permanent_attribute("intellect", 1) != 0 or GameState.get_attribute("intellect") != GameState.ATTRIBUTE_MAX:
		_fail("Intellect cap was not preserved")
		return

	committee.queue_free()
	print("ATTRIBUTE_REWARD_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("ATTRIBUTE_REWARD_SMOKE_FAILED: " + message)
	get_tree().quit(1)
