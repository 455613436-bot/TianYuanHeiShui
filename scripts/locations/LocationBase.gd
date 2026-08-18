extends Control
## 地图地点的共享占位场景。后续可用真正的探索场景替换各地点文件。

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"
const ITEM_BAG_POPUP_SCENE := preload("res://scenes/ui/ItemBagPopup.tscn")
const PHOTO_MATCHING_INTERACTION_SCRIPT := preload("res://scripts/ui/PhotoMatchingInteraction.gd")

const PHOTO_MATCH_ATTEMPT_STATE := "item_check:wu_xuan_photo_location_match"
const PHOTO_MATCH_OPTIONS := [
	{"id": "taoist_temple", "label": "道观"},
	{"id": "carpenter_workshop", "label": "木匠工坊"},
	{"id": "construction_site", "label": "旧工地"},
	{"id": "lakeside_dock", "label": "湖边码头"},
	{"id": "village_chief_house", "label": "村长家"},
]
const PHOTO_MATCH_SNIPPETS := [
	{
		"label": "局部 A",
		"image_path": "res://assets/scenes/village_chief_house.png",
		"region": Rect2(330, 685, 240, 220),
		"answer_id": "village_chief_house",
	},
	{
		"label": "局部 B",
		"image_path": "res://assets/scenes/lakeside_dock.png",
		"region": Rect2(60, 255, 260, 220),
		"answer_id": "lakeside_dock",
	},
	{
		"label": "局部 C",
		"image_path": "res://assets/scenes/carpenter_workshop.png",
		"region": Rect2(1270, 560, 260, 210),
		"answer_id": "carpenter_workshop",
	},
	{
		"label": "局部 D",
		"image_path": "res://assets/scenes/taoist_temple_front.png",
		"region": Rect2(1120, 745, 260, 215),
		"answer_id": "taoist_temple",
	},
	{
		"label": "局部 E",
		"image_path": "res://assets/scenes/bg_construction_site.png",
		"region": Rect2(1320, 650, 290, 220),
		"answer_id": "construction_site",
	},
]

@export var location_number: String = "?"
@export var location_name: String = "未命名地点"
## 该地点在 locations.json 里的 id；留空则由 NpcSpawner 按 scene path 反查
@export var location_id: String = ""
@export_multiline var location_description: String = "该地点仍在建设中。"
@export var background_texture: Texture2D
## 某些地点完成永久交互后使用的替代背景，例如废弃医院开锁后的场景。
@export var unlocked_background_texture: Texture2D
## 按日程出现人物时使用的背景，例如田间小路傍晚出现神秘人的版本。
@export var scheduled_background_texture: Texture2D
## 某些正式背景把 NPC 直接画进图里；场景无人时切换到对应的空景版本。
@export var empty_background_texture: Texture2D
## 同一地点的第二个视角；设置后会自动生成场景切换按键。
@export var alternate_background_texture: Texture2D
## 第二视角在无人状态时使用的空景；例如道观后室。
@export var alternate_empty_background_texture: Texture2D
@export var alternate_view_label: String = "切换至后方"
@export var accent_color: Color = Color(0.45, 0.58, 0.36)

var _showing_alternate_view := false
var _view_toggle_button: Button
var _uses_time_based_background := false
var _uses_road_hermit_schedule := false
var _road_hermit_departure_deferred := false
var _road_hermit_nodes: Dictionary = {}
## 地图按钮放入独立 HUD 层，避免被场景遮罩热点截获点击。
var _map_action_layer: CanvasLayer
var _scene_npc_hotspots: Dictionary = {}

@onready var content_panel: Panel = $Content
@onready var number_label: Label = $Content/NumberLabel
@onready var title_label: Label = $Content/TitleLabel
@onready var description_label: Label = $Content/DescriptionLabel
@onready var status_label: Label = $Content/StatusLabel if has_node("Content/StatusLabel") else null
@onready var return_button: Button = $ReturnMapButton
@onready var accent: ColorRect = $Accent
@onready var background: TextureRect = $BackgroundTexture
@onready var npc_spawner: Node2D = $NpcSpawner if has_node("NpcSpawner") else null
@onready var presence_bar: CanvasLayer = $NpcPresenceBar if has_node("NpcPresenceBar") else null


func _ready() -> void:
	resized.connect(_apply_responsive_layout)
	GameState.restore_current_scene()
	background.texture = background_texture
	background.visible = background_texture != null
	background.modulate = Color.WHITE
	number_label.text = location_number
	title_label.text = location_name
	description_label.text = location_description
	accent.color = accent_color
	# 有背景图时隐藏占位 Content 面板（场景已接入真背景，不再显示"待开发"）
	content_panel.visible = background_texture == null and alternate_background_texture == null
	_uses_time_based_background = location_id == "temporary_dorm" and background_texture != null and alternate_background_texture != null
	_uses_road_hermit_schedule = location_id == "field_path" and scheduled_background_texture != null
	if _uses_time_based_background:
		TimeSystem.minute_changed.connect(_on_time_changed)
		_refresh_time_based_background()
	elif alternate_background_texture != null:
		_create_view_toggle_button()
	if _uses_road_hermit_schedule:
		TimeSystem.minute_changed.connect(_on_time_changed)
	_move_map_button_to_hud_layer()
	return_button.pressed.connect(_open_map)
	GameState.item_added.connect(_on_item_added)
	_refresh_map_access()
	return_button.grab_focus()
	# 把 location_id 传给 spawner（若已指定）
	if npc_spawner != null and location_id != "":
		npc_spawner.location_id = location_id
	if presence_bar != null:
		presence_bar.location_id = location_id
		# M4：点击 NPC 头像 → 切换私聊
		if presence_bar.has_signal("npc_selected"):
			presence_bar.npc_selected.connect(_on_presence_npc_selected)
		# M6：召集公聊
		if presence_bar.has_signal("group_chat_requested"):
			presence_bar.group_chat_requested.connect(_on_group_chat_requested)
	if location_id == "abandoned_clinic":
		_setup_clinic_state()
	elif location_id == "field_path":
		_refresh_road_hermit_schedule()
	elif location_id == "village_chief_house":
		_create_village_chief_house_hotspots()
	elif location_id == "village_committee":
		_create_village_committee_hotspots()
	elif location_id == "temporary_dorm":
		_create_temporary_dorm_hotspots()
		call_deferred("_start_dorm_tutorial_if_needed")
	if not NpcRegistry.npc_moved.is_connected(_on_scene_npc_presence_changed):
		NpcRegistry.npc_moved.connect(_on_scene_npc_presence_changed)
	_refresh_scene_presence()
	call_deferred("_apply_responsive_layout")


func _move_map_button_to_hud_layer() -> void:
	if _map_action_layer != null:
		return
	_map_action_layer = CanvasLayer.new()
	_map_action_layer.name = "MapActionHudLayer"
	# 高于场景与遮罩热点，低于资料/对话等全屏交互层。
	_map_action_layer.layer = 10
	add_child(_map_action_layer)
	return_button.reparent(_map_action_layer)


