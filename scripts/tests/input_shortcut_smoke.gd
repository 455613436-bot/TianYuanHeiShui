extends Node
## Regression coverage for global Esc/M/I/J routing and dialogue-to-map navigation.

const MAIN_SCENE := preload("res://scenes/main/Main.tscn")
const SCENE_INTERACTION_SCRIPT := preload("res://scripts/ui/SceneItemInteraction.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()
	var expected_actions := {
		"cancel_or_back": KEY_ESCAPE,
		"open_map": KEY_M,
		"open_inventory": KEY_I,
		"open_journal": KEY_J,
	}
	for action_name: String in expected_actions:
		if not InputMap.has_action(action_name):
			_fail("Missing input action: %s" % action_name)
			return
		if not _action_has_key(action_name, int(expected_actions[action_name])):
			_fail("Input action %s is not bound to its expected key" % action_name)
			return

	var main := MAIN_SCENE.instantiate()
	get_tree().root.add_child(main)
	get_tree().current_scene = main
	await get_tree().process_frame
	await get_tree().process_frame
	if not bool(InputManager.call("_is_gameplay_scene")):
		_fail("Village square was not recognized as gameplay")
		return

	var dialogue := main.get_node("DialogueUI")
	var bag := main.get_node("ItemBagPopup")
	if dialogue == null or bag == null:
		_fail("Village square is missing persistent dialogue or bag UI")
		return
	var map_button := main.get_node("HUD/ReturnMapButton") as BaseButton
	if String(map_button.tooltip_text).contains("Esc"):
		_fail("Map tooltip still advertises Esc")
		return

	InputManager.request_open_inventory()
	if not bag.is_ui_open() or String(bag.get("_selection_mode")) != "browse":
		_fail("I did not open the idle inventory in browse mode")
		return
	InputManager.request_open_inventory()
	if bag.is_ui_open():
		_fail("I did not toggle the inventory closed")
		return

	InputManager.request_open_journal()
	var journal: Variant = dialogue.get("_clue_book_popup")
	if not is_instance_valid(journal) or not journal.is_ui_open() or bool(journal.get("_allow_present")):
		_fail("J did not open the idle clue book in browse-only mode")
		return
	InputManager.request_open_journal()
	if journal.is_ui_open():
		_fail("J did not toggle the clue book closed")
		return

	_open_test_dialogue(dialogue)
	InputManager.request_open_inventory()
	if not bag.is_ui_open() or String(bag.get("_selection_mode")) != "dialogue":
		_fail("I did not preserve dialogue item-selection mode")
		return
	bag.call("_on_inspect_pressed", "camera")
	var inspect_popup: Variant = bag.get("_inspect_popup")
	if not is_instance_valid(inspect_popup) or not inspect_popup.is_ui_open():
		_fail("Inventory inspect popup did not open")
		return
	InputManager.call("_handle_cancel")
	if inspect_popup.is_ui_open() or not bag.is_ui_open() or not dialogue.is_open():
		_fail("First Esc did not close only the item inspection")
		return
	InputManager.call("_handle_cancel")
	if bag.is_ui_open() or not dialogue.is_open():
		_fail("Second Esc did not close only the inventory")
		return
	InputManager.call("_handle_cancel")
	if dialogue.is_open():
		_fail("Third Esc did not close the dialogue")
		return

	InputManager.call("_handle_cancel")
	var settings := _first_group_node("settings_menu")
	if settings == null or not settings.is_ui_open():
		_fail("Esc did not open settings when no other page was open")
		return
	settings.call("_configure_display_options_for_platform", true)
	var settings_options := settings.get_node("Dimmer/Panel/VBox/Tabs/Display/Options") as GridContainer
	var resolution_option := settings.get_node("Dimmer/Panel/VBox/Tabs/Display/Options/ResolutionOption") as OptionButton
	var mode_option := settings.get_node("Dimmer/Panel/VBox/Tabs/Display/Options/ModeOption") as OptionButton
	var apply_button := settings.get_node("Dimmer/Panel/VBox/Tabs/Display/ApplyButton") as Button
	if not settings_options.visible or not apply_button.visible:
		_fail("Web settings hid all display controls")
		return
	if resolution_option.item_count != 4 or resolution_option.disabled:
		_fail("Web settings did not expose selectable display sizes")
		return
	if resolution_option.get_item_text(0) != "自动（最高 1920 × 1080）" or resolution_option.get_item_text(3) != "1920 × 1080":
		_fail("Web settings display-size labels are incorrect")
		return
	if mode_option.item_count != 2 or mode_option.get_item_text(1) != "浏览器全屏":
		_fail("Web settings did not expose window/fullscreen choices")
		return
	InputManager.call("_handle_cancel")
	if settings.is_ui_open():
		_fail("Esc did not close settings")
		return

	_open_test_dialogue(dialogue)
	InputManager.request_open_journal()
	journal = dialogue.get("_clue_book_popup")
	if not journal.is_ui_open() or not bool(journal.get("_allow_present")):
		_fail("J did not preserve clue presentation during dialogue")
		return
	InputManager.request_open_journal()

	var input_edit := dialogue.get_node("RootPanel/HBox/Center/InputRow/InputEdit") as LineEdit
	input_edit.grab_focus()
	await get_tree().process_frame
	if not bool(InputManager.call("_is_text_entry_focused")):
		_fail("Dialogue input focus was not detected")
		return
	var inventory_key := InputEventKey.new()
	inventory_key.pressed = true
	inventory_key.keycode = KEY_I
	inventory_key.physical_keycode = KEY_I
	InputManager.call("_unhandled_input", inventory_key)
	if bag.is_ui_open():
		_fail("I was intercepted while the dialogue text field had focus")
		return
	input_edit.release_focus()

	InputManager.request_open_map()
	if not dialogue.is_open():
		_fail("A locked map request closed the active dialogue")
		return
	GameState.add_item(GameState.VILLAGE_MAP_ITEM_ID)
	input_edit.grab_focus()
	await get_tree().process_frame
	var map_key := InputEventKey.new()
	map_key.pressed = true
	map_key.keycode = KEY_M
	map_key.physical_keycode = KEY_M
	InputManager.call("_unhandled_input", map_key)
	if get_tree().current_scene != main or not dialogue.is_open():
		_fail("M interrupted dialogue text entry")
		return
	input_edit.release_focus()

	var forced_modal := SCENE_INTERACTION_SCRIPT.new()
	main.add_child(forced_modal)
	forced_modal.open_paged_text("必须确认", ["不可跳过。"], "shortcut_smoke", {}, true, "确认")
	InputManager.call("_handle_cancel")
	if not forced_modal.is_ui_open():
		_fail("Esc closed a mandatory interaction")
		return
	if bool(InputManager.call("_close_optional_overlays_for_navigation")):
		_fail("Mandatory interaction allowed map navigation")
		return
	forced_modal.call("_advance_paged_text")
	if forced_modal.is_ui_open():
		_fail("Mandatory interaction did not close after acknowledgement")
		return

	InputManager.request_open_inventory()
	if not bag.is_ui_open():
		_fail("Dialogue inventory did not reopen before map navigation")
		return
	map_button.pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	var current := get_tree().current_scene
	if current == null or String(current.scene_file_path) != GameState.MAP_SCENE:
		_fail("Map request did not leave dialogue and enter WorldMap")
		return
	if is_instance_valid(dialogue) or is_instance_valid(bag):
		_fail("Dialogue overlays survived the scene transition")
		return

	InputManager.request_open_map()
	await get_tree().process_frame
	await get_tree().process_frame
	current = get_tree().current_scene
	if current == null or String(current.scene_file_path) != "res://scenes/main/Main.tscn":
		_fail("M did not toggle WorldMap back to the source scene")
		return

	print("INPUT_SHORTCUT_SMOKE_OK")
	get_tree().quit(0)


func _open_test_dialogue(dialogue: Node) -> void:
	dialogue.set("current_npc", NpcRegistry.get_dialogue_profile("wu_zhiyuan"))
	dialogue.call("_change_state", 2)


func _first_group_node(group_name: String) -> Node:
	for node in get_tree().get_nodes_in_group(group_name):
		return node
	return null


func _action_has_key(action_name: String, expected_keycode: int) -> bool:
	for event in InputMap.action_get_events(action_name):
		if event is InputEventKey and ((event as InputEventKey).keycode == expected_keycode or (event as InputEventKey).physical_keycode == expected_keycode):
			return true
	return false


func _fail(message: String) -> void:
	push_error("INPUT_SHORTCUT_SMOKE_FAILED: " + message)
	get_tree().quit(1)
