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
	var expected_masks := {
		"CommitteePhotosHotspot": "res://assets/scenes/masks/committee_photos_mask.png",
		"HospitalNoticeHotspot": "res://assets/scenes/masks/hospital_notice_mask.png",
		"WuXuanHotspot": "res://assets/scenes/masks/wu_xuan_mask.png",
		"CommitteeComputerHotspot": "res://assets/scenes/masks/committee_computer_mask.png",
	}
	for hotspot_name in expected_masks:
		var hotspot := committee.get_node_or_null(hotspot_name) as Button
		var hit_area := committee.get_node_or_null("%s/MaskHitArea" % hotspot_name) as TextureButton
		if hotspot == null or hit_area == null:
			_fail("Committee mask hotspot was not created: %s" % hotspot_name)
			return
		var mask_texture := hit_area.texture_normal
		var mask_image := mask_texture.get_image() if mask_texture != null else null
		if mask_texture == null or mask_texture.resource_path != expected_masks[hotspot_name]:
			_fail("Committee hotspot uses the wrong mask: %s" % hotspot_name)
			return
		if mask_image == null or mask_image.get_size() != Vector2i(1920, 1080):
			_fail("Committee mask is not aligned to the 1920x1080 scene: %s" % hotspot_name)
			return
		if hit_area.texture_click_mask == null:
			_fail("Committee mask did not generate an alpha click map: %s" % hotspot_name)
			return
		if hotspot.pressed.get_connections().is_empty():
			_fail("Committee mask lost its original interaction callback: %s" % hotspot_name)
			return

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
	var after_first_play := GameState.get_attribute("intellect")
	var time_before_replay := TimeSystem.total_minutes()
	committee.call("_on_committee_computer_choice", "committee_computer", "play_game", {}, interaction_ui)
	await get_tree().process_frame
	if GameState.get_attribute("intellect") != after_first_play:
		_fail("Committee game replay granted the one-time intellect reward again")
		return
	if TimeSystem.total_minutes() != time_before_replay + 240:
		_fail("Committee game replay did not consume four hours")
		return

	committee.queue_free()
	print("ATTRIBUTE_REWARD_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("ATTRIBUTE_REWARD_SMOKE_FAILED: " + message)
	get_tree().quit(1)