func _on_item_added(item_id: String) -> void:
	if item_id == GameState.VILLAGE_MAP_ITEM_ID:
		_refresh_map_access()


func _refresh_map_access() -> void:
	var unlocked := GameState.can_open_world_map()
	return_button.disabled = not unlocked
	return_button.tooltip_text = "打开地图" if unlocked else "先向村长询问并取得村庄手绘地图"
	return_button.text = "打开地图  M / Esc" if unlocked else "地图尚未解锁"


func _setup_clinic_state() -> void:
	if bool(GameState.get_investigation_state("abandoned_clinic_door_unlocked", false)):
		_activate_clinic_open_state()
	else:
		_create_clinic_door_hotspot()


func _create_clinic_door_hotspot() -> void:
	var mask := MaskInteractionHighlight.new()
	mask.name = "ClinicDoorHighlight"
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.configure(
		load("res://assets/scenes/masks/abandoned_clinic_door_mask.png"),
		Color(0.28, 0.86, 1.0, 1.0),
		0.24,
		3.0
	)
	add_child(mask)

	var hotspot := Button.new()
	hotspot.name = "ClinicDoorHotspot"
	hotspot.anchor_left = 0.39
	hotspot.anchor_top = 0.39
	hotspot.anchor_right = 0.53
	hotspot.anchor_bottom = 0.76
	hotspot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hotspot.tooltip_text = "诊所大门"
	hotspot.flat = true
	hotspot.mouse_entered.connect(func() -> void:
		mask.show_highlight()
	)
	hotspot.mouse_exited.connect(func() -> void:
		mask.hide_highlight()
	)
	add_child(hotspot)

	var interaction_ui := SceneItemInteraction.new()
	interaction_ui.name = "ClinicDoorInteraction"
	add_child(interaction_ui)
	interaction_ui.choice_selected.connect(func(interaction_id: String, choice_id: String, result: Dictionary) -> void:
		if interaction_id != "abandoned_clinic_door_lock":
			return
		var unlocked: bool = choice_id == "use_clinic_key" or (choice_id == "pry_lock" and bool(result.get("passed", false)))
		if not unlocked:
			return
		GameState.set_investigation_state("abandoned_clinic_door_unlocked", true)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		_activate_clinic_open_state()
		mask.queue_free()
		hotspot.queue_free()
		var unlock_text: String = "钥匙顺利转动，诊所大门的旧锁被打开了。" if choice_id == "use_clinic_key" else "锁芯终于松开，诊所大门可以自由出入了。"
		interaction_ui.open_paged_text("诊所大门", [unlock_text])
	)
	hotspot.pressed.connect(func() -> void:
		mask.hide_highlight()
		var door_unlocked: bool = bool(GameState.get_investigation_state("abandoned_clinic_door_unlocked", false))
		var door_choices: Array[Dictionary] = []
		if door_unlocked:
			door_choices.append({"id": "leave", "label": "门锁已经打开", "close": true})
		else:
			if GameState.has_item("abandoned_clinic_key"):
				door_choices.append({
					"id": "use_clinic_key",
					"label": "使用神秘人给的医院钥匙",
				})
			door_choices.append({
				"id": "pry_lock",
				"label": "撬锁（敏捷检定）",
				"type": "check",
				"attribute": "敏捷",
				"difficulty": CheckSystem.RAW_DIFFICULTY_MAX,
				"reason": "尝试撬开废弃诊所大门的锁",
				"success_text": "锁芯发出一声轻响，门闩松开了。",
				"failure_text": "铁片从锁眼滑开，锈蚀的锁仍纹丝不动。",
			})
			door_choices.append({"id": "leave", "label": "离开", "close": true})
		interaction_ui.open_choice({
			"id": "abandoned_clinic_door_lock",
			"title": "诊所大门",
			"description": "门锁已经打开，可以自由出入。" if door_unlocked else "这是一个摇摇欲坠的锁。锈蚀的锁芯仍勉强卡住门闩。",
			"choices": door_choices,
		})
	)


func _activate_clinic_open_state() -> void:
	if unlocked_background_texture != null:
		background.texture = unlocked_background_texture
		background.visible = true
	if has_node("ClinicFileHotspot"):
		return

	var files := _create_mask_hotspot(
		"ClinicFile",
		"res://assets/scenes/masks/clinic_file_mask.png",
		Rect2(0.375, 0.545, 0.085, 0.090),
		"查看桌上的医院档案"
	)
	var equipment := _create_mask_hotspot(
		"ClinicEquipment",
		"res://assets/scenes/masks/clinic_equipment_mask.png",
		Rect2(0.435, 0.530, 0.095, 0.100),
		"检查遗留的医学检验设备"
	)
	var file_ui := SceneItemInteraction.new()
	file_ui.name = "ClinicFileInteraction"
	add_child(file_ui)
	var equipment_ui := SceneItemInteraction.new()
	equipment_ui.name = "ClinicEquipmentInteraction"
	add_child(equipment_ui)
	(files["button"] as Button).pressed.connect(_open_clinic_files.bind(files["highlight"], file_ui))
	(equipment["button"] as Button).pressed.connect(_learn_medical_exam.bind(equipment["highlight"], equipment_ui))


