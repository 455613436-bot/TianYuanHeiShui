extends Node
## Regression coverage for metadata, availability and the five-slot settings UI.

const TEST_SAVE_PATH := "user://manual_save_smoke.json"
const EXPLORATION_SCENE := "res://scenes/locations/VillageChiefHouse.tscn"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	if GameState.get_manual_save_availability().get("allowed", false):
		_fail("Saving was allowed before attribute allocation")
		return
	if not GameState.set_attributes({"strength": 3, "agility": 3, "intellect": 2, "charisma": 2}, true):
		_fail("Could not prepare valid player attributes")
		return
	GameState.current_scene_path = EXPLORATION_SCENE
	TimeSystem.current_day = 4
	TimeSystem.minute_of_day = 13 * 60 + 25
	if not GameState.get_manual_save_availability().get("allowed", false):
		_fail("Saving was not allowed in an exploration scene")
		return
	if GameState.save_game(TEST_SAVE_PATH, false) != OK:
		_fail("Temporary manual save could not be written")
		return
	var metadata := GameState.get_save_metadata(TEST_SAVE_PATH)
	if not bool(metadata.get("valid", false)) or String(metadata.get("save_kind", "")) != "manual":
		_fail("Manual save metadata is invalid")
		return
	if int(metadata.get("day", 0)) != 4 or int(metadata.get("minute_of_day", 0)) != 805:
		_fail("Manual save metadata lost game time")
		return
	if String(metadata.get("location_name", "")).is_empty():
		_fail("Manual save metadata lost location name")
		return
	for slot in range(1, GameState.MANUAL_SAVE_SLOT_COUNT + 1):
		if GameState.get_manual_save_path(slot) != "user://save_%02d.json" % slot:
			_fail("Manual save slot path is inconsistent")
			return
	var settings := get_node_or_null("/root/SettingsMenu")
	if settings == null:
		_fail("SettingsMenu autoload is missing")
		return
	var save_list := settings.get_node("Dimmer/Panel/VBox/Tabs/SaveManagement/Scroll/List")
	if save_list.get_child_count() != GameState.MANUAL_SAVE_SLOT_COUNT:
		_fail("Settings menu did not build five save rows")
		return
	var tabs := settings.get_node("Dimmer/Panel/VBox/Tabs") as TabContainer
	if tabs == null or tabs.get_tab_count() != 3 or tabs.get_tab_title(1) != "声音设置" or tabs.get_tab_title(2) != "存档管理":
		_fail("Settings menu did not expose the audio settings tab")
		return
	for control_path in [
		"Dimmer/Panel/VBox/Tabs/AudioSettings/AudioOptions/MasterVolumeSlider",
		"Dimmer/Panel/VBox/Tabs/AudioSettings/AudioOptions/BgmVolumeSlider",
		"Dimmer/Panel/VBox/Tabs/AudioSettings/AudioOptions/SfxVolumeSlider",
		"Dimmer/Panel/VBox/Tabs/AudioSettings/MuteCheck",
	]:
		if settings.get_node_or_null(control_path) == null:
			_fail("Settings menu is missing audio control: %s" % control_path)
			return
	GameState.clear_save(TEST_SAVE_PATH)
	print("MANUAL_SAVE_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	GameState.clear_save(TEST_SAVE_PATH)
	push_error("MANUAL_SAVE_SMOKE_FAILED: " + message)
	get_tree().quit(1)
