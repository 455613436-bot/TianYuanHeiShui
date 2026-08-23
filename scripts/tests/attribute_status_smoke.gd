extends Node
## Regression coverage for pollution level-one bonuses, morning report, and HUD.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	if not GameState.set_attributes({
		"strength": 3,
		"agility": 3,
		"intellect": 2,
		"charisma": 2,
	}):
		_fail("Could not seed player attributes")
		return
	var hud_scene := load("res://scenes/ui/AttributeStatusHud.tscn") as PackedScene
	var hud := hud_scene.instantiate()
	add_child(hud)
	await get_tree().process_frame
	var hud_label := hud.get_node("Panel/AttributeLabel") as Label
	if hud_label.text != "力量 3　敏捷 3　智力 2　魅力 2":
		_fail("Attribute HUD did not show the current four attributes: %s" % hud_label.text)
		return
	GameState.grant_permanent_attribute("strength", 1)
	await get_tree().process_frame
	if not GameState.attributes_allocated() or not hud.visible or not hud_label.text.contains("力量 4"):
		_fail("Permanent attribute growth hid or failed to refresh the always-visible HUD")
		return

	var completed_day := TimeSystem.current_day
	GameState.water_contact_count = 1
	GameState.water_contact_days[str(completed_day)] = true
	var report: Dictionary = GameState.call("_apply_morning_status", completed_day)
	await get_tree().process_frame
	if GameState.get_attribute("agility") != 4:
		_fail("Pollution level one did not grant agility +1")
		return
	var report_text := "\n".join(report.get("pages", []))
	if not bool(report.get("show", false)) or not report_text.contains("敏捷 +1"):
		_fail("Morning report did not explain the level-one attribute bonus")
		return
	if not hud_label.text.contains("敏捷 4"):
		_fail("Attribute HUD did not refresh after the pollution bonus")
		return

	GameState.reset_for_new_game()
	GameState.set_attributes({"strength": 3, "agility": 3, "intellect": 2, "charisma": 2})
	GameState.set_investigation_state("onboarding:temporary_dorm_tutorial", true)
	GameState.record_water_contact("status_smoke")
	var dorm_scene := load("res://scenes/locations/TemporaryDorm.tscn") as PackedScene
	var dorm := dorm_scene.instantiate()
	get_tree().root.add_child(dorm)
	await get_tree().process_frame
	await get_tree().process_frame
	var rest_ui := dorm.get_node("DormRestConfirmation") as SceneItemInteraction
	var wake_ui := dorm.get_node("DormMorningReport") as SceneItemInteraction
	dorm.call("_rest_in_temporary_dorm", rest_ui, wake_ui)
	await get_tree().process_frame
	var wake_overlay := wake_ui.get("_overlay") as Control
	var wake_body := wake_ui.get("_body_label") as RichTextLabel
	if wake_overlay == null or not wake_overlay.visible:
		_fail("Ordinary morning status report was not displayed")
		return
	if wake_body == null or not wake_body.text.contains("今日增益"):
		_fail("Displayed morning report omitted the attribute bonus explanation")
		return

	print("ATTRIBUTE_STATUS_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("ATTRIBUTE_STATUS_SMOKE_FAILED: " + message)
	get_tree().quit(1)