func _open_clinic_files(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	var pages: Array[String] = [
		"【日记残章】老甘催我敲定这里的项目，可是迟迟难有进展。这里的村民似乎误会了我，旧友木匠也斥责我，说我们的工厂毁坏了这里的花草树木。可我无意破坏这里的生态环境，这里的水流恶臭也并非是工业园区带来的，为什么他们不信任我，为什么……",
		"【一张乡村医院记录】患者口吐黑血，身体浮肿严重，当前医疗资源无法进行进一步检查。已尝试联系患者丈夫，未打通电话，会持续尝试联络其亲属。",
	]
	ui.open_paged_text("废弃医院档案", pages, "clinic_files", {
		"id": "abandoned_clinic_medical_records",
		"title": "废弃医院档案",
		"summary": "日记否认工业园区造成水流恶臭；另一份乡村医院记录记载患者口吐黑血、身体严重浮肿，院方未能联系上其丈夫。",
		"pages": pages,
	})


func _learn_medical_exam(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	if SkillSystem.is_medical_exam_unlocked():
		ui.open_paged_text("医学检验设备", ["你已经掌握了这套设备的使用方法，可以从右下角的技能列表中使用“医学检验”。"])
		return
	GameState.set_investigation_state("skill_unlocked_medical_exam", true)
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	SceneItemInteraction.show_content_added_toast("医学检验", "技能列表")
	ui.open_paged_text("学会技能：医学检验", ["你整理了诊所遗留的检验器械与试剂，掌握了基础医学检验方法。现在可以对宿舍洗澡水或场景中的人物使用“医学检验”。"])


func _create_village_committee_hotspots() -> void:
	var xuan := _create_mask_hotspot(
		"WuXuan",
		"res://assets/scenes/masks/wu_xuan_mask.png",
		Rect2(0.247, 0.168, 0.254, 0.829),
		"与吴萱交谈"
	)
	var photos := _create_mask_hotspot(
		"CommitteePhotos",
		"res://assets/scenes/masks/committee_photos_mask.png",
		Rect2(0.825, 0.064, 0.175, 0.337),
		"旧照片与地点记录"
	)
	var computer := _create_mask_hotspot(
		"CommitteeComputer",
		"res://assets/scenes/masks/committee_computer_mask.png",
		Rect2(0.575, 0.384, 0.133, 0.247),
		"村委电脑"
	)
	var notice := _create_mask_hotspot(
		"HospitalNotice",
		"res://assets/scenes/masks/hospital_notice_mask.png",
		Rect2(0.279, 0.131, 0.156, 0.054),
		"田原村全体村民联名请愿书"
	)

	var photo_ui: PhotoMatchingInteraction = PHOTO_MATCHING_INTERACTION_SCRIPT.new()
	photo_ui.name = "CommitteePhotoMatchInteraction"
	add_child(photo_ui)
	photo_ui.submitted.connect(_on_committee_photo_matching_submitted.bind(photo_ui))
	var computer_ui := SceneItemInteraction.new()
	computer_ui.name = "CommitteeComputerInteraction"
	add_child(computer_ui)
	computer_ui.choice_selected.connect(_on_committee_computer_choice.bind(computer_ui))
	var notice_ui := SceneItemInteraction.new()
	notice_ui.name = "HospitalNoticeInteraction"
	add_child(notice_ui)

	(xuan["button"] as Button).pressed.connect(_open_wu_xuan_dialogue.bind(xuan["highlight"]))
	_scene_npc_hotspots["wu_xuan"] = xuan
	(photos["button"] as Button).pressed.connect(_open_committee_photo_match.bind(photos["highlight"], photo_ui))
	(computer["button"] as Button).pressed.connect(_open_committee_computer.bind(computer["highlight"], computer_ui))
	(notice["button"] as Button).pressed.connect(_open_hospital_notice.bind(notice["highlight"], notice_ui))


func _open_wu_xuan_dialogue(highlight: MaskInteractionHighlight) -> void:
	highlight.hide_highlight()
	if not NpcRegistry.is_npc_present_at("wu_xuan", location_id):
		_show_scene_message("无人回应", "吴萱已经不在村委会，这里现在没有人回应你。")
		return
	if not NpcRegistry.can_interact_with_npc("wu_xuan"):
		_show_scene_message("无人回应", "吴萱拒绝再与你交谈。")
		return
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or not dialogue_ui.has_method("open_dialogue"):
		return
	if dialogue_ui.has_method("is_open") and dialogue_ui.is_open():
		return
	var profile := NpcRegistry.get_dialogue_profile("wu_xuan")
	if not profile.is_empty():
		dialogue_ui.open_dialogue(profile)


func _open_committee_photo_match(highlight: MaskInteractionHighlight, interaction_ui: PhotoMatchingInteraction) -> void:
	highlight.hide_highlight()
	var stage := GameState.get_quest_stage("wu_xuan_photo_location_match")
	if stage >= 2:
		interaction_ui.open_notice("旧照片", "这些旧照片的拍摄地点已经整理完成。去和吴萱谈谈，她会知道下一步该怎么做。")
		return
	var last_attempt: Variant = GameState.get_investigation_state(PHOTO_MATCH_ATTEMPT_STATE, {})
	if last_attempt is Dictionary and int((last_attempt as Dictionary).get("day", 0)) == TimeSystem.current_day:
		interaction_ui.open_notice("旧照片", "你今天已经核对过这批照片了。先把结果整理一下，明天再来继续。")
		return
	if stage == 0:
		GameState.set_quest_stage("wu_xuan_photo_location_match", 1)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	interaction_ui.open_task(
		"wu_xuan_photo_location_match",
		"旧照片地点匹配",
		"照片缺少地点标注。观察每张局部图中的物件、材质和环境细节，从每行独立排列的下拉框选择它属于哪个场景；全部填对才算完成。今天只能提交一次。",
		PHOTO_MATCH_SNIPPETS,
		PHOTO_MATCH_OPTIONS,
		PHOTO_MATCH_ATTEMPT_STATE
	)


func _on_committee_photo_matching_submitted(result: Dictionary, interaction_ui: PhotoMatchingInteraction) -> void:
	if not bool(result.get("passed", false)):
		return
	GameState.set_quest_stage("wu_xuan_photo_location_match", 2)
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	SceneItemInteraction.show_content_added_toast("照片地点匹配完成", "调查进度")
	interaction_ui.set_result_note("你完成了照片地点的核对。去告诉吴萱这件事，她也许会愿意开放更多村委电脑的使用范围。")


func _open_committee_computer(highlight: MaskInteractionHighlight, interaction_ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	var has_game_access := GameState.has_item("village_committee_computer_game_access")
	var has_archive_access := GameState.has_item("village_committee_archive_access")
	if not has_game_access and not has_archive_access:
		interaction_ui.open_choice({
			"id": "committee_computer_locked",
			"title": "村委电脑",
			"description": "屏幕亮着，但吴萱没有允许你使用。这里存着村委资料，不能擅自操作。",
			"choices": [{"id": "leave", "label": "离开", "close": true}],
		})
		return

	var choices: Array[Dictionary] = []
	var description := "吴萱为你开放了有限的电脑使用权限。"
	if has_game_access:
		var can_play := not bool(GameState.get_investigation_state("wu_xuan_computer_game_completed", false)) and TimeSystem.minute_of_day + 240 <= 19 * 60
		if can_play:
			choices.append({"id": "play_game", "label": "玩本地游戏（消耗 4 小时）"})
		elif bool(GameState.get_investigation_state("wu_xuan_computer_game_completed", false)):
			description += "你已经通过本地游戏获得过一次智力成长。"
		else:
			description += "距离 19:00 已不足四小时，现在不适合开始游戏。"
	if has_archive_access:
		choices.append({"id": "search_archives", "label": "查阅限定档案"})
	choices.append({"id": "leave", "label": "离开", "close": true})
	interaction_ui.open_choice({
		"id": "committee_computer",
		"title": "村委电脑",
		"description": description,
		"choices": choices,
	})


func _on_committee_computer_choice(interaction_id: String, choice_id: String, _result: Dictionary, interaction_ui: SceneItemInteraction) -> void:
	if interaction_id != "committee_computer":
		return
	if choice_id == "play_game":
		if bool(GameState.get_investigation_state("wu_xuan_computer_game_completed", false)) or TimeSystem.minute_of_day + 240 > 19 * 60:
			return
		TimeSystem.advance_minutes(240)
		var gained := GameState.grant_permanent_attribute("intellect", 1)
		GameState.set_investigation_state("wu_xuan_computer_game_completed", true)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		var reward_text := "你在一套老旧的解谜游戏里花了四个小时，思路变得更清晰。"
		if gained > 0:
			reward_text += "\n\n[color=sea_green]永久获得：智力 +%d[/color]" % gained
		else:
			reward_text += "\n\n你的智力已达到上限，无法继续提升。"
		interaction_ui.open_paged_text("本地游戏", [reward_text])
	elif choice_id == "search_archives":
		GameState.trigger_clue("committee_2000_glasses_bronze_fragment")
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		interaction_ui.open_paged_text(
			"档案检索结果",
			["检索到一条 2000 年的登报登记：一名戴眼镜的人拿着青铜鼎碎片，请求在地方报纸上刊登相关消息。登记没有留下完整姓名，附件也已缺失。"],
			"",
			{
				"id": "committee_2000_glasses_bronze_fragment",
				"title": "2000 年登报登记",
				"summary": "一名戴眼镜的人持青铜鼎碎片请求登报，登记缺少姓名与附件。",
				"pages": ["2000 年登报登记：一名戴眼镜的人拿着青铜鼎碎片，请求在地方报纸上刊登相关消息。登记没有留下完整姓名，附件也已缺失。"],
			}
		)


func _open_hospital_notice(highlight: MaskInteractionHighlight, interaction_ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	interaction_ui.open_document(
		"田原村全体村民联名请愿书",
		load("res://assets/documents/hospital_notice.jpg"),
		{
			"id": "hospital_relocation_petition",
			"title": "田原村全体村民联名请愿书",
			"summary": "村民请求迁走“干水固”医院，并在旧址建立利水君观。",
			"image_path": "res://assets/documents/hospital_notice.jpg",
		}
	)


func _create_village_chief_house_hotspots() -> void:
	# 保险柜位于画面左侧高柜区域。这里使用透明矩形热点，避免为尚无独立遮罩的物品伪造素材。
	var safe_button := Button.new()
	safe_button.name = "VillageChiefSafeHotspot"
	safe_button.anchor_left = 0.17
	safe_button.anchor_top = 0.13
	safe_button.anchor_right = 0.34
	safe_button.anchor_bottom = 0.58
	safe_button.flat = true
	safe_button.tooltip_text = "里屋保险柜"
	safe_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	add_child(safe_button)
	safe_button.pressed.connect(_open_village_chief_safe)


func _open_village_chief_safe() -> void:
	var ui := SceneItemInteraction.new()
	ui.name = "VillageChiefSafeInteraction"
	add_child(ui)
	if not NpcRegistry.get_npcs_at(location_id).is_empty():
		ui.open_choice({
			"id": "village_chief_safe_blocked",
			"title": "里屋保险柜",
			"description": "吴志源还在屋里。他一直留意着你的动作，现在不能检查这只保险柜。",
			"choices": [{"id": "leave", "label": "离开", "close": true}],
		})
		return
	if bool(GameState.get_investigation_state("village_chief_safe_opened", false)):
		ui.open_paged_text("里屋保险柜", ["保险柜已经被打开。你收好其中的账本记录，其余物品暂时没有新的发现。"])
		return
	if not GameState.has_item("village_chief_safe_silver_key"):
		ui.open_choice({
			"id": "village_chief_safe_locked",
			"title": "里屋保险柜",
			"description": "保险柜上着双锁。没有对应钥匙时，贸然撬动很可能留下明显痕迹。",
			"choices": [{"id": "leave", "label": "暂时离开", "close": true}],
		})
		return
	GameState.set_investigation_state("village_chief_safe_opened", true)
	GameState.trigger_clue("bribe_ledger")
	GameState.add_item("hunting_rifle")
	GameState.add_document_clue({
		"id": "bribe_ledger",
		"title": "可疑的贿赂账本",
		"summary": "一份记录异常款项往来的账本，可能与村中利益交换有关。",
		"pages": ["你用吴萱交出的备用钥匙打开了双锁保险柜。几本普通旧账中夹着一册没有封面的往来记录。", "记录里有数笔来源含糊的款项，日期与工厂撤出、医院迁址以及村中水源争议接近。收款人与具体用途被人为简写，像是刻意避免留下完整证据。"],
	})
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	SceneItemInteraction.show_content_added_toast("可疑的贿赂账本", "线索册")
	ui.open_paged_text("保险柜中的账本", ["你用备用钥匙打开保险柜，在普通旧账中发现了一册没有封面的异常往来记录。", "记录日期与工厂撤出、医院迁址和水源争议接近，但收款人与用途都被刻意简写。", "保险柜内侧还固定着一支旧猎枪。你将它收进背包；它可在攻击技能中作为武器使用。"])


func open_skill_menu_for_npc(npc_id: String = "", dialogue_ui: Node = null) -> void:
	var targets: Array[String] = []
	if not npc_id.is_empty() and NpcRegistry.is_npc_present_at(npc_id, location_id):
		targets.append(npc_id)
	elif npc_id.is_empty():
		targets = NpcRegistry.get_npcs_at(location_id)
	var entries: Array[Dictionary] = []
	if location_id == "temporary_dorm" and SkillSystem.is_medical_exam_unlocked():
		entries.append({
			"id": "medical_exam::water",
			"skill_id": "medical_exam",
			"target_id": "water",
			"title": "医学检验：淋浴水",
			"summary": "采集宿舍淋浴水样并生成污染检验线索。",
			"badge": "医学",
			"action_tooltip": "对淋浴水使用医学检验",
		})
	for target_id in targets:
		if not NpcRegistry.can_interact_with_npc(target_id):
			continue
		var target_name := NpcRegistry.get_short_name(target_id)
		for skill in SkillSystem.skills_for_target(true, location_id):
			var skill_id := String(skill.get("id", ""))
			if not SkillSystem.is_skill_available_for_npc(skill_id, target_id):
				continue
			entries.append({
				"id": "%s::%s" % [skill_id, target_id],
				"skill_id": skill_id,
				"target_id": target_id,
				"title": "%s：%s" % [String(skill.get("title", skill_id)), target_name],
				"summary": String(skill.get("description", "")),
				"badge": "医学" if skill_id == "medical_exam" else ("力量" if skill_id == "attack" else "魅力"),
				"action_tooltip": "对%s使用%s" % [target_name, String(skill.get("title", skill_id))],
			})
	var popup := ClueBookPopup.new()
	popup.name = "SkillListPopup"
	add_child(popup)
	popup.action_requested.connect(_on_skill_list_action.bind(popup, dialogue_ui))
	popup.open_action_list(entries, "技能", "选择当前场景可用的技能与目标。", "使用")


func _on_skill_list_action(entry: Dictionary, popup: ClueBookPopup, dialogue_ui: Node) -> void:
	var skill_id := String(entry.get("skill_id", ""))
	var target_id := String(entry.get("target_id", ""))
	if skill_id.is_empty() or target_id.is_empty():
		return
	var ui := SceneItemInteraction.new()
	ui.name = "SceneSkillInteraction"
	add_child(ui)
	ui.choice_selected.connect(_on_skill_ui_choice.bind(ui, dialogue_ui))
	if skill_id == "medical_exam":
		_apply_medical_skill(target_id, ui)
	elif skill_id == "attack":
		if is_instance_valid(popup):
			popup.queue_free()
		_open_attack_weapon_mode(target_id, ui)
	else:
		_open_social_reason(skill_id, target_id, ui)
	if is_instance_valid(popup):
		popup.queue_free()


func _open_attack_weapon_mode(npc_id: String, ui: SceneItemInteraction) -> void:
	ui.choice_selected.connect(_on_attack_weapon_mode_selected.bind(ui, npc_id), CONNECT_ONE_SHOT)
	ui.open_choice({
		"id": "attack_weapon_mode::%s" % npc_id,
		"title": "攻击：%s" % NpcRegistry.get_short_name(npc_id),
		"description": "选择徒手攻击，或打开背包选择一件物品作为武器。选定后会先明确展示力量检定难度，再由你确认。",
		"choices": [{"id": "bare_hands", "label": "徒手攻击"}, {"id": "open_bag", "label": "从背包选择武器"}, {"id": "leave", "label": "取消", "close": true}],
	})


func _on_attack_weapon_mode_selected(_interaction_id: String, choice_id: String, _result: Dictionary, ui: SceneItemInteraction, npc_id: String) -> void:
	if choice_id == "bare_hands":
		_open_attack_confirmation(npc_id, "", ui)
	elif choice_id == "open_bag":
		ui.close_interaction()
		_open_attack_weapon_bag(npc_id)


func _open_attack_weapon_bag(npc_id: String) -> void:
	var bag: Node = get_tree().get_first_node_in_group("attack_weapon_bag")
	if bag == null:
		bag = ITEM_BAG_POPUP_SCENE.instantiate()
		bag.name = "AttackWeaponBag"
		bag.add_to_group("attack_weapon_bag")
		add_child(bag)
	if bag.has_signal("weapon_picked"):
		bag.connect("weapon_picked", _on_attack_weapon_picked.bind(npc_id), CONNECT_ONE_SHOT)
	if bag.has_method("open_weapon_selection"):
		bag.call("open_weapon_selection", GameState.inventory)


func _on_attack_weapon_picked(weapon_id: String, npc_id: String) -> void:
	var ui := SceneItemInteraction.new()
	ui.name = "AttackConfirmation"
	add_child(ui)
	_open_attack_confirmation(npc_id, weapon_id, ui)


func _open_attack_confirmation(npc_id: String, weapon_id: String, ui: SceneItemInteraction) -> void:
	var preview := SkillSystem.get_attack_preview(npc_id, weapon_id)
	ui.choice_selected.connect(_on_attack_confirmation_selected.bind(ui, npc_id, weapon_id), CONNECT_ONE_SHOT)
	ui.open_choice({
		"id": "attack_confirm::%s" % npc_id,
		"title": "确认攻击：%s" % NpcRegistry.get_short_name(npc_id),
		"description": "武器：%s\n基础难度：%d；力量：%d；武器减难度：%d。\n本次力量检定最终难度为：%d。\n攻击成功会永久杀死目标；失败后目标将永久拒绝与你交互，且所有人都会知道这次攻击。" % [String(preview.get("weapon_name", "徒手")), int(preview.get("base_difficulty", 18)), int(preview.get("strength", 0)), int(preview.get("weapon_reduction", 0)), int(preview.get("final_difficulty", 18))],
		"choices": [{"id": "confirm", "label": "发动攻击"}, {"id": "leave", "label": "取消", "close": true}],
	})


func _on_attack_confirmation_selected(_interaction_id: String, choice_id: String, _result: Dictionary, ui: SceneItemInteraction, npc_id: String, weapon_id: String) -> void:
	if choice_id != "confirm":
		return
	if not NpcRegistry.is_npc_present_at(npc_id, location_id) or not NpcRegistry.can_interact_with_npc(npc_id):
		ui.open_paged_text("攻击无法发动", ["目标已经不在这里，或不再接受你的交互。"])
		return
	var result := SkillSystem.perform_attack_check(npc_id, weapon_id)
	var passed := bool(result.get("passed", false))
	var target_name := NpcRegistry.get_short_name(npc_id)
	var weapon_name := String(result.get("weapon_name", "徒手"))
	var pages: Array[String] = [CheckSystem.result_to_display_text(result)]
	if passed and NpcRegistry.kill_npc(npc_id, "被玩家用%s攻击致死" % weapon_name):
		pages.append("%s倒下后再也没有起身。该人物已永久死亡，此场景会切换为无人状态。" % target_name)
		MemoryStore.add_global_memory("外来者在%s用%s杀死了%s。村中所有人都已得知此事。" % [NpcRegistry.get_location_name(location_id), weapon_name, target_name], ["attack", "killed", npc_id, location_id])
	else:
		NpcRegistry.mark_npc_hostile(npc_id, "玩家使用%s攻击失败" % weapon_name)
		pages.append("攻击没有得手。%s从此拒绝与你进行任何交互；村中所有人都会知道你攻击过他。" % target_name)
		MemoryStore.add_global_memory("外来者在%s试图用%s攻击%s但失败了。村中所有人都已得知此事。" % [NpcRegistry.get_location_name(location_id), weapon_name, target_name], ["attack", "failed", npc_id, location_id])
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui != null and dialogue_ui.has_method("is_open") and dialogue_ui.is_open() and dialogue_ui.has_method("close_dialogue"):
		dialogue_ui.close_dialogue()
	TimeSystem.on_dialogue_turn_completed()
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	ui.open_paged_text("攻击检定", pages)


func _on_skill_ui_choice(interaction_id: String, choice_id: String, result: Dictionary, ui: SceneItemInteraction, dialogue_ui: Node) -> void:
	if not interaction_id.begins_with("social_skill::") or choice_id != "confirm":
		return
	var interaction_parts := interaction_id.split("::", false)
	if interaction_parts.size() != 3:
		return
	var reason := String(result.get("input", "")).strip_edges()
	if reason.is_empty():
		ui.open_choice({
			"id": interaction_id,
			"title": "需要说明理由",
			"description": "理由不能为空。具体、能引用事实或线索的理由更容易说服对方。",
			"allow_input": true,
			"input_placeholder": "输入你的理由……",
			"choices": [{"id": "confirm", "label": "进行魅力检定"}, {"id": "leave", "label": "取消", "close": true}],
		})
		return
	_resolve_social_skill(String(interaction_parts[1]), String(interaction_parts[2]), reason, ui, dialogue_ui)


func _open_social_reason(skill_id: String, npc_id: String, ui: SceneItemInteraction) -> void:
	var title := "劝离" if skill_id == "dismiss" else "说服同阵营"
	var description := "输入你的理由。检定会综合魅力、好感度、披露等级以及理由是否具体合理。"
	var placeholder := "输入你的说服理由……"
	if skill_id == "persuade_ally":
		description = "劝说对方加入你的阵营，与你共同摧毁祭坛。普通观点说服请直接在对话输入框中进行。"
		placeholder = "说明为什么应该与你共同摧毁祭坛……"
	ui.open_choice({
		"id": "social_skill::%s::%s" % [skill_id, npc_id],
		"title": "%s：%s" % [title, NpcRegistry.get_short_name(npc_id)],
		"description": description,
		"allow_input": true,
		"input_placeholder": placeholder,
		"choices": [{"id": "confirm", "label": "进行魅力检定"}, {"id": "leave", "label": "取消", "close": true}],
	})


func _resolve_social_skill(skill_id: String, npc_id: String, reason: String, ui: SceneItemInteraction, dialogue_ui: Node) -> void:
	var profile := NpcRegistry.get_dialogue_profile(npc_id)
	if profile.is_empty() or not NpcRegistry.can_be_persuaded(npc_id):
		ui.open_paged_text("技能无法使用", ["当前人物已经离开，或不接受这种形式的说服。"])
		return
	if skill_id == "persuade_ally" and bool(GameState.get_investigation_state("altar_ally_%s" % npc_id, false)):
		ui.open_paged_text("已经加入阵营", ["%s已经答应与你共同摧毁祭坛，无需再次检定。" % NpcRegistry.get_short_name(npc_id)])
		return
	if skill_id == "persuade_ally" and bool(GameState.get_investigation_state("altar_ally_attempted_%s" % npc_id, false)):
		ui.open_paged_text("机会已经用过", ["你已经尝试拉拢过%s。无论上次结果如何，都不能再次进行这项检定。" % NpcRegistry.get_short_name(npc_id)])
		return
	var check_result := SkillSystem.perform_social_check(profile, skill_id, reason)
	if skill_id == "persuade_ally":
		GameState.set_investigation_state("altar_ally_attempted_%s" % npc_id, true)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	if is_instance_valid(dialogue_ui) and dialogue_ui.has_method("resolve_scene_skill"):
		ui.close_interaction()
		dialogue_ui.resolve_scene_skill(skill_id, reason, check_result)
		return
	var passed := bool(check_result.get("passed", false))
	var pages: Array[String] = [CheckSystem.result_to_display_text(check_result), SkillSystem.social_breakdown(check_result)]
	if skill_id == "dismiss":
		if passed and NpcRegistry.dismiss_npc(npc_id, "被玩家以理由劝离：%s" % reason):
			pages.append("%s接受了你的理由，离开了当前场景。两小时内这里会保持无人，之后他会返回。" % NpcRegistry.get_short_name(npc_id))
		else:
			pages.append("%s拒绝离开。" % NpcRegistry.get_short_name(npc_id))
	else:
		if passed:
			GameState.add_affinity(npc_id, 1)
			GameState.set_investigation_state("altar_ally_%s" % npc_id, true)
			MemoryStore.add_belief(npc_id, "应该与外来者结成同盟，并共同摧毁祭坛", 3, reason, "altar_alliance_skill", "ally_destroy_altar")
			if npc_id == "wu_zhiyuan":
				GameState.add_item("village_chief_safe_silver_key")
				pages.append("村长把保险柜钥匙交给了你。")
			pages.append("%s被你的理由打动，正式答应加入你的阵营，与你共同摧毁祭坛。好感度 +1。" % NpcRegistry.get_short_name(npc_id))
		else:
			pages.append("%s认为风险太大，没有答应加入摧毁祭坛的阵营。" % NpcRegistry.get_short_name(npc_id))
	MemoryStore.add_global_memory("外来者以“%s”为理由对%s使用%s，检定%s。" % [reason, NpcRegistry.get_short_name(npc_id), "劝离" if skill_id == "dismiss" else "祭坛阵营拉拢", "成功" if passed else "失败"], ["skill", skill_id, npc_id])
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	ui.open_paged_text("技能检定", pages)


func _apply_medical_skill(target_id: String, ui: SceneItemInteraction) -> void:
	var data := SkillSystem.get_water_result() if target_id == "water" else SkillSystem.get_medical_result(target_id)
	if data.is_empty():
		return
	var pages: Array[String] = []
	for raw_page in data.get("pages", []):
		var page := String(raw_page).strip_edges()
		if not page.is_empty():
			pages.append(page)
	var entry := {
		"id": String(data.get("clue_id", "")),
		"title": String(data.get("title", "医学检验结果")),
		"summary": String(data.get("summary", "")),
		"pages": pages,
		"linked_clue_ids": data.get("linked_clue_ids", []),
	}
	if GameState.add_document_clue(entry):
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		SceneItemInteraction.show_content_added_toast(String(entry.get("title", "医学检验结果")), "线索册")
	ui.open_paged_text(String(data.get("title", "医学检验结果")), pages, "medical_exam::%s" % target_id)


func _show_scene_message(title: String, text: String) -> void:
	var ui := SceneItemInteraction.new()
	add_child(ui)
	ui.open_paged_text(title, [text])


func _on_scene_npc_presence_changed(_npc_id: String, from_loc: String, to_loc: String, _reason: String) -> void:
	if from_loc == location_id or to_loc == location_id:
		_refresh_scene_presence()


func _refresh_scene_presence() -> void:
	if location_id.is_empty():
		return
	var scene_empty := NpcRegistry.get_npcs_at(location_id).is_empty()
	# 田间小路的人物背景由分钟级日程控制，不能被通用的有人/无人刷新覆盖。
	# 否则玩家在出场时段进入场景时会看到人物 mask，却仍是无人背景。
	if _uses_road_hermit_schedule:
		_refresh_road_hermit_schedule()
	elif scene_empty and empty_background_texture != null:
		background.texture = alternate_empty_background_texture if _showing_alternate_view and alternate_empty_background_texture != null else empty_background_texture
	elif not _uses_time_based_background:
		background.texture = alternate_background_texture if _showing_alternate_view else background_texture
	for raw_id in _scene_npc_hotspots:
		var hotspot: Variant = _scene_npc_hotspots[raw_id]
		if hotspot is not Dictionary:
			continue
		var present := NpcRegistry.is_npc_present_at(String(raw_id), location_id)
		var button: Variant = (hotspot as Dictionary).get("button")
		var highlight: Variant = (hotspot as Dictionary).get("highlight")
		if button is CanvasItem:
			(button as CanvasItem).visible = present
		if highlight is CanvasItem and not present:
			(highlight as CanvasItem).visible = false


func _start_dorm_tutorial_if_needed() -> void:
	const TUTORIAL_STATE_ID := "onboarding:temporary_dorm_tutorial"
	if bool(GameState.get_investigation_state(TUTORIAL_STATE_ID, false)):
		return
	var tutorial_pages: Array[String] = [
		"欢迎来到思源村。你会从临时宿舍开始每一天的调查：前往地图上的地点、与村民交谈并观察环境，逐步拼出事件的真相。",
		"完成本指引后，这份教程会被收录在右侧的线索册中，方便你随时重看。",
		"点击场景中高亮人物或物品可以进行交互。右下角原有的技能按钮会列出当前场景可用的技能与目标；对话中点击同一按钮会针对当前人物打开技能列表。",
		"部分行动会触发检定。系统会掷出骰点，加入相应属性和修正值，再与难度（由你选择方式的合理性判定）比较；检定过程与成功或失败都会明确展示。某些物品每天只能尝试检定一次。",
		"时间会持续推进。白天可以自由调查；19点后需要回到临时宿舍休息，休息会推进到次日早晨9点。请留意一天内有限的行动与检定机会。",
		"准备好后，开始你的调查吧。"
	]
	var tutorial_ui := SceneItemInteraction.new()
	tutorial_ui.name = "DormOnboardingTutorial"
	add_child(tutorial_ui)
	tutorial_ui.paged_text_completed.connect(func(interaction_id: String) -> void:
		if interaction_id != TUTORIAL_STATE_ID:
			return
		GameState.set_investigation_state(TUTORIAL_STATE_ID, true)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		_show_onboarding_letter()
	)
	tutorial_ui.open_paged_text(
		"新手指引",
		tutorial_pages,
		TUTORIAL_STATE_ID,
		{
			"id": "onboarding_tutorial",
			"title": "调查基础指引",
			"summary": "关于对话、调查、检定、属性与时间机制的入门说明。",
			"pages": tutorial_pages,
		}
	)


func _show_onboarding_letter() -> void:
	var letter_ui := SceneItemInteraction.new()
	letter_ui.name = "OnboardingLetter"
	add_child(letter_ui)
	letter_ui.document_closed.connect(func() -> void:
		_show_onboarding_departure_prompt()
	, CONNECT_ONE_SHOT)
	letter_ui.open_document(
		"一封奇怪的信",
		load("res://assets/documents/letter.jpg"),
		{
			"id": "onboarding_strange_letter",
			"title": "一封奇怪的信",
			"summary": "你是一个专门拍小众题材的网红，近日收到了一封奇怪的信……",
			"image_path": "res://assets/documents/letter.jpg",
		},
		false,
		true,
		"你是一个专门拍小众题材的网红，近日收到了一封奇怪的信……"
	)


func _show_onboarding_departure_prompt() -> void:
	var prompt_ui := SceneItemInteraction.new()
	prompt_ui.name = "OnboardingDeparturePrompt"
	add_child(prompt_ui)
	prompt_ui.open_paged_text(
		"下一步",
		["初来乍到，先去熟悉一下周围的环境吧。村长家可能会有地图，先出门去那吧。"]
	)


func _create_temporary_dorm_hotspots() -> void:
	var door := _create_mask_hotspot(
		"DormDoor",
		"res://assets/scenes/masks/dorm_door_mask.png",
		Rect2(0.0, 0.0, 0.095, 1.0),
		"出门"
	)
	var bed := _create_mask_hotspot(
		"DormBed",
		"res://assets/scenes/masks/dorm_bed_mask.png",
		Rect2(0.20, 0.53, 0.24, 0.30),
		"休息至次日 09:00"
	)
	var shower := _create_mask_hotspot(
		"DormShower",
		"res://assets/scenes/masks/dorm_shower_mask.png",
		Rect2(0.80, 0.06, 0.14, 0.73),
		"洗澡"
	)
	var wake_ui := SceneItemInteraction.new()
	wake_ui.name = "DormMorningReport"
	add_child(wake_ui)
	var rest_ui := SceneItemInteraction.new()
	rest_ui.name = "DormRestConfirmation"
	add_child(rest_ui)
	(door["button"] as Button).pressed.connect(_leave_temporary_dorm.bind(door["highlight"]))
	(bed["button"] as Button).pressed.connect(_open_rest_confirmation.bind(bed["highlight"], rest_ui, wake_ui))
	(shower["button"] as Button).pressed.connect(_open_dorm_shower.bind(shower["highlight"]))


func _create_mask_hotspot(node_name: String, mask_path: String, area: Rect2, tooltip: String) -> Dictionary:
	var highlight := MaskInteractionHighlight.new()
	highlight.name = "%sHighlight" % node_name
	highlight.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	highlight.configure(load(mask_path), Color(0.28, 0.86, 1.0, 1.0), 0.20, 3.0)
	add_child(highlight)

	var hotspot := Button.new()
	hotspot.name = "%sHotspot" % node_name
	hotspot.anchor_left = area.position.x
	hotspot.anchor_top = area.position.y
	hotspot.anchor_right = area.position.x + area.size.x
	hotspot.anchor_bottom = area.position.y + area.size.y
	hotspot.flat = true
	hotspot.tooltip_text = tooltip
	hotspot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hotspot.mouse_entered.connect(highlight.show_highlight)
	hotspot.mouse_exited.connect(highlight.hide_highlight)
	add_child(hotspot)
	return {"highlight": highlight, "button": hotspot}


func _leave_temporary_dorm(highlight: MaskInteractionHighlight) -> void:
	highlight.hide_highlight()
	const EXITED_DORM_STATE := "temporary_dorm:first_exit_completed"
	var target_scene := "res://scenes/locations/FieldPath.tscn"
	# 初次离开宿舍由村长接待；此后出门默认前往田间小路。
	if not bool(GameState.get_investigation_state(EXITED_DORM_STATE, false)):
		GameState.set_investigation_state(EXITED_DORM_STATE, true)
		target_scene = "res://scenes/locations/VillageChiefHouse.tscn"
	GameState.change_scene(target_scene)


func _open_rest_confirmation(highlight: MaskInteractionHighlight, rest_ui: SceneItemInteraction, wake_ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	rest_ui.choice_selected.connect(func(interaction_id: String, choice_id: String, _result: Dictionary) -> void:
		if interaction_id != "dorm_rest" or choice_id != "confirm_rest":
			return
		_rest_in_temporary_dorm(rest_ui, wake_ui)
	, CONNECT_ONE_SHOT)
	rest_ui.open_choice({
		"id": "dorm_rest",
		"title": "休息",
		"description": "现在休息将直接推进到明天早上 09:00。确定要睡下吗？",
		"choices": [
			{"id": "confirm_rest", "label": "确定休息"},
			{"id": "leave", "label": "离开", "close": true},
		],
	})


func _rest_in_temporary_dorm(rest_ui: SceneItemInteraction, wake_ui: SceneItemInteraction) -> void:
	if not GameState.rest_at_location(location_id):
		return
	var report := GameState.get_latest_morning_report()
	if not bool(report.get("show", false)):
		rest_ui.close_interaction()
		return
	var pages: Array[String] = []
	for raw_page in report.get("pages", []):
		if raw_page is String and not raw_page.strip_edges().is_empty():
			pages.append(raw_page)
	rest_ui.close_interaction()
	if not pages.is_empty():
		wake_ui.open_paged_text(String(report.get("title", "清晨")), pages)


func _open_dorm_shower(highlight: MaskInteractionHighlight) -> void:
	highlight.hide_highlight()
	var shower_ui := SceneItemInteraction.new()
	shower_ui.name = "DormShowerInteraction"
	add_child(shower_ui)
	if GameState.has_showered_on_day(TimeSystem.current_day):
		shower_ui.open_choice({
			"id": "dorm_shower",
			"title": "淋浴",
			"description": "你今天已经洗过澡了。保持清洁能避免次日醒来时魅力下降。",
			"choices": [{"id": "leave", "label": "离开", "close": true}],
		})
		return
	shower_ui.choice_selected.connect(func(interaction_id: String, choice_id: String, _result: Dictionary) -> void:
		if interaction_id != "dorm_shower" or choice_id != "shower":
			return
		if GameState.shower_today():
			shower_ui.open_paged_text("洗浴", ["你用冷水简单冲洗了身体。你的魅力已恢复到初始设定值。"])
	)
	shower_ui.open_choice({
		"id": "dorm_shower",
		"title": "淋浴",
		"description": "洗澡每天只能进行一次。若前一天没有洗澡，次日早上九点魅力会降低 1；洗澡则会恢复到初始设定的魅力。",
		"choices": [
			{"id": "shower", "label": "洗澡"},
			{"id": "leave", "label": "离开", "close": true},
		],
	})


## M6：NpcPresenceBar 上的"召集所有人谈话"按钮触发 → 打开 GroupChatUI
func _on_group_chat_requested() -> void:
	var gc_ui := get_node_or_null("GroupChatUI")
	if gc_ui == null:
		return
	var loc_id := location_id
	if loc_id == "":
		var scene := get_tree().current_scene
		loc_id = NpcRegistry.location_id_for_scene(String(scene.scene_file_path)) if scene != null else ""
	if loc_id == "":
		return
	var npc_ids := NpcRegistry.get_interactable_npcs_at(loc_id)
	if npc_ids.size() < 2:
		return
	# 获取内嵌的 GroupChatCoordinator 节点
	var coord := gc_ui.get_node_or_null("GroupChatCoordinator")
	if coord == null:
		return
	if not gc_ui.has_method("set_coordinator"):
		return
	gc_ui.set_coordinator(coord)
	gc_ui.open(loc_id, npc_ids)


## NpcPresenceBar 上选中某 NPC → 走 NpcInteractable 路径打开私聊
func _on_presence_npc_selected(npc_id: String) -> void:
	if not NpcRegistry.can_interact_with_npc(npc_id):
		return
	var ui := get_tree().get_first_node_in_group("dialogue_ui")
	if ui == null or (ui.has_method("is_open") and ui.is_open()):
		return
	# 在 spawner 里找到该 NPC 节点
	if npc_spawner == null:
		return
	for child in npc_spawner.get_children():
		if child is Node2D and child.has_method("on_player_interact"):
			if String(child.get("npc_id")) == npc_id:
				child.on_player_interact(self)
				return


func _apply_responsive_layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var safe_margin := clampf(size.x * 0.06, 16.0, 64.0)
	var panel_width := minf(780.0, size.x - safe_margin * 2.0)
	var panel_height := minf(440.0, size.y - 120.0)
	content_panel.offset_left = -panel_width * 0.5
	content_panel.offset_right = panel_width * 0.5
	content_panel.offset_top = -panel_height * 0.5
	content_panel.offset_bottom = panel_height * 0.5
	var action_button_width := minf(190.0, size.x * 0.38)
	return_button.offset_right = -safe_margin
	return_button.offset_left = return_button.offset_right - action_button_width
	return_button.offset_top = safe_margin
	return_button.offset_bottom = safe_margin + 52.0
	if is_instance_valid(_view_toggle_button):
		_view_toggle_button.offset_left = safe_margin
		_view_toggle_button.offset_right = safe_margin + minf(188.0, size.x * 0.36)
		_view_toggle_button.offset_top = safe_margin
		_view_toggle_button.offset_bottom = safe_margin + 52.0


func _create_view_toggle_button() -> void:
	if is_instance_valid(_view_toggle_button):
		return
	_view_toggle_button = Button.new()
	_view_toggle_button.name = "ViewToggleButton"
	_view_toggle_button.text = alternate_view_label
	_view_toggle_button.tooltip_text = "切换同一地点的前后视角"
	_view_toggle_button.add_theme_font_size_override("font_size", 18)
	_view_toggle_button.pressed.connect(_toggle_background_view)
	add_child(_view_toggle_button)


func _toggle_background_view() -> void:
	_showing_alternate_view = not _showing_alternate_view
	_refresh_scene_presence()
	if is_instance_valid(_view_toggle_button):
		_view_toggle_button.text = "切换至前方" if _showing_alternate_view else alternate_view_label


func _on_time_changed(_day: int, _minute_of_day: int) -> void:
	_refresh_time_based_background()
	_refresh_road_hermit_schedule()


func _refresh_time_based_background() -> void:
	if not _uses_time_based_background:
		return
	# 临时宿舍在 19:00（含）后显示夜景，其余时间显示日景；两张图尺寸相同，遮罩坐标无需变动。
	var is_night := TimeSystem.minute_of_day >= 19 * 60
	background.texture = alternate_background_texture if is_night else background_texture
	background.visible = background.texture != null


func _refresh_road_hermit_schedule() -> void:
	if not _uses_road_hermit_schedule:
		return
	var should_show := NpcRegistry.is_mysterious_hermit_road_time()
	if not should_show and not _road_hermit_departure_deferred and _is_hermit_dialogue_open():
		# 如果 18:00 到点时仍在交谈，本次进入场景期间不再切走人物。
		# 场景离开后节点会销毁，下次进入时重新依据真实时间判定。
		_road_hermit_departure_deferred = true
	if _road_hermit_departure_deferred:
		should_show = true
	_set_road_hermit_visible(should_show)


func _is_hermit_dialogue_open() -> bool:
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or not dialogue_ui.has_method("is_open") or not dialogue_ui.is_open():
		return false
	var active_npc: Variant = dialogue_ui.get("current_npc")
	return active_npc is Dictionary and String((active_npc as Dictionary).get("id", "")) == "mysterious_hermit"


func _set_road_hermit_visible(visible_now: bool) -> void:
	background.texture = scheduled_background_texture if visible_now else background_texture
	background.visible = background.texture != null
	if _road_hermit_nodes.is_empty():
		_road_hermit_nodes = _create_mask_hotspot(
			"RoadMysteriousHermit",
			"res://assets/scenes/masks/road_man_mask.png",
			Rect2(0.155, 0.485, 0.105, 0.370),
			"与神秘人交谈"
		)
		(_road_hermit_nodes["button"] as Button).pressed.connect(_open_road_mysterious_hermit_dialogue)
	(_road_hermit_nodes["highlight"] as Control).visible = visible_now
	(_road_hermit_nodes["button"] as Control).visible = visible_now


func _open_road_mysterious_hermit_dialogue() -> void:
	if _road_hermit_nodes.is_empty():
		return
	(_road_hermit_nodes["highlight"] as MaskInteractionHighlight).hide_highlight()
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or not dialogue_ui.has_method("open_dialogue"):
		return
	if dialogue_ui.has_method("is_open") and dialogue_ui.is_open():
		return
	if not NpcRegistry.can_interact_with_npc("mysterious_hermit"):
		_show_scene_message("无人回应", "神秘人警惕地避开了你，不再接受交谈。")
		return
	var profile: Dictionary = NpcRegistry.get_dialogue_profile("mysterious_hermit")
	if not profile.is_empty():
		dialogue_ui.open_dialogue(profile)


func _open_map() -> void:
	InputManager.request_open_map()
