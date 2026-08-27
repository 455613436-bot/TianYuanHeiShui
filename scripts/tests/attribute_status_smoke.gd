extends Node
## Regression coverage for morning temporary bonuses, pollution copy, and HUD rules.

const FORBIDDEN_POLLUTION_PHRASES := [
	"子宫",
	"血肉贴合",
	"挣开衣服",
	"衣服崩开",
	"兴奋的眩晕",
]
const TEST_SAVE_PATH := "user://attribute_status_smoke_save.json"


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
	if not hud_label.tooltip_text.contains("初始属性每项 0–5") or not hud_label.tooltip_text.contains("永久成长可突破 5"):
		_fail("Attribute HUD did not explain initial and permanent-growth limits")
		return

	var completed_day := TimeSystem.current_day
	GameState.showered_days[str(completed_day)] = true
	GameState.water_contact_count = 1
	GameState.water_contact_days[str(completed_day)] = true
	var report: Dictionary = GameState.call("_apply_morning_status", completed_day)
	await get_tree().process_frame
	if GameState.get_attribute("agility") != 4:
		_fail("Pollution level one did not grant agility +1")
		return
	var report_text := "\n".join(report.get("pages", []))
	if not bool(report.get("show", false)) or not report_text.contains("新增临时加成：敏捷 +1（3 → 4）"):
		_fail("Morning report did not identify the first daily bonus as newly added: %s" % report_text)
		return
	if not hud_label.text.contains("敏捷 4"):
		_fail("Attribute HUD did not refresh after the pollution bonus")
		return

	var maintained_day := completed_day + 1
	GameState.showered_days[str(maintained_day)] = true
	GameState.water_contact_days[str(maintained_day)] = true
	var maintained_report: Dictionary = GameState.call("_apply_morning_status", maintained_day)
	var maintained_text := "\n".join(maintained_report.get("pages", []))
	if GameState.get_attribute("agility") != 4 or not maintained_text.contains("维持临时加成：敏捷 +1（4 → 4）"):
		_fail("Repeated daily bonus was not reported as maintained: %s" % maintained_text)
		return
	if maintained_text.contains("新增临时加成：敏捷 +1（4 → 4）"):
		_fail("Maintained daily bonus was incorrectly reported as a new permanent increase")
		return

	var expired_day := completed_day + 2
	GameState.showered_days[str(expired_day)] = true
	var expired_report: Dictionary = GameState.call("_apply_morning_status", expired_day)
	var expired_text := "\n".join(expired_report.get("pages", []))
	if GameState.get_attribute("agility") != 3 or not bool(expired_report.get("show", false)):
		_fail("Expired daily bonus silently remained active")
		return
	if not expired_text.contains("昨日临时加成失效：敏捷（4 → 3）"):
		_fail("Expired daily bonus did not explain the actual value change: %s" % expired_text)
		return

	GameState.reset_for_new_game()
	GameState.set_attributes({"strength": 3, "agility": 3, "intellect": 2, "charisma": 2})
	completed_day = TimeSystem.current_day
	GameState.showered_days[str(completed_day)] = true
	GameState.ritual_offering_days[str(completed_day)] = true
	GameState.water_contact_count = 1
	GameState.water_contact_days[str(completed_day)] = true
	var stacked_report: Dictionary = GameState.call("_apply_morning_status", completed_day)
	var stacked_text := "\n".join(stacked_report.get("pages", []))
	if not stacked_text.contains("祭台上的供品") or not stacked_text.contains("并不存在的童年"):
		_fail("Offering and water-contact narratives did not survive the same morning report: %s" % stacked_text)
		return
	var agility_change := _find_attribute_change(stacked_report, "agility")
	if int(agility_change.get("current_bonus", 0)) != 2 or int(agility_change.get("before", 0)) != 3 or int(agility_change.get("after", 0)) != 5:
		_fail("Stacked offering and water bonuses were not represented as agility +2: %s" % str(agility_change))
		return
	if GameState.save_game(TEST_SAVE_PATH, false) != OK:
		_fail("Could not save the morning temporary-bonus state")
		return
	GameState.daily_attribute_bonuses = {}
	if GameState.load_game(TEST_SAVE_PATH, false) != OK:
		_fail("Could not reload the morning temporary-bonus state")
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))
	if int(GameState.daily_attribute_bonuses.get("agility", 0)) != 2 or GameState.get_attribute("agility") != 5:
		_fail("Save/load lost stacked daily bonuses")
		return

	GameState.reset_for_new_game()
	GameState.set_attributes({"strength": 3, "agility": 3, "intellect": 2, "charisma": 2})
	completed_day = TimeSystem.current_day
	GameState.water_contact_count = 4
	GameState.water_contact_days[str(completed_day)] = true
	var offset_report: Dictionary = GameState.call("_apply_morning_status", completed_day)
	var offset_text := "\n".join(offset_report.get("pages", []))
	if GameState.get_attribute("charisma") != 2:
		_fail("Expected daily charisma bonus and missed-shower penalty to cancel")
		return
	if not offset_text.contains("昨日未洗澡：魅力持续调整 -1") or not offset_text.contains("新增临时加成：魅力 +1（2 → 2）"):
		_fail("Offsetting cleanliness penalty and temporary bonus were not separately explained: %s" % offset_text)
		return

	for level in range(1, 6):
		var pollution_text := String(GameState.call("_water_contact_text", level))
		for forbidden in FORBIDDEN_POLLUTION_PHRASES:
			if pollution_text.contains(forbidden):
				_fail("Pollution level %d retained forbidden phrase: %s" % [level, forbidden])
				return
	if not String(GameState.call("_water_contact_text", 2)).contains("没有倒影的黑水"):
		_fail("Pollution level two did not use the approved mental-horror replacement")
		return

	GameState.grant_permanent_attribute("strength", 3)
	if int(GameState.attributes.get("strength", 0)) != 6:
		_fail("Permanent story growth was incorrectly capped at the initial limit of five")
		return

	GameState.reset_for_new_game()
	GameState.set_attributes({"strength": 3, "agility": 3, "intellect": 2, "charisma": 2})
	GameState.set_investigation_state("onboarding:temporary_dorm_tutorial", true)
	var dorm_scene := load("res://scenes/locations/TemporaryDorm.tscn") as PackedScene
	var dorm := dorm_scene.instantiate()
	get_tree().root.add_child(dorm)
	await get_tree().process_frame
	await get_tree().process_frame
	var shower_highlight := dorm.get_node("DormShowerHighlight") as MaskInteractionHighlight
	dorm.call("_open_dorm_shower", shower_highlight)
	await get_tree().process_frame
	var shower_ui := dorm.get_node("DormShowerInteraction") as SceneItemInteraction
	var shower_body := shower_ui.get("_body_label") as RichTextLabel
	if shower_body == null or not shower_body.text.contains("累计污染影响") or not shower_body.text.contains("次日清晨结算"):
		_fail("Shower confirmation did not warn about delayed pollution settlement")
		return
	shower_ui.close_interaction()
	shower_ui.queue_free()

	var rest_ui := dorm.get_node("DormRestConfirmation") as SceneItemInteraction
	var wake_ui := dorm.get_node("DormMorningReport") as SceneItemInteraction
	var bed_highlight := dorm.get_node("DormBedHighlight") as MaskInteractionHighlight
	dorm.call("_open_rest_confirmation", bed_highlight, rest_ui, wake_ui)
	await get_tree().process_frame
	var rest_body := rest_ui.get("_body_label") as RichTextLabel
	if rest_body == null or not rest_body.text.contains("结算清洁状态和每日临时增益"):
		_fail("Rest confirmation did not explain the morning settlement")
		return
	rest_ui.close_interaction()

	GameState.record_water_contact("status_smoke")
	dorm.call("_rest_in_temporary_dorm", rest_ui, wake_ui)
	await get_tree().process_frame
	var wake_overlay := wake_ui.get("_overlay") as Control
	var wake_body := wake_ui.get("_body_label") as RichTextLabel
	if wake_overlay == null or not wake_overlay.visible:
		_fail("Ordinary morning status report was not displayed")
		return
	if wake_body == null or not wake_body.text.contains("并不存在的童年"):
		_fail("Displayed morning report omitted the approved pollution narrative")
		return
	wake_ui.call("_advance_paged_text")
	if not wake_body.text.contains("新增临时加成") or not wake_body.text.contains("不会永久累计"):
		_fail("Displayed morning report omitted the explicit temporary-bonus explanation")
		return

	print("ATTRIBUTE_STATUS_SMOKE_OK")
	get_tree().quit(0)


func _find_attribute_change(report: Dictionary, key: String) -> Dictionary:
	for raw_change in report.get("attribute_changes", []):
		if raw_change is Dictionary and String(raw_change.get("key", "")) == key:
			return raw_change
	return {}


func _fail(message: String) -> void:
	push_error("ATTRIBUTE_STATUS_SMOKE_FAILED: " + message)
	get_tree().quit(1)
