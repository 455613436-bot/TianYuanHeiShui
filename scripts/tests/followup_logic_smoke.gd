extends Node
## Regression coverage for death visuals, hostile retries, inventory rows, medical scope, and ending cleanup.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	if not GameState.set_attributes({"strength": 5, "agility": 2, "intellect": 2, "charisma": 1}):
		_fail("Could not seed capped attributes for daily bonus test")
		return
	GameState.call("_grant_daily_attribute_bonus", "strength")
	GameState.call("_grant_daily_attribute_bonus", "strength")
	if GameState.get_attribute("strength") != 7:
		_fail("Daily water/offering bonuses are still capped at realtime attribute 5")
		return
	GameState.reset_for_new_game()
	MemoryStore.reset()
	GameState.set_attributes({"strength": 3, "agility": 3, "intellect": 2, "charisma": 2})

	var main_scene := (load("res://scenes/main/Main.tscn") as PackedScene).instantiate()
	if not main_scene.has_node("AttributeStatusHud"):
		_fail("Village square did not include the always-visible attribute HUD")
		return
	main_scene.queue_free()

	GameState.add_item("hunting_rifle")
	GameState.add_item("li_leshui_talisman")
	var bag := (load("res://scenes/ui/ItemBagPopup.tscn") as PackedScene).instantiate()
	add_child(bag)
	await get_tree().process_frame
	bag.open_ui(["hunting_rifle", "li_leshui_talisman"], [], true)
	await get_tree().process_frame
	var item_list := bag.get_node("Center/Panel/VBox/Scroll/List") as VBoxContainer
	if item_list.get_child_count() != 2:
		_fail("Non-dialogue items were omitted from the inventory rows")
		return
	for row in item_list.get_children():
		var disabled_use_button_found := false
		for descendant in row.find_children("*", "Button", true, false):
			if (descendant as Button).text == "不可出示" and (descendant as Button).disabled:
				disabled_use_button_found = true
		if not disabled_use_button_found:
			_fail("A visible non-dialogue inventory row did not disable its use button")
			return
	bag.queue_free()

	GameState.set_investigation_state("skill_unlocked_medical_exam", true)
	if SkillSystem.is_skill_available_for_npc("medical_exam", "wu_zhiyuan"):
		_fail("Medical exam remained available for people")
		return
	if _has_skill(SkillSystem.skills_for_target(true, "village_chief_house"), "medical_exam"):
		_fail("Medical exam appeared outside the temporary dorm")
		return
	if not _has_skill(SkillSystem.skills_for_target(false, "temporary_dorm"), "medical_exam"):
		_fail("Medical exam was unavailable for dorm shower water")
		return

	NpcRegistry.mark_npc_hostile("li_leshui_day", "smoke")
	if NpcRegistry.is_npc_hostile("li_leshui_night"):
		_fail("Taoist day/night personalities incorrectly shared attack hostility")
		return
	if not SkillSystem.is_skill_available_for_npc("attack", "li_leshui_day"):
		_fail("Hostile Taoist could not be attacked again")
		return
	NpcRegistry.mark_npc_hostile("mysterious_hermit", "smoke")
	if not SkillSystem.can_retry_hostile_attack("mysterious_hermit"):
		_fail("Hostile hermit could not be attacked again")
		return
	SkillSystem.record_attack_attempt("mysterious_hermit")
	if SkillSystem.can_retry_hostile_attack("mysterious_hermit"):
		_fail("Hostile hermit could be attacked twice on the same day")
		return
	SkillSystem.record_attack_attempt("li_leshui_day")
	if not SkillSystem.has_attempted_attack_today("li_leshui_night"):
		_fail("Day and night Taoist forms did not share the daily attack limit")
		return
	TimeSystem.current_day += 1
	if SkillSystem.has_attempted_attack_today("mysterious_hermit") or SkillSystem.has_attempted_attack_today("li_leshui_day"):
		_fail("Repeatable NPC attack limit did not reset on the next day")
		return
	TimeSystem.current_day -= 1

	GameState.set_investigation_state("altar_resolution", "sealed")
	GameState.remove_item("li_leshui_talisman")
	var sealed_preview := SkillSystem.get_attack_preview("mysterious_hermit")
	if int(sealed_preview.get("seal_reduction", 0)) != 5:
		_fail("Successful sealing did not reduce hermit attack difficulty by five")
		return
	GameState.add_item("li_leshui_talisman")
	var stacked_preview := SkillSystem.get_attack_preview("mysterious_hermit")
	if int(stacked_preview.get("seal_reduction", 0)) != 10:
		_fail("Seal and talisman hermit reductions did not stack to ten")
		return
	GameState.set_investigation_state("altar_resolution", "destroyed")
	var destroyed_taoist_preview := SkillSystem.get_attack_preview("li_leshui_day")
	if int(destroyed_taoist_preview.get("seal_reduction", 0)) != 10:
		_fail("Destroyed altar did not reduce Taoist attack difficulty by ten")
		return
	var altar_preview := SkillSystem.get_altar_attack_preview("steel_pipe")
	if int(altar_preview.get("base_difficulty", 0)) != 20:
		_fail("Altar attack does not use base difficulty twenty")
		return

	GameState.reset_for_new_game()
	GameState.set_attributes({"strength": 3, "agility": 3, "intellect": 2, "charisma": 2})
	var cave := (load("res://scenes/locations/BackMountain.tscn") as PackedScene).instantiate()
	add_child(cave)
	await get_tree().process_frame
	var ritual_nodes: Dictionary = cave.get("_cave_ritual_nodes")
	var ritual_highlight := ritual_nodes.get("highlight") as MaskInteractionHighlight
	var ritual_button := ritual_nodes.get("button") as Button
	var ritual_ui := cave.get_node_or_null("CaveRitualInteraction") as SceneItemInteraction
	if ritual_highlight == null or ritual_button == null or ritual_ui == null:
		_fail("Cave altar hotspot or interaction was not created")
		return
	var exit_button := cave.get_node_or_null("CaveExitHotspot") as Button
	var exit_hit_area := cave.get_node_or_null("CaveExitHotspot/MaskHitArea") as TextureButton
	if exit_button == null or exit_hit_area == null or exit_hit_area.texture_normal == null:
		_fail("Cave rear entrance mask hotspot was not created")
		return
	if exit_hit_area.texture_normal.resource_path != "res://assets/scenes/masks/cave_entrance_mask.png":
		_fail("Cave rear return hotspot did not use the supplied entrance mask")
		return
	if exit_hit_area.texture_click_mask == null or exit_button.pressed.get_connections().is_empty():
		_fail("Cave rear entrance mask lost alpha hit mapping or its return callback")
		return
	var passage_highlight := cave.get_node_or_null("CavePassageHighlight") as MaskInteractionHighlight
	var passage_ui := cave.get_node_or_null("CavePassageInteraction") as SceneItemInteraction
	cave.call("_on_cave_passage_choice", "cave_passage", "descend", {"passed": true}, passage_ui)
	if not bool(GameState.get_investigation_state("cave_back_unlocked", false)):
		_fail("Successful cave rear check did not persist the permanent unlock state")
		return
	cave.call("_return_to_cave_front", ritual_highlight)
	cave.call("_open_cave_passage", passage_highlight, passage_ui)
	if not bool(cave.get("_showing_alternate_view")):
		_fail("Permanently unlocked cave passage asked for another check")
		return
	cave.call("_open_cave_ritual", ritual_highlight, ritual_ui)
	await get_tree().process_frame
	if not _interaction_button_texts(ritual_ui).has("游泳到对岸（力量检定 18）"):
		_fail("Unreached altar without rifle/talisman did not offer the swim check")
		return
	var water_before_swim := GameState.get_water_contact_count()
	cave.call("_on_cave_ritual_choice", "cave_ritual_table", "swim_across", {}, ritual_ui)
	await get_tree().process_frame
	if GameState.get_water_contact_count() != water_before_swim + 1:
		_fail("Altar swim attempt did not silently record one water contact")
		return
	GameState.set_investigation_state("cave_altar_reached", false)
	GameState.add_item("li_leshui_talisman")
	ritual_ui.close_interaction()
	await get_tree().process_frame
	cave.call("_open_cave_ritual", ritual_highlight, ritual_ui)
	await get_tree().process_frame
	var talisman_choices := _interaction_button_texts(ritual_ui)
	if not talisman_choices.has("高举护符") or talisman_choices.has("游泳到对岸（力量检定 18）"):
		_fail("Talisman did not replace the initial altar swim route")
		return
	cave.call("_on_cave_ritual_choice", "cave_ritual_table", "raise_talisman", {}, ritual_ui)
	await get_tree().process_frame
	if not bool(GameState.get_investigation_state("cave_altar_reached", false)):
		_fail("Raising the talisman did not permanently unlock the far bank")
		return
	GameState.add_item("hunting_rifle")
	GameState.add_item("old_water_gauge")
	ritual_ui.close_interaction()
	await get_tree().process_frame
	cave.call("_open_cave_ritual", ritual_highlight, ritual_ui)
	await get_tree().process_frame
	var reached_choices := _interaction_button_texts(ritual_ui)
	for expected_choice: String in ["使用猎枪摧毁祭坛", "摧毁祭坛（力量攻击检定，基础难度 20）"]:
		if not reached_choices.has(expected_choice):
			_fail("Reached altar is missing choice: %s" % expected_choice)
			return
	if not _has_button_containing(reached_choices, "使用水尺封印"):
		_fail("Reached altar with water gauge did not offer sealing")
		return
	cave.set("_showing_alternate_view", true)
	GameState.set_investigation_state("altar_resolution", "sealed")
	cave.call("_refresh_cave_view")
	if ritual_button.visible or not ritual_button.disabled:
		_fail("Resolved altar mask remained clickable")
		return
	cave.queue_free()
	await get_tree().process_frame

	GameState.reset_for_new_game()
	GameState.set_attributes({"strength": 3, "agility": 3, "intellect": 2, "charisma": 2})
	var dock := (load("res://scenes/locations/LakesideDock.tscn") as PackedScene).instantiate()
	add_child(dock)
	await get_tree().process_frame
	var fishing_ui := dock.get_node_or_null("DockFishingInteraction") as SceneItemInteraction
	if fishing_ui == null:
		_fail("Dock fishing interaction was not created")
		return
	dock.call("_on_dock_fishing_choice", "lakeside_dock_fishing", "fish", {}, fishing_ui)
	if GameState.has_item("climbing_rope"):
		_fail("Climbing rope was awarded before the second fishing activity")
		return
	dock.call("_on_dock_fishing_choice", "lakeside_dock_fishing", "fish", {}, fishing_ui)
	if int(GameState.get_investigation_state("lakeside_dock:fishing_count", 0)) != 2 or not GameState.has_item("climbing_rope"):
		_fail("Second fishing activity did not award the climbing rope")
		return
	dock.queue_free()
	await get_tree().process_frame

	GameState.reset_for_new_game()
	GameState.set_investigation_state("farmland:birds_driven_away", true)
	if GameState.has_clue("niu_water_channel_object"):
		_fail("Bird-task success added the water-channel clue before the reward dialogue")
		return
	var niu_profile := NpcRegistry.get_dialogue_profile("niu_lanshan")
	var niu_reward_event := NpcStoryEvent.find_event(niu_profile, "niu_lanshan_bird_task_reward")
	if niu_reward_event.is_empty() or not NpcStoryEvent.is_available(niu_profile, niu_reward_event):
		_fail("Farmer reward dialogue was not available after driving away the birds")
		return
	NpcStoryEvent.apply_event(niu_reward_event)
	if not GameState.has_clue("niu_water_channel_object"):
		_fail("Farmer reward dialogue did not add the water-channel clue")
		return

	GameState.reset_for_new_game()
	var pavilion := (load("res://scenes/locations/LakesidePavilion.tscn") as PackedScene).instantiate()
	add_child(pavilion)
	await get_tree().process_frame
	NpcRegistry.kill_npc("lin_deshan", "smoke")
	await get_tree().process_frame
	var pavilion_texture := (pavilion.get_node("BackgroundTexture") as TextureRect).texture
	if pavilion_texture == null or pavilion_texture.resource_path != "res://assets/scenes/lakeside_pavilion_empty.png":
		_fail("Lakeside pavilion did not switch to its empty background after Lin Deshan died")
		return
	var lin_hotspot: Dictionary = (pavilion.get("_scene_npc_hotspots") as Dictionary).get("lin_deshan", {})
	if not lin_hotspot.is_empty() and (lin_hotspot.get("button") as Button).visible:
		_fail("Lin Deshan mask remained visible after death")
		return
	pavilion.queue_free()
	await get_tree().process_frame

	GameState.reset_for_new_game()
	var farmer_death_scene := (load("res://scenes/locations/Farmland.tscn") as PackedScene).instantiate()
	add_child(farmer_death_scene)
	await get_tree().process_frame
	var farmer_hotspot: Dictionary = (farmer_death_scene.get("_scene_npc_hotspots") as Dictionary).get("niu_lanshan", {})
	if farmer_hotspot.is_empty():
		_fail("Farmer mask was not registered for presence refresh")
		return
	NpcRegistry.kill_npc("niu_lanshan", "smoke")
	await get_tree().process_frame
	var farmland_texture := (farmer_death_scene.get_node("BackgroundTexture") as TextureRect).texture
	if farmland_texture == null or farmland_texture.resource_path != "res://assets/scenes/farmland_empty.png":
		_fail("Farmland did not switch to its empty background after the farmer died")
		return
	if (farmer_hotspot.get("button") as Button).visible:
		_fail("Farmer mask remained visible after death")
		return
	if (farmer_hotspot.get("highlight") as CanvasItem).visible:
		_fail("Farmer highlight remained visible after death")
		return
	farmer_death_scene.queue_free()
	await get_tree().process_frame

	# Every remaining authored NPC mask uses the same presence table. Audit each
	# scene registration and exercise the actual death signal once per NPC.
	var authored_mask_cases := [
		{"scene": "res://scenes/locations/VillageCommittee.tscn", "npc": "wu_xuan"},
		{"scene": "res://scenes/locations/VillageChiefHouse.tscn", "npc": "wu_zhiyuan"},
		{"scene": "res://scenes/locations/LakesideDock.tscn", "npc": "yu_le"},
		{"scene": "res://scenes/locations/CarpenterWorkshop.tscn", "npc": "mu_jiang"},
		{"scene": "res://scenes/locations/ConstructionSite.tscn", "npc": "gong_zhong"},
	]
	for mask_case: Dictionary in authored_mask_cases:
		GameState.reset_for_new_game()
		var location := (load(String(mask_case["scene"])) as PackedScene).instantiate()
		add_child(location)
		await get_tree().process_frame
		var npc_id := String(mask_case["npc"])
		var hotspot: Dictionary = (location.get("_scene_npc_hotspots") as Dictionary).get(npc_id, {})
		if hotspot.is_empty():
			_fail("%s mask was not registered for death refresh" % npc_id)
			return
		NpcRegistry.kill_npc(npc_id, "smoke")
		await get_tree().process_frame
		if (hotspot.get("button") as Button).visible:
			_fail("%s mask remained visible after death" % npc_id)
			return
		if (hotspot.get("highlight") as CanvasItem).visible:
			_fail("%s highlight remained visible after death" % npc_id)
			return
		location.queue_free()
		await get_tree().process_frame

	GameState.reset_for_new_game()
	TimeSystem.current_day = 3
	TimeSystem.minute_of_day = 17 * 60
	var field_path := (load("res://scenes/locations/FieldPath.tscn") as PackedScene).instantiate()
	add_child(field_path)
	await get_tree().process_frame
	var hermit_hotspot := field_path.get_node("RoadMysteriousHermitHotspot") as Button
	if hermit_hotspot == null or not hermit_hotspot.visible:
		_fail("Hermit mask was unavailable during its configured appearance time")
		return
	# Simulate the old edge case: death signal arrives while departure has been deferred.
	field_path.set("_road_hermit_departure_deferred", true)
	NpcRegistry.kill_npc("mysterious_hermit", "smoke")
	await get_tree().process_frame
	if hermit_hotspot.visible:
		_fail("Hermit mask remained visible after death during deferred departure")
		return
	var field_background := (field_path.get_node("BackgroundTexture") as TextureRect).texture
	if field_background == null or field_background.resource_path != "res://assets/scenes/field_path.png":
		_fail("Field path retained the hermit background after death")
		return
	field_path.queue_free()
	await get_tree().process_frame

	GameState.reset_for_new_game()
	var temple := (load("res://scenes/locations/TaoistTemple.tscn") as PackedScene).instantiate()
	add_child(temple)
	await get_tree().process_frame
	NpcRegistry.kill_npc("li_leshui_day", "smoke")
	await get_tree().process_frame
	if not NpcRegistry.is_npc_killed("li_leshui_day") or not NpcRegistry.is_npc_killed("li_leshui_night"):
		_fail("Taoist day/night personalities did not share death state")
		return
	var temple_background := temple.get_node("BackgroundTexture") as TextureRect
	if temple_background.texture.resource_path != "res://assets/scenes/taoist_temple_empty.png":
		_fail("Daytime Taoist temple did not switch to its empty scene after death")
		return
	var front_nodes: Array = temple.get("_taoist_front_nodes")
	if not front_nodes.is_empty() and (front_nodes[0] as Button).visible:
		_fail("Daytime Taoist mask remained visible after shared death")
		return
	TimeSystem.minute_of_day = 19 * 60
	temple.set("_taoist_in_rear_room", false)
	temple.call("_refresh_taoist_temple_state")
	if temple_background.texture.resource_path != "res://assets/scenes/taoist_temple_empty.png":
		_fail("Night temple front did not remain empty after shared death")
		return
	temple.call("_open_taoist_inner_door")
	if not bool(temple.get("_taoist_in_rear_room")) or int(temple.get("_taoist_door_judge_request_id")) != 0:
		_fail("Dead Taoist still caused the night rear-door trust check")
		return
	if temple_background.texture.resource_path != "res://assets/scenes/taoist_temple_rear_empty.png":
		_fail("Night rear room did not switch to its empty scene after shared death")
		return
	var rear_nodes: Array = temple.get("_taoist_rear_nodes")
	if not rear_nodes.is_empty() and (rear_nodes[0] as Button).visible:
		_fail("Night Taoist mask remained visible after shared death")
		return
	temple.queue_free()
	await get_tree().process_frame

	GameState.reset_for_new_game()
	GameState.set_investigation_state("altar_resolution", "sealed")
	TimeSystem.current_day = 9
	EndingController.evaluate_endings()
	var scene_tree := get_tree()
	if GameState.get_ending_id() != "suppression" or EndingController.get_node_or_null("EndingOverlay") == null or not scene_tree.paused:
		_fail("A sealed altar did not trigger the suppression ending on day nine")
		return
	scene_tree.paused = false
	GameState.reset_for_new_game()
	GameState.set_investigation_state("altar_resolution", "destroyed")
	TimeSystem.current_day = 9
	EndingController.evaluate_endings()
	if GameState.get_ending_id() != "sacrifice":
		_fail("A destroyed altar incorrectly triggered the suppression ending")
		return
	EndingController.call("_return_to_title_screen")
	if EndingController.get_node_or_null("EndingOverlay") != null or scene_tree.paused:
		_fail("Returning to the title screen did not remove the ending overlay")
		return

	# Regression: restoring a save does not emit TimeSystem.day_changed. The load-completed
	# hook must still settle an overdue day-nine ending without requiring another midnight.
	GameState.reset_for_new_game()
	GameState.set_investigation_state("altar_resolution", "destroyed")
	TimeSystem.current_day = 30
	var overdue_ending_save := "user://followup_overdue_ending_smoke.json"
	if GameState.save_game(overdue_ending_save, false) != OK:
		_fail("Could not create the overdue-ending load regression save")
		return
	GameState.reset_for_new_game()
	if GameState.load_game(overdue_ending_save, false) != OK:
		_fail("Could not restore the overdue-ending load regression save")
		return
	if GameState.get_ending_id() != "sacrifice" or EndingController.get_node_or_null("EndingOverlay") == null or not scene_tree.paused:
		_fail("Loading a day-thirty destroyed-altar save did not settle its overdue ending")
		return
	scene_tree.paused = false
	EndingController.reset_for_new_game()
	GameState.clear_save(overdue_ending_save)

	print("FOLLOWUP_LOGIC_SMOKE_OK")
	scene_tree.quit(0)


func _has_skill(skills: Array[Dictionary], skill_id: String) -> bool:
	for skill in skills:
		if String(skill.get("id", "")) == skill_id:
			return true
	return false


func _interaction_button_texts(ui: Node) -> Array[String]:
	var texts: Array[String] = []
	for node in ui.find_children("*", "Button", true, false):
		texts.append(String((node as Button).text))
	return texts


func _has_button_containing(texts: Array[String], needle: String) -> bool:
	for value in texts:
		if value.contains(needle):
			return true
	return false


func _fail(message: String) -> void:
	get_tree().paused = false
	push_error("FOLLOWUP_LOGIC_SMOKE_FAILED: " + message)
	get_tree().quit(1)
