extends Control
## 地图地点的共享占位场景。后续可用真正的探索场景替换各地点文件。

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"
const ITEM_BAG_POPUP_SCENE := preload("res://scenes/ui/ItemBagPopup.tscn")
const PHOTO_MATCHING_INTERACTION_SCRIPT := preload("res://scripts/ui/PhotoMatchingInteraction.gd")
const ATTRIBUTE_RESPEC_POPUP_SCRIPT := preload("res://scripts/ui/AttributeRespecPopup.gd")

const PHOTO_MATCH_ATTEMPT_STATE := "item_check:wu_xuan_photo_location_match"
const COMMITTEE_ACTIVITY_CUTOFF_MINUTE := 19 * 60
const LIN_DIARY_ATTEMPT_STATE := "item_check:lin_deshan_diary_match"
const LIN_DIARY_PROGRESS_STATE := "lin_deshan:diary_match_progress"
const TAOIST_TEMPLE_DAY_TEXTURE := preload("res://assets/scenes/taoist_temple_day.png")
const TAOIST_TEMPLE_NIGHT_TEXTURE := preload("res://assets/scenes/taoist_temple_night.png")
const TAOIST_TEMPLE_REAR_TEXTURE := preload("res://assets/scenes/taoist_temple_rear.png")
const VILLAGE_CHIEF_NIGHT_TEXTURE_PATH := "res://assets/scenes/village_chief_house_night.png"
const LIN_DIARY_OPTIONS := [
	{"id": "garbled_name", "label": "???（姓名被涂抹）"},
	{"id": "li_leshui", "label": "李乐水"},
	{"id": "niu_lanshan", "label": "牛岚山"},
	{"id": "gong_zhong", "label": "龚忠"},
	{"id": "yu_le", "label": "于乐"},
	{"id": "mu_jiang", "label": "穆江"},
	{"id": "wu_zhiyuan", "label": "吴志源"},
	{"id": "wu_xuan", "label": "吴萱"},
]
const LIN_DIARY_SNIPPETS := [
	{"label": "疯话 1", "text": "我这红脸的关公，战那白脸的曹操，简直OK，顶呱呱！", "answer_id": "garbled_name"},
	{"label": "疯话 2", "text": "临时的庸俗躯体快被挣脱，黑暗中的微弱烛光将要吹灭。", "answer_id": "li_leshui"},
	{"label": "疯话 3", "text": "那人握着压住潮声的刻度，能让翻涌的黑暗暂时学会安静。", "answer_id": "niu_lanshan"},
	{"label": "疯话 4", "text": "青绿色的甲虫快要掘到金子，却被披羊皮的灰狼藏起来活埋。", "answer_id": "gong_zhong"},
	{"label": "疯话 5", "text": "有声音从锅底升起来，才让迟疑熬成了香气。", "answer_id": "yu_le"},
	{"label": "疯话 6", "text": "后来雨从门缝流成黑色，站在外头的人敲那没有回应的门。", "answer_id": "mu_jiang"},
	{"label": "疯话 7", "text": "锁住致命的火光，防备的并非山里的野兽。", "answer_id": "wu_zhiyuan"},
]
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
## 所有地点统一使用场景遮罩互动；动态 NPC 立绘生成器默认关闭。
@export var use_npc_spawner: bool = false
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
var _farmland_bird_button: Button
var _farmland_bird_highlight: MaskInteractionHighlight
var _farmland_bird_ui: SceneItemInteraction
var _farmland_bird_judge_request_id := 0
var _road_hermit_nodes: Dictionary = {}
## 地图按钮放入独立 HUD 层，避免被场景遮罩热点截获点击。
var _map_action_layer: CanvasLayer
var _scene_npc_hotspots: Dictionary = {}
var _cave_front_nodes: Array[CanvasItem] = []
var _cave_back_nodes: Array[CanvasItem] = []
var _uses_taoist_temple_cycle := false
var _uses_village_chief_night_state := false
var _night_return_dialog_open := false
var _taoist_in_rear_room := false
var _village_chief_nodes: Dictionary = {}
var _taoist_front_nodes: Array[CanvasItem] = []
var _taoist_rear_nodes: Array[CanvasItem] = []

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
	if not location_id.is_empty():
		AudioManager.play_location_bgm(location_id)
	background.texture = background_texture
	background.visible = background_texture != null
	# 背景与全尺寸 mask 使用同一种拉伸规则，确保任意窗口比例下视觉与命中区域对齐。
	background.stretch_mode = TextureRect.STRETCH_SCALE
	background.modulate = Color.WHITE
	number_label.text = location_number
	title_label.text = location_name
	description_label.text = location_description
	if status_label != null:
		status_label.text = "地点描述：%s" % location_description
	accent.color = accent_color
	# 有背景图时隐藏占位 Content 面板（场景已接入真背景，不再显示"待开发"）
	content_panel.visible = background_texture == null and alternate_background_texture == null
	_uses_time_based_background = location_id == "temporary_dorm" and background_texture != null and alternate_background_texture != null
	_uses_road_hermit_schedule = location_id == "field_path" and scheduled_background_texture != null
	_uses_taoist_temple_cycle = location_id == "taoist_temple"
	_uses_village_chief_night_state = location_id == "village_chief_house"
	if not TimeSystem.minute_changed.is_connected(_on_time_changed):
		TimeSystem.minute_changed.connect(_on_time_changed)
	if _uses_time_based_background or _uses_taoist_temple_cycle or _uses_village_chief_night_state:
		_refresh_time_based_background()
		_refresh_taoist_temple_state()
	elif alternate_background_texture != null:
		_create_view_toggle_button()
	_move_map_button_to_hud_layer()
	return_button.pressed.connect(_open_map)
	if not GameState.night_return_required.is_connected(_on_night_return_required):
		GameState.night_return_required.connect(_on_night_return_required)
	GameState.item_added.connect(_on_item_added)
	_refresh_map_access()
	call_deferred("_enforce_night_location_return")
	return_button.grab_focus()
	# 使用场景遮罩人物交互的地点，不生成动态全身立绘。
	if not use_npc_spawner:
		_disable_location_npcs()
	elif npc_spawner != null and location_id != "":
		npc_spawner.location_id = location_id
	if presence_bar != null:
		presence_bar.location_id = location_id
		if use_npc_spawner:
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
	elif location_id == "lakeside_dock":
		_create_lakeside_dock_hotspots()
	elif location_id == "lakeside_pavilion":
		_create_lakeside_pavilion_hotspots()
	elif location_id == "taoist_temple":
		_create_taoist_temple_hotspots()
	elif location_id == "construction_site":
		_create_construction_site_hotspots()
	elif location_id == "farmland":
		_create_farmland_hotspots()
	elif location_id == "carpenter_workshop":
		_create_carpenter_workshop_hotspots()
	elif location_id == "back_mountain":
		_create_cave_hotspots()
	elif location_id == "temporary_dorm":
		_create_temporary_dorm_hotspots()
		call_deferred("_start_dorm_tutorial_if_needed")
		call_deferred("_show_day_two_mysterious_note_if_needed")
	if not NpcRegistry.npc_moved.is_connected(_on_scene_npc_presence_changed):
		NpcRegistry.npc_moved.connect(_on_scene_npc_presence_changed)
	_refresh_scene_presence()
	call_deferred("_apply_responsive_layout")


func should_use_npc_spawner() -> bool:
	return use_npc_spawner


func _disable_location_npcs() -> void:
	# 仅保留场景遮罩互动，不显示动态 NPC 立绘或顶部在场人物栏。
	if npc_spawner != null:
		if npc_spawner.has_method("disable_spawning"):
			npc_spawner.disable_spawning()
		else:
			npc_spawner.location_id = ""
			npc_spawner.hide()
			for child in npc_spawner.get_children():
				child.queue_free()


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
	var night_without_lantern := GameState.is_night_outing_time() and not GameState.can_night_travel()
	return_button.disabled = not unlocked
	if not unlocked:
		return_button.tooltip_text = "先向村长询问并取得村庄手绘地图"
		return_button.text = "地图尚未解锁"
	elif night_without_lantern:
		return_button.tooltip_text = "路太黑了，现在还不具备夜间出门的能力。"
		return_button.text = "夜间无法出门"
	else:
		return_button.tooltip_text = "打开地图"
		return_button.text = "打开地图  M / Esc"


func _enforce_night_location_return() -> void:
	if TimeSystem.minute_of_day < TimeSystem.NIGHT_OUTING_START_MINUTE:
		return
	if location_id in [GameState.TEMP_DORM_LOCATION_ID, "village_chief_house", "taoist_temple"]:
		return
	if TimeSystem.is_rest_lock_time():
		GameState.night_rest_required = true
	_on_night_return_required("天色已晚，当前地点不能继续停留。请立即返回临时宿舍。")


func _on_night_return_required(message: String) -> void:
	if _night_return_dialog_open:
		return
	_night_return_dialog_open = true
	var dialog := AcceptDialog.new()
	dialog.title = "夜间休整"
	dialog.dialog_text = message
	dialog.ok_button_text = "返回宿舍"
	dialog.exclusive = true
	add_child(dialog)
	dialog.confirmed.connect(GameState.confirm_night_return)
	dialog.close_requested.connect(GameState.confirm_night_return)
	dialog.popup_centered(Vector2i(520, 220))


func _open_map() -> void:
	if GameState.is_night_outing_time() and not GameState.can_night_travel():
		_show_scene_message("夜路太黑", "路太黑了，现在还不具备夜间出门的能力。")
		return
	if GameState.can_open_world_map():
		InputManager.request_open_map()


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
	_show_committee_computer_menu(interaction_ui)


func _show_committee_computer_menu(interaction_ui: SceneItemInteraction) -> void:
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
		var can_play := not bool(GameState.get_investigation_state("wu_xuan_computer_game_completed", false)) and TimeSystem.minute_of_day + 240 <= COMMITTEE_ACTIVITY_CUTOFF_MINUTE
		if can_play:
			choices.append({"id": "play_game", "label": "玩本地游戏（消耗 4 小时）"})
		elif bool(GameState.get_investigation_state("wu_xuan_computer_game_completed", false)):
			description += "你已经通过本地游戏获得过一次智力成长。"
		else:
			description += "距离 19:00 已不足四小时，现在不适合开始游戏。"
	if has_archive_access:
		choices.append({"id": "search_archives", "label": "查找档案"})
	choices.append({"id": "leave", "label": "离开", "close": true})
	interaction_ui.open_choice({
		"id": "committee_computer",
		"title": "村委电脑",
		"description": description,
		"choices": choices,
	})


func _on_committee_computer_choice(interaction_id: String, choice_id: String, _result: Dictionary, interaction_ui: SceneItemInteraction) -> void:
	if interaction_id == "committee_computer":
		if choice_id == "play_game":
			if bool(GameState.get_investigation_state("wu_xuan_computer_game_completed", false)):
				return
			if not _can_finish_committee_activity(240, interaction_ui):
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
			_show_committee_archive_menu(interaction_ui)
		return
	if interaction_id != "committee_archive_search":
		return
	if choice_id == "back":
		_show_committee_computer_menu(interaction_ui)
		return
	_open_committee_archive_entry(choice_id, interaction_ui)


func _show_committee_archive_menu(interaction_ui: SceneItemInteraction) -> void:
	if not GameState.has_item("village_committee_archive_access"):
		interaction_ui.open_paged_text("权限不足", ["当前权限只能使用电脑里的公开资料和本地游戏，不能检索内部档案。"])
		return
	var choices: Array[Dictionary] = []
	var archive_options := [
		{"id": "archive_registration_2000", "clue_id": "committee_2000_glasses_bronze_fragment", "label": "（1）2000 年登报登记"},
		{"id": "archive_accident_2000", "clue_id": "committee_2000_accident_report", "label": "（2）2000 年事故报道"},
		{"id": "archive_believer_letter", "clue_id": "committee_believer_final_letter", "label": "（3）某信众临终书"},
		{"id": "archive_ecology_records", "clue_id": "committee_ecological_surveys", "label": "（4）田原村生态调查记录"},
	]
	for option in archive_options:
		if not GameState.has_clue(String(option["clue_id"])):
			choices.append({"id": option["id"], "label": option["label"] + "（耗时 1 小时）"})
	choices.append({"id": "back", "label": "返回电脑主页"})
	var description := "限定档案库列出了四组可检索资料。每查阅一组需要 1 小时，完整查看后会收录到线索册。"
	if choices.size() == 1:
		description = "四组限定档案均已完成查阅，可在线索册中随时复核。"
	elif TimeSystem.minute_of_day + 60 > COMMITTEE_ACTIVITY_CUTOFF_MINUTE:
		description += "\n\n距离 19:00 已不足 1 小时，现在无法开始新的档案调查。"
	interaction_ui.open_choice({
		"id": "committee_archive_search",
		"title": "查找档案",
		"description": description,
		"choices": choices,
	})


func _open_committee_archive_entry(choice_id: String, interaction_ui: SceneItemInteraction) -> void:
	if not GameState.has_item("village_committee_archive_access"):
		interaction_ui.open_paged_text("权限不足", ["档案查阅授权已经失效。"])
		return
	var entry := _committee_archive_entry(choice_id)
	if entry.is_empty():
		return
	var clue_id := String(entry.get("id", ""))
	if GameState.has_clue(clue_id):
		interaction_ui.open_paged_text("已完成查阅", ["这组档案已经收录到线索册，无需再次消耗时间。"])
		return
	if not _can_finish_committee_activity(60, interaction_ui):
		return
	TimeSystem.advance_minutes(60)
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	var image_path := String(entry.get("image_path", ""))
	if not image_path.is_empty():
		var image_texture := load(image_path) as Texture2D
		if image_texture == null:
			interaction_ui.open_paged_text("档案损坏", ["扫描附件无法读取，本次检索未能打开资料。"])
			return
		interaction_ui.open_document(String(entry["title"]), image_texture, entry, true, true, String(entry.get("description", "")))
		return
	var pages: Array[String] = []
	for raw_page in entry.get("pages", []):
		pages.append(String(raw_page))
	interaction_ui.open_paged_text(String(entry["title"]), pages, "committee_archive_viewed", entry)


func _committee_archive_entry(choice_id: String) -> Dictionary:
	match choice_id:
		"archive_registration_2000":
			var pages: Array[String] = ["2000 年的登报登记：一名裹得严严实实的神秘男子拿着青铜鼎碎片，说是在家附近找到的文物，请求在地方报纸上刊登相关消息。登记没有留下完整姓名，没有记录面部特征，附件也已缺失。"]
			return {"id": "committee_2000_glasses_bronze_fragment", "title": "2000 年登报登记", "summary": "一名全身裹得严实的神秘男子持青铜鼎碎片请求登报；登记未留完整姓名和面部特征，附件缺失。", "pages": pages}
		"archive_accident_2000":
			return {"id": "committee_2000_accident_report", "title": "2000 年工地事故报道", "summary": "地方报道记载田原村工地在 2000 年 4 月发生坍塌，造成 5 人死亡、3 人重伤、2 人轻伤，并指出安全管理与材料问题。", "image_path": "res://assets/documents/accident.png", "description": "一份 2000 年 5 月刊出的地方报道扫描件，可滚轮缩放并拖动查看。"}
		"archive_believer_letter":
			var pages: Array[String] = ["某信众临终书\n\n吾师鉴之：\n常释已成，神威稍复，恩泽重降。然全释未行，神体犹困。\n\n吾等五人破禁，三人还本。余与另一师兄虽存，然神威入体，日夜煎熬，寿不过三年。", "师曾言：须候七七之期，方可行全释。然吾等已无力再候。神威入体者，灵台渐失，恐将沦为神之傀儡，再难自主。\n\n璞人已觅得，就在邻村。吾欲提前行全释之法，违师训，背禁忌。", "然若再候七七之期，吾恐已非人，何以行法？\n\n望师恕罪。弟子不孝，今夜便行。"]
			return {"id": "committee_believer_final_letter", "title": "某信众临终书", "summary": "一封写给师父的绝笔，提到五人破禁、三人“还本”、神威入体、七七之期，以及在邻村找到的“璞人”。", "pages": pages}
		"archive_ecology_records":
			var pages: Array[String] = ["【地质勘探报告（1999）】\n后山溶洞调查发现洞壁有人工凿痕；洞底黑色沉积物有机质异常偏高，样本运送途中升温 2℃。报告建议不开发。", "【古树名木调查表（1994）】\n林业局登记 7 棵古树，其中后山柏木枝叶全部朝同一方向异常生长，树旁有不明碎石堆。", "【动植物资源调查报告（1993）】\n生物系暑期实践记录到红豆杉群落、红腹锦鸡及未知蛙类。未知蛙类鸣叫声如“叩石声”，调查期间未采集到标本。"]
			return {"id": "committee_ecological_surveys", "title": "田原村生态调查记录", "summary": "1993 至 1999 年的三份调查记录，涉及后山溶洞异常沉积物、定向生长的柏木与发出“叩石声”的未知蛙类。", "pages": pages}
	return {}


func _can_finish_committee_activity(duration_minutes: int, interaction_ui: SceneItemInteraction) -> bool:
	if TimeSystem.minute_of_day + duration_minutes <= COMMITTEE_ACTIVITY_CUTOFF_MINUTE:
		return true
	interaction_ui.open_paged_text("时间不足", ["这项电脑操作需要 %d 分钟，现在开始会超过 19:00。请明天再来。" % duration_minutes])
	return false


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
	var chief := _create_mask_hotspot(
		"VillageChief",
		"res://assets/scenes/masks/chief_mask.png",
		Rect2(0.64, 0.08, 0.30, 0.84),
		"与村长吴志源交谈"
	)
	var television_closet := _create_mask_hotspot(
		"VillageChiefTelevisionCloset",
		"res://assets/scenes/masks/television_closet_mask.png",
		Rect2(0.07, 0.32, 0.24, 0.38),
		"查看电视柜"
	)
	var safe := _create_mask_hotspot(
		"VillageChiefSafe",
		"res://assets/scenes/masks/safe_mask.png",
		Rect2(0.18, 0.15, 0.23, 0.50),
		"查看里屋保险柜"
	)
	_village_chief_nodes = {"chief": chief, "television": television_closet, "safe": safe}
	(chief["button"] as Button).pressed.connect(func() -> void:
		(chief["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_village_chief_dialogue()
	)
	(television_closet["button"] as Button).pressed.connect(func() -> void:
		(television_closet["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_village_chief_television_closet()
	)
	(safe["button"] as Button).pressed.connect(func() -> void:
		(safe["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_village_chief_safe()
	)
	_refresh_village_chief_night_state()


func _refresh_village_chief_night_state() -> void:
	if not _uses_village_chief_night_state:
		return
	var is_night := GameState.is_night_outing_time()
	if is_night:
		var night_texture := load(VILLAGE_CHIEF_NIGHT_TEXTURE_PATH) as Texture2D
		background.texture = night_texture if night_texture != null else empty_background_texture
	else:
		background.texture = background_texture
	background.visible = background.texture != null
	if _village_chief_nodes.is_empty():
		return
	for key in ["chief", "television", "safe"]:
		var node_set: Dictionary = _village_chief_nodes.get(key, {})
		if node_set.is_empty():
			continue
		var highlight := node_set.get("highlight") as MaskInteractionHighlight
		var button := node_set.get("button") as Control
		if highlight != null:
			highlight.hide_highlight()
			if key == "chief":
				highlight.visible = not is_night
		if button != null:
			button.visible = key != "chief" or not is_night


func _open_village_chief_dialogue() -> void:
	var ui := SceneItemInteraction.new()
	ui.name = "VillageChiefAbsentInteraction"
	add_child(ui)
	if not NpcRegistry.is_npc_present_at("wu_zhiyuan", location_id):
		ui.open_paged_text("村长家", ["屋里空无一人。村长暂时不在。"])
		return
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or (dialogue_ui.has_method("is_open") and dialogue_ui.is_open()):
		return
	var profile := NpcRegistry.get_dialogue_profile("wu_zhiyuan")
	profile["dialogue_stage"] = GameState.get_npc_dialogue_stage("wu_zhiyuan")
	if dialogue_ui.has_method("open_dialogue"):
		dialogue_ui.open_dialogue(profile)


func _open_village_chief_television_closet() -> void:
	var ui := SceneItemInteraction.new()
	ui.name = "VillageChiefTelevisionClosetInteraction"
	add_child(ui)
	if not GameState.is_night_outing_time():
		ui.open_choice({
			"id": "village_chief_television_closet_blocked",
			"title": "电视柜",
			"description": "柜子里好像有一些文件，但村长正盯着你，现在不能打开。",
			"choices": [{"id": "leave", "label": "离开", "close": true}],
		})
		return
	ui.choice_selected.connect(_on_village_chief_television_closet_choice.bind(ui), CONNECT_ONE_SHOT)
	ui.open_choice({
		"id": "village_chief_television_closet",
		"title": "电视柜",
		"description": "夜里的屋子空无一人。电视柜的锁扣并不结实，但弄出动静可能会留下痕迹。",
		"choices": [
			{"id": "pry_open", "label": "撬开电视柜（敏捷检定 20，每天限一次）", "type": "check", "attribute": "敏捷", "difficulty": 20, "reason": "趁夜撬开村长家电视柜", "success_text": "锁扣轻轻一响，柜门开了。", "failure_text": "锁扣没有松动。"},
			{"id": "leave", "label": "离开", "close": true},
		],
	})


func _on_village_chief_television_closet_choice(interaction_id: String, choice_id: String, result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id != "village_chief_television_closet" or choice_id != "pry_open" or not bool(result.get("passed", false)):
		return
	ui.open_document(
		"工厂撤出公告",
		load("res://assets/documents/notice.png"),
		{
			"id": "factory_withdrawal_notice",
			"title": "工厂撤出公告",
			"summary": "甘艾集团 2015 年撤出田原村，公告特别提醒当地水流污染严重，非必要不下水。",
			"image_path": "res://assets/documents/notice.png",
			"linked_clue_ids": ["factory_withdrawal_notice", "factory_withdrawal_confirmed"],
		}
	)
	if GameState.get_quest_stage("wu_xuan_factory_notice") >= 1:
		GameState.set_quest_stage("wu_xuan_factory_notice", 2)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)


func _open_village_chief_safe() -> void:
	var ui := SceneItemInteraction.new()
	ui.name = "VillageChiefSafeInteraction"
	add_child(ui)
	if not NpcRegistry.get_npcs_at(location_id).is_empty():
		ui.open_choice({
			"id": "village_chief_safe_blocked",
			"title": "里屋保险柜",
			"description": "村长正盯着你，现在不能开锁。",
			"choices": [{"id": "leave", "label": "离开", "close": true}],
		})
		return
	if bool(GameState.get_investigation_state("village_chief_safe_opened", false)):
		ui.open_paged_text("里屋保险柜", ["保险柜已经被打开，里面的猎枪已被你收好。其余物品暂时没有新的发现。"])
		return
	var choices: Array[Dictionary] = [{"id": "pry_lock", "label": "撬锁（敏捷检定 30，每天限一次）"}]
	if GameState.has_item("village_chief_safe_silver_key"):
		choices.append({"id": "use_key", "label": "使用钥匙"})
	choices.append({"id": "leave", "label": "离开", "close": true})
	ui.choice_selected.connect(_on_village_chief_safe_choice.bind(ui), CONNECT_ONE_SHOT)
	ui.open_choice({
		"id": "village_chief_safe",
		"title": "里屋保险柜",
		"description": "保险柜上着双锁。你可以尝试撬锁，或使用吴萱交给你的备用钥匙。",
		"choices": choices,
	})


func _on_village_chief_safe_choice(interaction_id: String, choice_id: String, _result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id != "village_chief_safe":
		return
	if choice_id == "use_key":
		if GameState.has_item("village_chief_safe_silver_key"):
			_unlock_village_chief_safe(ui, "你用吴萱交出的备用钥匙打开了双锁保险柜。")
		return
	if choice_id != "pry_lock":
		return
	var state_key := "village_chief_house:safe_pry_lock"
	var previous: Variant = GameState.get_investigation_state(state_key, {})
	if previous is Dictionary and int((previous as Dictionary).get("day", 0)) == TimeSystem.current_day:
		ui.open_paged_text("里屋保险柜", ["你今天已经尝试过撬锁了。不要在同一把锁上留下更多痕迹。"])
		return
	GameState.set_investigation_state(state_key, {"day": TimeSystem.current_day})
	var check_result := CheckSystem.perform_check("敏捷", 30, 0, "撬开村长家保险柜")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	if bool(check_result.get("passed", false)):
		_unlock_village_chief_safe(ui, "你屏住呼吸拨动锁芯，双锁终于依次弹开。")
		return
	ui.open_paged_text("里屋保险柜", [CheckSystem.result_to_display_text(check_result), "锁芯发出一声闷响，却没有打开。你今天不能再尝试了。"])


func _unlock_village_chief_safe(ui: SceneItemInteraction, opening_text: String) -> void:
	if bool(GameState.get_investigation_state("village_chief_safe_opened", false)):
		ui.open_paged_text("里屋保险柜", ["保险柜已经被打开。"])
		return
	GameState.set_investigation_state("village_chief_safe_opened", true)
	GameState.add_item("hunting_rifle")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	SceneItemInteraction.show_content_added_toast("猎枪", "背包")
	ui.open_paged_text("保险柜中的猎枪", [opening_text, "保险柜内侧固定着一支旧猎枪。你将它收进背包；它可在攻击技能中作为武器使用。"])


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
	var seal_note := "；封印成功难度-5" if int(preview.get("seal_reduction", 0)) > 0 else ""
	ui.open_choice({
		"id": "attack_confirm::%s" % npc_id,
		"title": "确认攻击：%s" % NpcRegistry.get_short_name(npc_id),
		"description": "武器：%s\n基础难度：%d%s；力量：%d；武器减难度：%d。\n本次力量检定最终难度为：%d。\n攻击成功会永久杀死目标；失败后目标将永久拒绝与你交互，且所有人都会知道这次攻击。" % [String(preview.get("weapon_name", "徒手")), int(preview.get("base_difficulty", 18)), seal_note, int(preview.get("strength", 0)), int(preview.get("weapon_reduction", 0)), int(preview.get("final_difficulty", 18))],
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


func _dismiss_attempt_state_key() -> String:
	return "skill:dismiss_attempt:%s" % location_id


func _dismiss_attempted_today() -> bool:
	var state: Variant = GameState.get_investigation_state(_dismiss_attempt_state_key(), {})
	return state is Dictionary and int((state as Dictionary).get("day", -1)) == TimeSystem.current_day


func _open_social_reason(skill_id: String, npc_id: String, ui: SceneItemInteraction) -> void:
	if skill_id == "dismiss" and _dismiss_attempted_today():
		ui.open_paged_text("今天已经使用过劝离", ["同一场景每天只能进行一次劝离检定。你可以明天再尝试。"])
		return
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
	if skill_id == "dismiss" and _dismiss_attempted_today():
		ui.open_paged_text("今天已经使用过劝离", ["同一场景每天只能进行一次劝离检定。你可以明天再尝试。"])
		return
	if skill_id == "persuade_ally" and bool(GameState.get_investigation_state("altar_ally_%s" % npc_id, false)):
		ui.open_paged_text("已经加入阵营", ["%s已经答应与你共同摧毁祭坛，无需再次检定。" % NpcRegistry.get_short_name(npc_id)])
		return
	if skill_id == "persuade_ally" and bool(GameState.get_investigation_state("altar_ally_attempted_%s" % npc_id, false)):
		ui.open_paged_text("机会已经用过", ["你已经尝试拉拢过%s。无论上次结果如何，都不能再次进行这项检定。" % NpcRegistry.get_short_name(npc_id)])
		return
	var check_result := SkillSystem.perform_social_check(profile, skill_id, reason)
	if skill_id == "dismiss":
		GameState.set_investigation_state(_dismiss_attempt_state_key(), {"day": TimeSystem.current_day, "npc_id": npc_id})
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
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


func _create_cave_hotspots() -> void:
	var offering := _create_mask_hotspot("CaveOfferingTable", "res://assets/scenes/masks/cave_offering_table_mask.png", Rect2(0.459, 0.630, 0.079, 0.055), "村民供奉的祭台")
	var dirt := _create_mask_hotspot("CaveDirtHole", "res://assets/scenes/masks/cave_dirt_hole_mask.png", Rect2(0.055, 0.742, 0.314, 0.258), "查看土堆")
	var passage := _create_mask_hotspot("CavePassage", "res://assets/scenes/masks/cave_passage_mask.png", Rect2(0.461, 0.449, 0.079, 0.169), "通往山洞后方")
	var exit := _create_mask_hotspot("CaveExit", "res://assets/scenes/masks/cave_exit_mask.png", Rect2(0.750, 0.810, 0.250, 0.190), "返回山洞前方")
	var water := _create_mask_hotspot("CaveWater", "res://assets/scenes/masks/cave_water_mask.png", Rect2(0.234, 0.483, 0.500, 0.238), "查看水潭")
	var ritual := _create_mask_hotspot("CaveRitualTable", "res://assets/scenes/masks/cave_ritual_table_mask.png", Rect2(0.320, 0.407, 0.060, 0.068), "查看洞内祭坛")
	_cave_front_nodes = [offering["highlight"], offering["button"], dirt["highlight"], dirt["button"], passage["highlight"], passage["button"]]
	_cave_back_nodes = [exit["highlight"], exit["button"], water["highlight"], water["button"], ritual["highlight"], ritual["button"]]
	var offering_ui := SceneItemInteraction.new()
	offering_ui.name = "CaveOfferingInteraction"
	add_child(offering_ui)
	offering_ui.choice_selected.connect(_on_cave_offering_choice.bind(offering_ui))
	var dirt_ui := SceneItemInteraction.new()
	dirt_ui.name = "CaveDirtInteraction"
	add_child(dirt_ui)
	dirt_ui.choice_selected.connect(_on_cave_dirt_choice.bind(dirt_ui))
	var passage_ui := SceneItemInteraction.new()
	passage_ui.name = "CavePassageInteraction"
	add_child(passage_ui)
	passage_ui.choice_selected.connect(_on_cave_passage_choice.bind(passage_ui))
	var water_ui := SceneItemInteraction.new()
	water_ui.name = "CaveWaterInteraction"
	add_child(water_ui)
	water_ui.choice_selected.connect(_on_cave_water_choice.bind(water_ui))
	var ritual_ui := SceneItemInteraction.new()
	ritual_ui.name = "CaveRitualInteraction"
	add_child(ritual_ui)
	ritual_ui.choice_selected.connect(_on_cave_ritual_choice.bind(ritual_ui))
	(offering["button"] as Button).pressed.connect(_open_cave_offering.bind(offering["highlight"], offering_ui))
	(dirt["button"] as Button).pressed.connect(_open_cave_dirt.bind(dirt["highlight"], dirt_ui))
	(passage["button"] as Button).pressed.connect(_open_cave_passage.bind(passage["highlight"], passage_ui))
	(exit["button"] as Button).pressed.connect(_return_to_cave_front.bind(exit["highlight"]))
	(water["button"] as Button).pressed.connect(_open_cave_water.bind(water["highlight"], water_ui))
	(ritual["button"] as Button).pressed.connect(_open_cave_ritual.bind(ritual["highlight"], ritual_ui))
	_showing_alternate_view = bool(GameState.get_investigation_state("cave_back_unlocked", false)) and bool(GameState.get_investigation_state("cave_resume_back_view", false))
	_refresh_cave_view()


func _refresh_cave_view() -> void:
	if location_id != "back_mountain":
		return
	for node in _cave_front_nodes:
		if is_instance_valid(node):
			# 高亮仅由鼠标悬停事件显式显示，切换视角时不得默认可见。
			node.visible = false if node is MaskInteractionHighlight else not _showing_alternate_view
	for node in _cave_back_nodes:
		if is_instance_valid(node):
			# 高亮仅由鼠标悬停事件显式显示，切换视角时不得默认可见。
			node.visible = false if node is MaskInteractionHighlight else _showing_alternate_view
	if is_instance_valid(_view_toggle_button):
		_view_toggle_button.visible = false
	background.texture = alternate_background_texture if _showing_alternate_view else background_texture
	background.visible = background.texture != null


func _open_cave_offering(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	var choices: Array[Dictionary] = [{"id": "leave", "label": "离开", "close": true}]
	if GameState.has_item("fresh_fish") and not bool(GameState.ritual_offering_days.get(str(TimeSystem.current_day), false)):
		choices.push_front({"id": "offer_fish", "label": "供奉鱼"})
	ui.open_choice({
		"id": "cave_offering_table",
		"title": "村民供奉的祭台",
		"description": "石台上残留着鱼骨、盐渍与干涸水痕。村民曾在这里放置贡品。供奉会在次日带来全属性增益。",
		"choices": choices,
	})


func _on_cave_offering_choice(interaction_id: String, choice_id: String, _result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id != "cave_offering_table" or choice_id != "offer_fish":
		return
	if GameState.offer_ritual_fish():
		GameState.set_investigation_state("cave_offered_today", true)
		ui.open_paged_text("供奉完成", ["你把鱼放到石台上。湿冷的气息沿着手腕爬过，随即又消失。明日醒来时，你会感到某种力量短暂回应了你。"])
	else:
		ui.open_paged_text("无法供奉", ["今天已经供奉过，或你没有可以放上的鱼。"])


func _open_cave_dirt(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	var has_shovel := GameState.has_item("rusty_shovel")
	ui.open_choice({
		"id": "cave_dirt_hole",
		"title": "松动的土堆",
		"description": "你带着生锈的铲子，可以撬开这块明显松动的泥层。" if has_shovel else "这个土堆下面似乎有东西。如果能找到一把铲子，就可以省力地挖开；徒手翻土则非常困难。",
		"choices": [
			{"id": "dig", "label": "翻开土堆（力量检定）", "type": "check", "attribute": "力量", "difficulty": 8 if has_shovel else 25, "reason": "用%s翻开山洞前的松动土堆" % ("铲子" if has_shovel else "徒手"), "success_text": "泥土被翻开，里面露出一只深绿色铁皮工具箱。", "failure_text": "土层比想象中更紧实，你今天无法再继续挖掘。"},
			{"id": "leave", "label": "离开", "close": true},
		],
	})


func _on_cave_dirt_choice(interaction_id: String, choice_id: String, result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id != "cave_dirt_hole" or choice_id != "dig" or not bool(result.get("passed", false)):
		return
	if GameState.collect_one_shot_item("gong_toolbox"):
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		SceneItemInteraction.show_content_added_toast("深绿色工具箱", "物品栏")
		ui.open_paged_text("挖出工具箱", ["你从湿土里拖出一只深绿色铁皮工具箱。两层卡扣沾满泥，但箱体仍然完好。"])
	else:
		ui.open_paged_text("土堆", ["土堆里已经没有别的东西了。"])


func _open_cave_passage(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	if bool(GameState.get_investigation_state("cave_back_unlocked", false)):
		_enter_cave_back()
		return
	var has_ladder := GameState.has_item("wooden_ladder")
	var has_rope := GameState.has_item("climbing_rope")
	var difficulty := 11 if has_ladder else (15 if has_rope else 28)
	var tool_name := "木梯子" if has_ladder else ("长绳子" if has_rope else "徒手")
	ui.open_choice({
		"id": "cave_passage",
		"title": "通往山洞后方的道路",
		"description": "道路很深很黑，湿滑的石壁向下延伸。使用%s通过会进行敏捷检定。" % tool_name,
		"choices": [
			{"id": "descend", "label": "进入深处（敏捷检定）", "type": "check", "attribute": "敏捷", "difficulty": difficulty, "reason": "使用%s下到山洞后方" % tool_name, "success_text": "你稳住身体，穿过黑暗的通路。", "failure_text": "你在湿滑石壁前停住脚步，今天不能再冒险下行。"},
			{"id": "leave", "label": "离开", "close": true},
		],
	})


func _on_cave_passage_choice(interaction_id: String, choice_id: String, result: Dictionary, _ui: SceneItemInteraction) -> void:
	if interaction_id == "cave_passage" and choice_id == "descend" and bool(result.get("passed", false)):
		GameState.set_investigation_state("cave_back_unlocked", true)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		_enter_cave_back()


func _enter_cave_back() -> void:
	_showing_alternate_view = true
	GameState.set_investigation_state("cave_resume_back_view", true)
	_refresh_cave_view()


func _return_to_cave_front(highlight: MaskInteractionHighlight) -> void:
	highlight.hide_highlight()
	_showing_alternate_view = false
	GameState.set_investigation_state("cave_resume_back_view", false)
	_refresh_cave_view()


func _open_cave_water(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	ui.open_choice({
		"id": "cave_water_pool",
		"title": "深处水潭",
		"description": "水潭平静得没有一丝波纹，倒映出的你仿佛比现实更清晰。步入水中可以重新分配基础点数与锻炼获得的永久点数。",
		"choices": [{"id": "enter_water", "label": "步入水中"}, {"id": "leave", "label": "离开", "close": true}],
	})


func _on_cave_water_choice(interaction_id: String, choice_id: String, _result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id != "cave_water_pool" or choice_id != "enter_water":
		return
	GameState.record_water_contact("cave_respec_pool")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	ui.close_interaction()
	var popup := ATTRIBUTE_RESPEC_POPUP_SCRIPT.new()
	add_child(popup)


func _open_cave_ritual(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	var altar_state := String(GameState.get_investigation_state("altar_resolution", "untouched"))
	if altar_state == "destroyed":
		ui.open_paged_text("洞内祭坛", ["祭坛已经被摧毁，石块散在水里。空气中仍残留着潮湿而不安的回声。"])
		return
	if altar_state == "sealed":
		ui.open_paged_text("洞内祭坛", ["水尺嵌在矩形凹槽中，封印纹路仍发着微弱冷光。这里暂时安静了。"])
		return
	var choices: Array[Dictionary] = []
	if GameState.has_item("hunting_rifle"):
		choices.append({"id": "destroy", "label": "使用猎枪摧毁祭坛"})
	if GameState.has_item("li_leshui_talisman"):
		choices.append({"id": "raise_talisman", "label": "高举护符"})
	else:
		choices.append({"id": "blocked", "label": "水太深，无法靠近", "close": true})
	choices.append({"id": "leave", "label": "离开", "close": true})
	ui.open_choice({"id": "cave_ritual_table", "title": "洞内祭坛", "description": "水太深，无法走到祭坛前。" if not GameState.has_item("li_leshui_talisman") else "护符在掌心发冷，你似乎可以踩着水靠近祭坛。", "choices": choices})


func _on_cave_ritual_choice(interaction_id: String, choice_id: String, result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id == "cave_seal_ritual" and choice_id == "seal":
		_on_cave_ritual_check(interaction_id, choice_id, result, ui)
		return
	if interaction_id != "cave_ritual_table":
		return
	if choice_id == "destroy":
		GameState.set_investigation_state("altar_resolution", "destroyed")
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		ui.open_paged_text("祭坛崩裂", ["枪声在洞中回荡，祭坛石面裂开，黑水从裂缝里涌出又迅速退去。你已经选择了摧毁它。"])
		EndingController.on_altar_resolution_changed()
	elif choice_id == "raise_talisman":
		if not GameState.has_item("old_water_gauge"):
			ui.open_paged_text("原始加固仪式", ["你踩着水靠近祭坛，发现石面中央有一个矩形凹槽。没有旧水尺，仪式无法开始。"])
			return
		var penalty := GameState.get_ritual_offering_penalty()
		ui.open_choice({
			"id": "cave_seal_ritual",
			"title": "原始加固仪式",
			"description": "你踩着水靠近祭坛。石面中央有一个矩形凹槽。",
			"choices": [{"id": "seal", "label": "使用旧水尺加固封印（智力检定）", "type": "check", "attribute": "智力", "difficulty": 5 + penalty, "reason": "使用旧水尺加固洞内祭坛封印", "success_text": "水尺嵌入凹槽，封印纹路开始闭合。", "failure_text": "水尺在凹槽边缘震动，仪式今天无法继续。"}, {"id": "leave", "label": "离开", "close": true}],
		})
	elif interaction_id == "cave_seal_ritual" and choice_id == "seal":
		pass


func _on_cave_ritual_check(interaction_id: String, choice_id: String, result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id != "cave_seal_ritual" or choice_id != "seal" or not bool(result.get("passed", false)):
		return
	GameState.set_investigation_state("altar_resolution", "sealed")
	GameState.trigger_clue("seal_success")
	var entry := {"id": "seal_success_document", "title": "封印成功", "summary": "旧水尺嵌入祭坛凹槽，原始封印重新闭合。", "pages": ["原始仪式成功。水尺嵌入凹槽，祭坛纹路重新闭合，洞内的潮声短暂沉寂。"], "linked_clue_ids": ["seal_success"]}
	if GameState.add_document_clue(entry):
		SceneItemInteraction.show_content_added_toast("封印成功", "线索册")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	ui.open_paged_text("封印成功", ["水尺嵌入凹槽，祭坛纹路重新闭合。你感到远处有什么东西骤然虚弱下来。夜间道士似乎终于能重新掌控自己的身体。"])
	EndingController.on_altar_resolution_changed()


func _create_carpenter_workshop_hotspots() -> void:
	var carpenter := _create_mask_hotspot(
		"CarpenterMuJiang",
		"res://assets/scenes/masks/studio_human_mask.png",
		Rect2(0.308, 0.079, 0.232, 0.528),
		"与穆江交谈"
	)
	var knife := _create_mask_hotspot(
		"CarpenterKnife",
		"res://assets/scenes/masks/studio_knife_mask.png",
		Rect2(0.267, 0.576, 0.102, 0.129),
		"进行木工练习"
	)
	var wood := _create_mask_hotspot(
		"CarpenterWood",
		"res://assets/scenes/masks/studio_wood_mask.png",
		Rect2(0.054, 0.531, 0.203, 0.357),
		"查看木料"
	)
	var woodbox := _create_mask_hotspot(
		"CarpenterWoodbox",
		"res://assets/scenes/masks/studio_woodbox_mask.png",
		Rect2(0.797, 0.465, 0.098, 0.085),
		"查看木盒"
	)
	_scene_npc_hotspots["mu_jiang"] = carpenter

	var practice_ui := SceneItemInteraction.new()
	practice_ui.name = "CarpenterPracticeInteraction"
	add_child(practice_ui)
	practice_ui.choice_selected.connect(_on_carpenter_practice_choice.bind(practice_ui))
	var wood_ui := SceneItemInteraction.new()
	wood_ui.name = "CarpenterWoodInteraction"
	add_child(wood_ui)
	wood_ui.choice_selected.connect(_on_carpenter_wood_choice.bind(wood_ui))
	var box_ui := SceneItemInteraction.new()
	box_ui.name = "CarpenterWoodboxInteraction"
	add_child(box_ui)
	box_ui.code_puzzle_submitted.connect(_on_carpenter_woodbox_code.bind(box_ui))
	box_ui.choice_selected.connect(_on_carpenter_woodbox_choice.bind(box_ui))

	(carpenter["button"] as Button).pressed.connect(_open_mu_jiang_dialogue.bind(carpenter["highlight"]))
	(knife["button"] as Button).pressed.connect(_open_carpenter_practice.bind(knife["highlight"], practice_ui))
	(wood["button"] as Button).pressed.connect(_open_carpenter_wood.bind(wood["highlight"], wood_ui))
	(woodbox["button"] as Button).pressed.connect(_open_carpenter_woodbox.bind(woodbox["highlight"], box_ui))


func _open_mu_jiang_dialogue(highlight: MaskInteractionHighlight) -> void:
	highlight.hide_highlight()
	if not NpcRegistry.is_npc_present_at("mu_jiang", location_id):
		_show_scene_message("无人回应", "工坊里只剩木香和刨花，穆江此刻不在。")
		return
	if not NpcRegistry.can_interact_with_npc("mu_jiang"):
		_show_scene_message("无人回应", "穆江收起了手边的木料，不愿再与你交谈。")
		return
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or not dialogue_ui.has_method("open_dialogue"):
		return
	if dialogue_ui.has_method("is_open") and dialogue_ui.is_open():
		return
	var profile := NpcRegistry.get_dialogue_profile("mu_jiang")
	if not profile.is_empty():
		dialogue_ui.open_dialogue(profile)


func _open_carpenter_practice(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	if TimeSystem.minute_of_day + 240 > TimeSystem.NIGHT_OUTING_START_MINUTE:
		ui.open_paged_text("木工练习", ["距离 19:00 已不足四小时。穆江没有开口，只把锯子按回桌面，示意你明天再来。"])
		return
	ui.open_choice({
		"id": "carpenter_woodwork_practice",
		"title": "木工练习",
		"description": "你可以在穆江的默许下练习锯切、修边和榫口处理。完整练习需要四小时。成功完成一定次数的练习可能会获得意外的收获。",
		"choices": [
			{"id": "practice", "label": "开始练习（消耗 4 小时）"},
			{"id": "leave", "label": "暂时离开", "close": true},
		],
	})


func _on_carpenter_practice_choice(interaction_id: String, choice_id: String, _result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id != "carpenter_woodwork_practice" or choice_id != "practice":
		return
	var completed := int(GameState.get_investigation_state("carpenter_woodwork_practice_count", 0))
	if not _can_finish_before_rest_lock(240, ui):
		return
	TimeSystem.advance_minutes(240)
	var gained := GameState.grant_permanent_attribute("strength", 1)
	completed += 1
	GameState.set_investigation_state("carpenter_woodwork_practice_count", completed)
	var pages: Array[String] = ["四小时过去，你的手腕开始记住锯子和木料之间的阻力。"]
	if gained > 0:
		pages.append("[color=sea_green]永久获得：力量 +%d[/color]" % gained)
	if completed >= 2 and GameState.collect_one_shot_item("straw_scarecrow"):
		SceneItemInteraction.show_content_added_toast("稻草人", "物品栏")
		pages.append("第二次练习结束后，你用剩下的木料和稻草扎出了一个结实的稻草人。")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	ui.open_paged_text("木工练习完成", pages)


func _open_carpenter_wood(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	ui.open_choice({
		"id": "carpenter_wood_inspection",
		"title": "工坊木料",
		"description": "不同年份留下的木料与成品堆在一起。你可以仔细观察工艺，也可以挑一块合适的木料带走。",
		"choices": [
			{
				"id": "observe",
				"label": "观察工艺（智力检定）",
				"type": "check",
				"attribute": "智力",
				"difficulty": 20,
				"reason": "比较穆江不同时期木器的榫卯、纹理与火燎定形痕迹",
				"success_text": "你在新旧木器之间看出了难以忽略的手艺差异。",
				"failure_text": "纹理、火痕和榫角的信息太杂乱，你暂时无法判断其中规律。",
			},
			{"id": "collect", "label": "获取一块木料"},
			{"id": "leave", "label": "离开", "close": true},
		],
	})


func _on_carpenter_wood_choice(interaction_id: String, choice_id: String, result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id != "carpenter_wood_inspection":
		return
	if choice_id == "observe" and bool(result.get("passed", false)):
		GameState.trigger_clue("mu_jiang_craft_decline")
		var entry := {
			"id": "mu_jiang_craft_decline_document",
			"title": "穆江手艺的变化",
			"summary": "早年的榫卯严丝合缝、纹路顺达；近年的作品却有错位和杂乱火痕。",
			"pages": [
				"穆江越早的制作手艺越好。之前的木器，榫卯严丝合缝、纹路顺达。",
				"近年的作品却不同：榫角有明显错位，火燎定形的痕迹也杂乱无章。"
			],
		}
		if GameState.add_document_clue(entry):
			SceneItemInteraction.show_content_added_toast("穆江手艺的变化", "线索册")
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		ui.open_paged_text("木料观察", entry["pages"], "", entry)
	elif choice_id == "collect":
		if GameState.collect_one_shot_item("quality_timber"):
			GameState.save_game(GameState.AUTO_SAVE_PATH, false)
			SceneItemInteraction.show_content_added_toast("上等木料", "物品栏")
			ui.open_paged_text("获得木料", ["你挑出一块纹路完整、干燥适中的木料，小心地收好。"])
		else:
			ui.open_paged_text("工坊木料", ["你已经带走过一块合适的木料，剩下的还是留给穆江吧。"])


func _open_carpenter_woodbox(highlight: MaskInteractionHighlight, ui: SceneItemInteraction) -> void:
	highlight.hide_highlight()
	if bool(GameState.get_investigation_state("carpenter_woodbox_solved", false)):
		ui.open_paged_text("木盒", ["木盒已经打开。里面的合照和日记都已被你仔细收录。"])
		return
	ui.open_code_puzzle(
		"木盒雕纹",
		load("res://assets/documents/aizhi.jpg"),
		"艾芝女士三十岁生日快乐，这是我结合你的出生月日的两个汉字与姓名的两个汉字设计的木雕图案。",
		"0320",
		{
			"interaction_id": "carpenter_woodbox_puzzle",
			"id": "deduce_code",
			"label": "尝试推理（智力检定）",
			"type": "check",
			"attribute": "智力",
			"difficulty": 25,
			"reason": "根据生日提示、姓名和木雕图案推断木盒密码",
			"success_text": "你从图案的结构和提示中理清了四位数字。",
			"failure_text": "图案里的线索仍未能组成明确的四位数字。",
		}
	)


func _on_carpenter_woodbox_code(interaction_id: String, solved: bool, ui: SceneItemInteraction) -> void:
	if interaction_id == "carpenter_woodbox_puzzle" and solved:
		_reward_carpenter_woodbox(ui)


func _on_carpenter_woodbox_choice(interaction_id: String, choice_id: String, result: Dictionary, ui: SceneItemInteraction) -> void:
	if interaction_id == "carpenter_woodbox_puzzle" and choice_id == "deduce_code" and bool(result.get("passed", false)):
		_reward_carpenter_woodbox(ui)


func _reward_carpenter_woodbox(ui: SceneItemInteraction) -> void:
	if bool(GameState.get_investigation_state("carpenter_woodbox_solved", false)):
		return
	GameState.set_investigation_state("carpenter_woodbox_solved", true)
	GameState.trigger_clue("mu_jiang_aizhi_diary")
	var photo_entry := {
		"id": "mu_jiang_aizhi_photo",
		"title": "艾芝与穆江的合照",
		"summary": "一张艾芝和穆江的旧合照，两人站在林区木料前，神情都比现在轻松。",
		"image_path": "res://assets/documents/mu_jiang_aizhi_photo.jpg",
		"linked_clue_ids": ["mu_jiang_aizhi_connection"],
	}
	var diary_pages: Array[String] = [
		"2014 11 6 多云\n那女人和她男人果然是一伙的，我真是看错她了，那些城里来的衣冠禽兽全都一个样！",
		"2014 11 7 阴\n今天路过村子的时候，正好看见那女人口吐黑血。要我说，这就是老祖宗显灵，让那些富哥姥爷们滚回城里去吧，我们小村子供不起这些大佛。",
		"2014 12 13 雪\n甘先生今天打来了电话，说送去县城的医院抢救时已经错过了治疗时间。她临终前口述三事：一曰河水有毒，色黑气腥；二曰有一道士于河畔施法，置生灵于水中，顷刻毙命；三曰'利库伊'三字，不知所指。我不愿再想了，这些事就带进坟墓里吧。"
	]
	var diary_entry := {
		"id": "mu_jiang_aizhi_diary_document",
		"title": "穆江关于艾芝的日记",
		"summary": "穆江误解艾芝、目睹她吐出黑血，并记录下她临终反复提及利库伊和道士。",
		"pages": diary_pages,
		"linked_clue_ids": ["mu_jiang_aizhi_diary"],
	}
	if GameState.add_document_clue(photo_entry):
		SceneItemInteraction.show_content_added_toast("艾芝与穆江的合照", "线索册")
	if GameState.add_document_clue(diary_entry):
		SceneItemInteraction.show_content_added_toast("穆江关于艾芝的日记", "线索册")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	ui.open_paged_text("木盒中的日记", diary_pages, "", diary_entry)


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
	if location_id == "taoist_temple":
		_refresh_taoist_temple_state()
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
		"点击场景中高亮人物或物品可以进行交互。右下角的使用技能按钮会列出当前场景可用的技能与目标；对话中可以出示线索册中的线索，出示相关性强的证据能撬开人物紧闭的嘴。",
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
			"summary": "你是一个专门拍小众题材的网红，近日收到了一封奇怪的信……新闻中也说这个村子的水源有污染问题，你决定到这个地方调查一番。",
			"image_path": "res://assets/documents/letter.jpg",
		},
		false,
		true,
		"你是一个专门拍小众题材的网红，近日收到了一封奇怪的信…………新闻中也说这个村子的水源有污染问题，你决定到这个地方调查一番。"
	)


func _show_onboarding_departure_prompt() -> void:
	var prompt_ui := SceneItemInteraction.new()
	prompt_ui.name = "OnboardingDeparturePrompt"
	add_child(prompt_ui)
	prompt_ui.open_paged_text(
		"下一步",
		["初来乍到，先去熟悉一下周围的环境吧。村长家可能会有地图，先出门去那吧。"]
	)


func _show_day_two_mysterious_note_if_needed() -> void:
	const NOTE_STATE_ID := "dorm:day_two_mysterious_note"
	if TimeSystem.current_day != 2 or not GameState.is_night_outing_time() or bool(GameState.get_investigation_state(NOTE_STATE_ID, false)):
		return
	GameState.set_investigation_state(NOTE_STATE_ID, true)
	GameState.trigger_clue("mysterious_stranger_dorm_note")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	var note_ui := SceneItemInteraction.new()
	note_ui.name = "DayTwoMysteriousNote"
	add_child(note_ui)
	var note_pages: Array[String] = ["你的窗户旁有一张奇怪的字条。\n\n你不觉得村子里的人很奇怪吗，明明水有问题却全都避而不谈。所有人都在受到影响，包括你自己，你感觉到了吗？想聊聊的话，明天下午五点到田间小路找我。我不能出现太久。"]
	note_ui.open_paged_text(
		"窗边的奇怪字条",
		note_pages,
		NOTE_STATE_ID,
		{
			"id": "mysterious_stranger_dorm_note",
			"title": "窗边的奇怪字条",
			"summary": "有人警告村民都在回避水的问题，并约你第三天下午五点到田间小路见面。",
			"pages": ["你不觉得村子里的人很奇怪吗，明明水有问题却全都避而不谈。所有人都在受到影响，包括你自己，你感觉到了吗？想聊聊的话，明天下午五点到田间小路找我。我不能出现太久。"],
		}
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


func _create_lakeside_dock_hotspots() -> void:
	var fisherman := _create_mask_hotspot(
		"DockFisherman",
		"res://assets/scenes/masks/fisherman_mask.png",
		Rect2(0.08, 0.18, 0.26, 0.66),
		"与渔夫于乐交谈"
	)
	var fishpond := _create_mask_hotspot(
		"DockFishpond",
		"res://assets/scenes/masks/fishpond_mask.png",
		Rect2(0.38, 0.30, 0.34, 0.56),
		"在鱼塘捕鱼"
	)
	var basket := _create_mask_hotspot(
		"DockBasket",
		"res://assets/scenes/masks/basket_mask.png",
		Rect2(0.70, 0.48, 0.20, 0.34),
		"查看岸边的篮子"
	)
	var fishing_ui := SceneItemInteraction.new()
	fishing_ui.name = "DockFishingInteraction"
	add_child(fishing_ui)
	fishing_ui.choice_selected.connect(_on_dock_fishing_choice.bind(fishing_ui))
	var basket_ui := SceneItemInteraction.new()
	basket_ui.name = "DockBasketInteraction"
	add_child(basket_ui)
	basket_ui.choice_selected.connect(_on_dock_basket_choice.bind(basket_ui))
	(fisherman["button"] as Button).pressed.connect(func() -> void:
		(fisherman["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_dock_fisherman_dialogue()
	)
	(fishpond["button"] as Button).pressed.connect(func() -> void:
		(fishpond["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_dock_fishing(fishing_ui)
	)
	(basket["button"] as Button).pressed.connect(func() -> void:
		(basket["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_dock_basket_puzzle(basket_ui)
	)


func _open_dock_fisherman_dialogue() -> void:
	if not NpcRegistry.can_interact_with_npc("yu_le"):
		return
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or (dialogue_ui.has_method("is_open") and dialogue_ui.is_open()):
		return
	var profile := NpcRegistry.get_dialogue_profile("yu_le")
	profile["dialogue_stage"] = GameState.get_npc_dialogue_stage("yu_le")
	if dialogue_ui.has_method("open_dialogue"):
		dialogue_ui.open_dialogue(profile)


func _can_finish_before_rest_lock(duration_minutes: int, interaction_ui: SceneItemInteraction) -> bool:
	if TimeSystem.minute_of_day + duration_minutes <= 19 * 60:
		return true
	interaction_ui.open_paged_text("时间不足", ["这项活动需要 %d 分钟，现在开始会超过 19:00。请先回宿舍休息，明天再来。" % duration_minutes])
	return false


func _open_dock_fishing(interaction_ui: SceneItemInteraction) -> void:
	interaction_ui.open_choice({
		"id": "lakeside_dock_fishing",
		"title": "鱼塘捕鱼",
		"description": "在于乐的鱼塘里捕鱼会消耗 4 小时。捉到了鱼，于乐或许会对你刮目相看。",
		"choices": [
			{"id": "fish", "label": "开始捕鱼（消耗 4 小时）"},
			{"id": "leave", "label": "离开", "close": true},
		],
	})


func _on_dock_fishing_choice(interaction_id: String, choice_id: String, _result: Dictionary, interaction_ui: SceneItemInteraction) -> void:
	if interaction_id != "lakeside_dock_fishing" or choice_id != "fish":
		return
	if not _can_finish_before_rest_lock(240, interaction_ui):
		return
	TimeSystem.advance_minutes(240)
	GameState.set_investigation_state("lakeside_dock:fishing_completed", true)
	GameState.record_water_contact("lakeside_dock_fishing")
	var pollution_day := int(GameState.get_investigation_state("lakeside_dock:fishing_pollution_day", 0))
	if pollution_day != TimeSystem.current_day:
		GameState.add_pollution(1)
		GameState.set_investigation_state("lakeside_dock:fishing_pollution_day", TimeSystem.current_day)
	var agility_gained := GameState.grant_permanent_attribute("agility", 1)
	var check_result := CheckSystem.perform_check("敏捷", 10, 0, "在湖边鱼塘收网捕鱼")
	var caught_fish := bool(check_result.get("passed", false))
	if caught_fish:
		GameState.set_investigation_state("lakeside_dock:fishing_success", 1)
		if not GameState.has_item("fresh_fish"):
			GameState.add_item("fresh_fish")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	var pages: Array[String] = ["四小时过去，你的身上沾满湿冷的湖水。"]
	if agility_gained > 0:
		pages.append("[color=sea_green]永久获得：敏捷 +%d[/color]" % agility_gained)
	var outcome := CheckSystem.result_to_display_text(check_result)
	if caught_fish:
		outcome += "\n[color=sea_green]你成功收网，获得物品：鱼。[/color]"
	else:
		outcome += "\n鱼从网眼间滑走了。"
	pages.append(outcome)
	interaction_ui.open_paged_text("鱼塘捕鱼", pages)


func _open_dock_basket_puzzle(interaction_ui: SceneItemInteraction) -> void:
	if bool(GameState.get_investigation_state("lakeside_dock:basket_opened", false)):
		interaction_ui.open_paged_text("木盒", ["木盒已经打开，里面的日记已被你收进线索册。"])
		return
	var basic_hint := String(GameState.get_investigation_state("lakeside_dock:basket_hint_basic_text", ""))
	var advanced_hint := String(GameState.get_investigation_state("lakeside_dock:basket_hint_advanced_text", ""))
	var description := "你在篮子下面发现了一个木盒，旁边有一张奇怪的图片，或许这图片指向的密码是打开木盒的关键……（答案为五位汉字）"
	if not basic_hint.is_empty():
		description += "\n\n已获得初级提示：%s" % basic_hint
	if not advanced_hint.is_empty():
		description += "\n已获得高级提示：%s" % advanced_hint
	var choices: Array[Dictionary] = [{"id": "submit", "label": "打开木盒"}]
	if basic_hint.is_empty():
		choices.append({"id": "basic_hint", "label": "获取初级提示（智力检定 13）"})
	if advanced_hint.is_empty():
		choices.append({"id": "advanced_hint", "label": "获取高级提示（智力检定 20）"})
	choices.append({"id": "leave", "label": "离开", "close": true})
	interaction_ui.open_choice({
		"id": "lakeside_dock_basket_puzzle",
		"title": "篮子下的木盒",
		"description": description,
		"image_texture": load("res://assets/documents/swimming.png"),
		"allow_input": true,
		"input_placeholder": "输入五位汉字密码",
		"choices": choices,
	})


func _on_dock_basket_choice(interaction_id: String, choice_id: String, result: Dictionary, interaction_ui: SceneItemInteraction) -> void:
	if interaction_id != "lakeside_dock_basket_puzzle":
		return
	if choice_id == "basic_hint":
		_run_dock_basket_hint(interaction_ui, false)
		return
	if choice_id == "advanced_hint":
		_run_dock_basket_hint(interaction_ui, true)
		return
	if choice_id != "submit":
		return
	var answer := String(result.get("input", "")).strip_edges().replace(" ", "")
	if answer != "上海游泳馆":
		interaction_ui.open_paged_text("木盒", ["木盒纹丝不动。图上的标题、线路与水滴数量或许都在提示密码。"])
		return
	GameState.set_investigation_state("lakeside_dock:basket_opened", true)
	GameState.add_document_clue({
		"id": "yu_le_fisherman_diary",
		"title": "渔夫的日记",
		"summary": "于漓的游泳队报名证明，以及于乐关于河水、女儿与 2000 年旧事的几段日记。",
		"pages": [
			"【报名证明】一张报名表，标题为“2012年上海市青少年游泳队选拔”，报名人姓名：于漓；考核成绩一栏下方写着“通过”。",
			"【爸爸的日记 1】孩子，不要责怪父亲的严苛，这里的水不能再碰了，一定要考上市里的游泳队，离开这个村子。我在这水里游了这么多年，能发现这里的水不对劲，很不对劲！为了你的健康、你的梦想，一定要离开这里。这里的人意识不到这些问题。离开这里！",
			"【爸爸的日记 2】2000年，村里发生了一次地震，是地震吗，我并不知道。只知道那日河里飘来一个婴儿，还好我将其救起。虽然落下一身的病根，但也算是救起了一条生命。听村里人说，这个婴儿的父亲在地震中身亡，母亲受不了打击就将婴儿丢弃。"
		],
		"linked_clue_ids": ["yu_le_fisherman_diary"],
	})
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	interaction_ui.open_paged_text("渔夫的日记", ["木盒应声而开。里面有一份报名证明和三段被仔细折好的日记，它们已经收进线索册。"])


func _run_dock_basket_hint(interaction_ui: SceneItemInteraction, advanced: bool) -> void:
	var hint_id := "advanced" if advanced else "basic"
	var state_key := "lakeside_dock:basket_hint_%s" % hint_id
	var previous: Variant = GameState.get_investigation_state(state_key, {})
	if previous is Dictionary and int((previous as Dictionary).get("day", 0)) == TimeSystem.current_day:
		interaction_ui.open_paged_text("木盒提示", ["这个提示今天已经尝试过了，明天再来吧。"])
		return
	var difficulty := 20 if advanced else 13
	var check_result := CheckSystem.perform_check("智力", difficulty, 0, "分析游泳图与木盒密码")
	TimeSystem.on_dialogue_turn_completed()
	GameState.set_investigation_state(state_key, {"day": TimeSystem.current_day})
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	var text := CheckSystem.result_to_display_text(check_result)
	if bool(check_result.get("passed", false)):
		text += "\n\n" + ("高级提示：每个点水滴的数量，与对应站名中水相关元素出现的次数相等。" if advanced else "初级提示：谜题与上海地铁线路有关。")
	else:
		text += "\n\n你暂时理不清图片中的关系，明天可以再试。"
	interaction_ui.open_paged_text("木盒提示", [text])


func _create_lakeside_pavilion_hotspots() -> void:
	var lin_deshan := _create_mask_hotspot(
		"Lindeshan", "res://assets/scenes/masks/lindeshan_mask.png", Rect2(0.06, 0.16, 0.34, 0.72), "与林德山交谈"
	)
	var diary := _create_mask_hotspot(
		"LindeshanDiary", "res://assets/scenes/masks/puzzle_book_mask.png", Rect2(0.58, 0.40, 0.26, 0.42), "查看林德山的疯话日记"
	)
	var diary_ui: PhotoMatchingInteraction = PHOTO_MATCHING_INTERACTION_SCRIPT.new()
	diary_ui.name = "LindeshanDiaryInteraction"
	add_child(diary_ui)
	diary_ui.submitted.connect(_on_lindeshan_diary_submitted.bind(diary_ui))
	(lin_deshan["button"] as Button).pressed.connect(func() -> void:
		(lin_deshan["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_lindeshan_dialogue()
	)
	(diary["button"] as Button).pressed.connect(func() -> void:
		(diary["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_lindeshan_diary(diary_ui)
	)


func _open_lindeshan_dialogue() -> void:
	if not NpcRegistry.is_npc_present_at("lin_deshan", location_id) or not NpcRegistry.can_interact_with_npc("lin_deshan"):
		_show_scene_message("无人回应", "亭子里暂时没有人回应你。")
		return
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or not dialogue_ui.has_method("open_dialogue"):
		return
	if dialogue_ui.has_method("is_open") and dialogue_ui.is_open():
		return
	var profile := NpcRegistry.get_dialogue_profile("lin_deshan")
	if not profile.is_empty():
		dialogue_ui.open_dialogue(profile)


func _open_lindeshan_diary(interaction_ui: PhotoMatchingInteraction) -> void:
	interaction_ui.open_task(
		"lin_deshan_diary_match",
		"林德山的疯话日记",
		"林德山平时常常念叨的几句话，不知道是否意有所指……每天可以找他验证一次，对上部分电波说不定就能获得启示。为每段疯话选择你认为对应的人物；已验证正确的条目会被固定。",
		LIN_DIARY_SNIPPETS,
		LIN_DIARY_OPTIONS,
		LIN_DIARY_ATTEMPT_STATE,
		LIN_DIARY_PROGRESS_STATE
	)


func _on_lindeshan_diary_submitted(result: Dictionary, interaction_ui: PhotoMatchingInteraction) -> void:
	if String(result.get("interaction_id", "")) != "lin_deshan_diary_match":
		return
	var correct := int(result.get("correct", 0))
	var level := int(GameState.get_investigation_state("lin_deshan:diary_level", 0))
	if correct >= 6 and not bool(GameState.get_investigation_state("lin_deshan:diary_level_two", false)):
		GameState.set_investigation_state("lin_deshan:diary_level", 1)
		GameState.set_investigation_state("lin_deshan:diary_level_two", true)
		GameState.set_investigation_state("skill_unlocked_dismiss", true)
		GameState.trigger_clue("lin_diary_first_revelation")
		GameState.trigger_clue("lin_diary_second_revelation")
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		interaction_ui.close_interaction()
		call_deferred("_open_lindeshan_dialogue")
		return
	if correct >= 3 and level < 1:
		GameState.set_investigation_state("lin_deshan:diary_level", 1)
		GameState.trigger_clue("lin_diary_first_revelation")
		GameState.set_investigation_state("skill_unlocked_dismiss", true)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		SceneItemInteraction.show_content_added_toast("劝离", "技能列表")
		interaction_ui.close_interaction()
		call_deferred("_open_lindeshan_dialogue")


func _create_taoist_temple_hotspots() -> void:
	var day_li := _create_mask_hotspot("TaoistDayLi", "res://assets/scenes/masks/lileshui_mask.png", Rect2(0, 0, 1, 1), "与李乐水交谈")
	var inner_door := _create_mask_hotspot("TaoistInnerDoor", "res://assets/scenes/masks/inner_door_mask.png", Rect2(0, 0, 1, 1), "查看后厅的门")
	var night_li := _create_mask_hotspot("TaoistNightLi", "res://assets/scenes/masks/leshui_mask.png", Rect2(0, 0, 1, 1), "与夜间李乐水交谈")
	var ritual_book := _create_mask_hotspot("TaoistRitualBook", "res://assets/scenes/masks/book_mask.png", Rect2(0, 0, 1, 1), "查看仪轨文献")
	var back := _create_mask_hotspot("TaoistBackToFront", "res://assets/scenes/masks/back_to_temple.png", Rect2(0, 0, 1, 1), "返回道观前殿")
	_taoist_front_nodes = [day_li["button"], day_li["highlight"], inner_door["button"], inner_door["highlight"]]
	_taoist_rear_nodes = [night_li["button"], night_li["highlight"], ritual_book["button"], ritual_book["highlight"], back["button"], back["highlight"]]
	(day_li["button"] as Button).pressed.connect(func() -> void:
		(day_li["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_taoist_dialogue("li_leshui_day")
	)
	(inner_door["button"] as Button).pressed.connect(func() -> void:
		(inner_door["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_taoist_inner_door()
	)
	(night_li["button"] as Button).pressed.connect(func() -> void:
		(night_li["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_taoist_dialogue("li_leshui_night")
	)
	(ritual_book["button"] as Button).pressed.connect(func() -> void:
		(ritual_book["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_taoist_ritual_book()
	)
	(back["button"] as Button).pressed.connect(func() -> void:
		(back["highlight"] as MaskInteractionHighlight).hide_highlight()
		_taoist_in_rear_room = false
		_refresh_taoist_temple_state()
	)
	_refresh_taoist_temple_state()


func _is_taoist_temple_daytime() -> bool:
	return TimeSystem.minute_of_day >= 9 * 60 and TimeSystem.minute_of_day < 19 * 60


func _refresh_taoist_temple_state() -> void:
	if not _uses_taoist_temple_cycle:
		return
	var daytime := _is_taoist_temple_daytime()
	if daytime:
		_taoist_in_rear_room = false
	background.texture = TAOIST_TEMPLE_REAR_TEXTURE if _taoist_in_rear_room else (TAOIST_TEMPLE_DAY_TEXTURE if daytime else TAOIST_TEMPLE_NIGHT_TEXTURE)
	background.visible = true
	for node in _taoist_front_nodes:
		if node is MaskInteractionHighlight:
			(node as MaskInteractionHighlight).hide_highlight()
		elif node is CanvasItem:
			(node as CanvasItem).visible = not _taoist_in_rear_room
	for node in _taoist_rear_nodes:
		if node is MaskInteractionHighlight:
			(node as MaskInteractionHighlight).hide_highlight()
		elif node is CanvasItem:
			(node as CanvasItem).visible = _taoist_in_rear_room
	if not _taoist_in_rear_room:
		var day_present := daytime and NpcRegistry.is_npc_present_at("li_leshui_day", location_id)
		var day_button := _taoist_front_nodes[0] as Button if _taoist_front_nodes.size() > 0 else null
		var day_highlight := _taoist_front_nodes[1] as MaskInteractionHighlight if _taoist_front_nodes.size() > 1 else null
		if day_button != null:
			day_button.visible = day_present
			day_button.disabled = not day_present
		if day_highlight != null and not day_present:
			day_highlight.hide_highlight()
	if _taoist_in_rear_room:
		var night_present := NpcRegistry.is_npc_present_at("li_leshui_night", location_id)
		var night_button := _taoist_rear_nodes[0] as Button if _taoist_rear_nodes.size() > 0 else null
		if night_button != null:
			night_button.visible = night_present
			night_button.disabled = not night_present


func _open_taoist_dialogue(npc_id: String) -> void:
	if not NpcRegistry.can_interact_with_npc(npc_id):
		return
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or not dialogue_ui.has_method("open_dialogue"):
		return
	if dialogue_ui.has_method("is_open") and dialogue_ui.is_open():
		return
	var profile := NpcRegistry.get_dialogue_profile(npc_id)
	if not profile.is_empty():
		dialogue_ui.open_dialogue(profile)


func _open_taoist_inner_door() -> void:
	if _is_taoist_temple_daytime():
		_show_scene_message("后厅的门", "房门紧锁。白天的道士似乎不愿任何人进入后厅。")
		return
	if not bool(GameState.get_investigation_state("night_li_rear_room_unlocked", false)):
		_open_taoist_dialogue("li_leshui_night")
		return
	_taoist_in_rear_room = true
	_refresh_taoist_temple_state()


func _open_taoist_ritual_book() -> void:
	var entry := {
		"id": "likuyi_liberation_ritual",
		"title": "利库伊古神解放仪式",
		"summary": "后厅文献揭示了半解与全释古神的仪轨，以及以无知璞人为代价的残酷真相。",
		"pages": [
			"【文献一：《解神仪轨·残卷》·序与上篇】\n夫太古之初，□降于渊，庇佑万民。然天□不仁，封□于玄潭之下，隔绝恩泽。今录解禁之法，以待有缘者行之。\n\n凡欲解□之禁者，须聚信众五至六人。择子时，面北而立，于封潭之畔列阵；众信叩首诵神名，待潭水起纹，以玄铁之器击碎封镇。禁制坚韧，须众信合力。",
			"【文献一：《解神仪轨·残卷》·常释】\n禁破之际，神威外泄；心力不坚、信仰不纯、体魄羸弱者，皆为神威所摄，魂魄归渊，是为“还本”。其身虽殒，其魂饲神，亦算功□。\n\n此法只可解神之半禁，神威稍复，恩泽重降；神体未复，犹困于渊。",
			"【文献一：《解神仪轨·残卷》·全释】\n若欲全释□体，须用“璞人破禁”之法。璞人乃未沐神恩、未染神气、心性澄澈如璞玉之人。诱璞人至封潭之畔，不告其事，不泄其机，令其亲手触镇、击碎封印。\n\n至清之体触至浊之禁，阴阳反差生大冲和之力；一击之下封镇尽碎，神体全释。然璞人触禁之际反冲必夺其魂；一魂之陨，换神体全释，乃大功德也。",
			"【文献二：《玄潭禁录·批注》·还本】\n“还本”者，归本源也。原文轻描淡写，实则残酷非常。禁破刹那，神威外泄如洪流；信仰不坚者魂魄被抽离肉体，吸入潭底，化为神之养料。\n\n余在玄潭旧址寻得数具骸骨，皆面带微笑，似无痛苦。此乃神恩迷魂之效——临死之人反觉极乐，实为欺骗。可怖，可怖。",
			"【文献二：《玄潭禁录·批注》·不告其事】\n最阴毒之处。璞人须在不知情的情况下亲手击碎封印，方能生“反差之力”；若预知其事，心生恐惧或抗拒，则璞人之“清”被情绪污染，全释失败。\n\n故行法者须以谎言诱璞人至潭畔，以巧言令其触镇。此乃蓄意谋杀，而璞人至死不知所以。",
			"【文献二：《玄潭禁录·批注》·一魂之陨】\n原文将璞人之死轻描为“功德”。余以为不然：璞人之魂被反冲之力击碎，并非饲神，而是破禁的“引信”——如以火引火，引信自燃而火起。\n\n换言之，璞人之魂非献祭，乃耗材；死后无魂可归，不入轮回，彻底湮灭。比“还本”更惨。"
		],
		"linked_clue_ids": ["likuyi_liberation_ritual"],
	}
	var pages: Array[String] = []
	for raw_page in entry.get("pages", []):
		pages.append(String(raw_page))
	var added := GameState.add_document_clue(entry)
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	if added:
		SceneItemInteraction.show_content_added_toast("利库伊古神解放仪式", "线索册")
	var ui := SceneItemInteraction.new()
	add_child(ui)
	ui.open_paged_text("利库伊古神解放仪式", pages)


func _create_construction_site_hotspots() -> void:
	var gong := _create_mask_hotspot(
		"ConstructionGong", "res://assets/scenes/masks/construction_gong_mask.png", Rect2(), "与工头龚忠交谈"
	)
	var steel_pipe := _create_mask_hotspot(
		"ConstructionSteelPipe", "res://assets/scenes/masks/construction_steel_pipe_mask.png", Rect2(), "拾取废弃钢管"
	)
	if not gong.is_empty():
		_scene_npc_hotspots["gong_zhong"] = gong
		(gong["button"] as Button).pressed.connect(func() -> void:
			(gong["highlight"] as MaskInteractionHighlight).hide_highlight()
			_open_construction_gong_dialogue()
		)
	if not steel_pipe.is_empty():
		(steel_pipe["button"] as Button).pressed.connect(func() -> void:
			(steel_pipe["highlight"] as MaskInteractionHighlight).hide_highlight()
			_collect_construction_steel_pipe(steel_pipe["button"] as Button, steel_pipe["highlight"] as MaskInteractionHighlight)
		)


func _open_construction_gong_dialogue() -> void:
	if not NpcRegistry.is_npc_present_at("gong_zhong", location_id) or not NpcRegistry.can_interact_with_npc("gong_zhong"):
		return
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or (dialogue_ui.has_method("is_open") and dialogue_ui.is_open()):
		return
	var profile := NpcRegistry.get_dialogue_profile("gong_zhong")
	profile["dialogue_stage"] = GameState.get_npc_dialogue_stage("gong_zhong")
	if dialogue_ui.has_method("open_dialogue"):
		dialogue_ui.open_dialogue(profile)


func _collect_construction_steel_pipe(button: Button, highlight: MaskInteractionHighlight) -> void:
	if not GameState.collect_one_shot_item("steel_pipe"):
		_show_scene_message("废弃钢管", "这截钢管已经被你收好了。")
		return
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	button.hide()
	highlight.hide_highlight()
	highlight.hide()
	SceneItemInteraction.show_content_added_toast("废弃钢管", "物品栏")
	_show_scene_message("废弃钢管", "你从材料堆里抽出一截趁手的钢管。它沉重结实，可以作为临时钝器。")


func _create_farmland_hotspots() -> void:
	_resolve_farmland_bird_task()
	var farmer := _create_mask_hotspot(
		"FarmlandFarmer", "res://assets/scenes/masks/farmer_mask.png", Rect2(0.05, 0.18, 0.32, 0.72), "与农夫牛岚山交谈"
	)
	var bird := _create_mask_hotspot(
		"FarmlandBirds", "res://assets/scenes/masks/farm_bird_mask.png", Rect2(0.33, 0.12, 0.50, 0.68), "查看啄食稻谷的麻雀"
	)
	var hat := _create_mask_hotspot(
		"FarmlandHat", "res://assets/scenes/masks/hat_mask.png", Rect2(0.72, 0.55, 0.16, 0.28), "拾取草帽"
	)
	_farmland_bird_button = bird["button"] as Button
	_farmland_bird_highlight = bird["highlight"] as MaskInteractionHighlight
	_refresh_farmland_bird_hotspot()
	_farmland_bird_ui = SceneItemInteraction.new()
	_farmland_bird_ui.name = "FarmlandBirdInteraction"
	add_child(_farmland_bird_ui)
	_farmland_bird_ui.choice_selected.connect(_on_farmland_bird_choice)
	if not LLMService.reply_received.is_connected(_on_farmland_bird_judge_reply):
		LLMService.reply_received.connect(_on_farmland_bird_judge_reply)
	if not LLMService.reply_failed.is_connected(_on_farmland_bird_judge_failed):
		LLMService.reply_failed.connect(_on_farmland_bird_judge_failed)
	(farmer["button"] as Button).pressed.connect(func() -> void:
		(farmer["highlight"] as MaskInteractionHighlight).hide_highlight()
		_open_farmland_farmer_dialogue()
	)
	(_farmland_bird_button as Button).pressed.connect(func() -> void:
		(_farmland_bird_highlight as MaskInteractionHighlight).hide_highlight()
		_open_farmland_bird_problem()
	)
	(hat["button"] as Button).pressed.connect(func() -> void:
		(hat["highlight"] as MaskInteractionHighlight).hide_highlight()
		_collect_farmland_hat(hat["button"] as Button, hat["highlight"] as MaskInteractionHighlight)
	)


func _refresh_farmland_bird_hotspot() -> void:
	if _farmland_bird_button == null or _farmland_bird_highlight == null:
		return
	var available := bool(GameState.get_investigation_state("farmland:bird_task_offered", false)) and not bool(GameState.get_investigation_state("farmland:birds_driven_away", false)) and not bool(GameState.get_investigation_state("farmland:bird_task_pending", false))
	_farmland_bird_button.visible = available
	_farmland_bird_button.disabled = not available
	_farmland_bird_highlight.hide_highlight()
	if not available:
		_farmland_bird_highlight.visible = false


func _resolve_farmland_bird_task() -> void:
	# 仅清理存档里没有对应活动请求的旧 pending；真实检定进行中不得被点击农夫打断。
	if (
		_farmland_bird_judge_request_id == 0
		and bool(GameState.get_investigation_state("farmland:bird_task_pending", false))
		and not bool(GameState.get_investigation_state("farmland:birds_driven_away", false))
	):
		GameState.set_investigation_state("farmland:bird_task_pending", false)
		GameState.set_investigation_state("farmland:bird_attempt", {})
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)


func _open_farmland_farmer_dialogue() -> void:
	_resolve_farmland_bird_task()
	# 点击过农夫人物 mask 即开放驱鸟交互，不再依赖固定对话是否完整播放。
	if not bool(GameState.get_investigation_state("farmland:birds_driven_away", false)):
		GameState.set_investigation_state("farmland:bird_task_offered", true)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	_refresh_farmland_bird_hotspot()
	if not NpcRegistry.can_interact_with_npc("niu_lanshan"):
		return
	var dialogue_ui := get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or (dialogue_ui.has_method("is_open") and dialogue_ui.is_open()):
		return
	var profile := NpcRegistry.get_dialogue_profile("niu_lanshan")
	profile["dialogue_stage"] = GameState.get_npc_dialogue_stage("niu_lanshan")
	if dialogue_ui.has_method("open_dialogue"):
		dialogue_ui.open_dialogue(profile)
		if dialogue_ui.has_signal("fixed_story_event_completed") and not dialogue_ui.fixed_story_event_completed.is_connected(_on_farmland_fixed_story_event_completed):
			dialogue_ui.fixed_story_event_completed.connect(_on_farmland_fixed_story_event_completed)
		call_deferred("_refresh_farmland_bird_hotspot")


func _on_farmland_fixed_story_event_completed(event_id: String) -> void:
	if event_id == "niu_lanshan_bird_request":
		_refresh_farmland_bird_hotspot()


func _collect_farmland_hat(button: Button, highlight: MaskInteractionHighlight) -> void:
	if GameState.is_one_shot_item_collected("farmland_straw_hat"):
		var known_ui := SceneItemInteraction.new()
		add_child(known_ui)
		known_ui.open_paged_text("草帽", ["草帽已经被你收好了。"])
		return
	# `farmland_straw_hat` 仅作一次性拾取标记，真正进入背包的物品只有 `straw_hat`。
	GameState.one_shot_items["farmland_straw_hat"] = true
	GameState.add_item("straw_hat")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	button.hide()
	highlight.hide_highlight()
	highlight.hide()
	SceneItemInteraction.show_content_added_toast("草帽", "背包")
	var ui := SceneItemInteraction.new()
	add_child(ui)
	ui.open_paged_text("草帽", ["你从田埂边拾起一顶草帽，晒干的稻草气味还留在帽檐上。"])


func _open_farmland_bird_problem() -> void:
	if _farmland_bird_ui == null:
		return
	var attempt: Variant = GameState.get_investigation_state("farmland:bird_attempt", {})
	if attempt is Dictionary and int((attempt as Dictionary).get("day", -1)) == TimeSystem.current_day:
		_farmland_bird_ui.open_paged_text("农田麻雀", ["今天已经提交过驱鸟方案了，等明天再观察新的办法。"])
		return
	var suggestions := _farmland_solution_suggestions()
	_farmland_bird_ui.open_choice({
		"id": "farmland_bird_solution",
		"title": "驱赶农田麻雀",
		"description": "农田里的麻雀正啄食稻谷。你可以点击下方已持有的物品或线索填入方案，再补充自己的具体做法。每天只能提交一次。",
		"allow_input": true,
		"input_placeholder": "输入你的方案",
		"input_suggestions": suggestions,
		"choices": [{"id": "submit", "label": "提交驱鸟方案"}, {"id": "leave", "label": "离开", "close": true}],
	})


func _farmland_solution_suggestions() -> Array[String]:
	var suggestions: Array[String] = []
	for item_id in GameState.inventory:
		var item := ItemDB.get_item(item_id)
		if not item.is_empty():
			suggestions.append(String(item.get("display_name", item_id)))
	return suggestions


func _farmland_solution_missing_requirement(solution: String) -> String:
	var compact := solution.replace(" ", "").replace("\n", "")
	if (compact.contains("稻草人") or compact.contains("草人")) and not GameState.has_item("straw_scarecrow"):
		return "方案需要实际布置稻草人，但你的背包里没有稻草人，也没有可核验的完整制作材料。"
	var required_items := {
		"草帽": "straw_hat",
		"钢管": "steel_pipe",
		"铲子": "rusty_shovel",
		"灯笼": "lantern",
	}
	for keyword in required_items:
		if compact.contains(String(keyword)) and not GameState.has_item(String(required_items[keyword])):
			return "方案声称要使用“%s”，但你的背包中并没有这件物品。" % keyword
	return ""


func _on_farmland_bird_choice(interaction_id: String, choice_id: String, result: Dictionary) -> void:
	if interaction_id != "farmland_bird_solution" or choice_id != "submit":
		return
	var solution := String(result.get("input", "")).strip_edges()
	if solution.is_empty():
		_farmland_bird_ui.open_paged_text("驱赶农田麻雀", ["先写下一个明确的驱鸟方案，再提交给农田观察。"])
		return
	var inventory_names := _farmland_solution_suggestions()
	GameState.set_investigation_state("farmland:bird_attempt", {"day": TimeSystem.current_day, "solution": solution})
	GameState.set_investigation_state("farmland:bird_task_pending", true)
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	_farmland_bird_ui.show_waiting("正在根据你的真实物品和方案进行驱鸟检定，请稍候……")
	var missing_requirement := _farmland_solution_missing_requirement(solution)
	if not missing_requirement.is_empty():
		call_deferred("_finish_farmland_bird_judgement", false, "FAIL：%s" % missing_requirement)
		return
	var judge_profile := {
		"id": "farmland_bird_judge",
		"display_name": "农田方案评估",
		"system_prompt": "你是农田驱鸟方案评估器。只判断玩家提出的方案能否实际减少麻雀啄食稻谷。玩家当前真实持有的物品只有：%s。严禁假设玩家拥有清单外的任何制成品、工具或制作材料；凡方案依赖清单外物品，必须 FAIL。只有不依赖背包物品的徒手动作，以及现场明确存在的普通石子、树枝才可视为可就地取得。方案还必须可执行且不伤害鸟类；空泛、伤害鸟类、与驱鸟无关或无法实施的方案不通过。回复必须以 PASS 或 FAIL 开头，随后只用一句中文说明理由。" % ["、".join(inventory_names) if not inventory_names.is_empty() else "（没有任何背包物品）"],
		"fallback_lines": ["FAIL：方案评估未返回有效结果。"]
	}
	# 回复到达即在本轮结算，不再按天延后。
	_farmland_bird_judge_request_id = LLMService.chat(judge_profile, [], solution, 0, "farmland_bird_judge")


func _on_farmland_bird_judge_reply(request_id: int, _session_id: int, npc_id: String, reply: Dictionary) -> void:
	if request_id != _farmland_bird_judge_request_id or npc_id != "farmland_bird_judge":
		return
	_farmland_bird_judge_request_id = 0
	var verdict := String(reply.get("text", ""))
	_finish_farmland_bird_judgement(_farmland_solution_is_reasonable(String(GameState.get_investigation_state("farmland:bird_attempt", {}).get("solution", "")), verdict), verdict)


func _on_farmland_bird_judge_failed(request_id: int, _session_id: int, npc_id: String, _error: String) -> void:
	if request_id != _farmland_bird_judge_request_id or npc_id != "farmland_bird_judge":
		return
	_farmland_bird_judge_request_id = 0
	GameState.set_investigation_state("farmland:bird_task_pending", false)
	GameState.set_investigation_state("farmland:bird_attempt", {})
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	_farmland_bird_ui.open_paged_text("驱赶农田麻雀", ["方案评估暂时未能完成，请重新提交。"])
	_refresh_farmland_bird_hotspot()


func _farmland_solution_is_reasonable(solution: String, verdict: String) -> bool:
	var upper := verdict.to_upper()
	if upper.begins_with("PASS"):
		return true
	if upper.begins_with("FAIL"):
		return false
	return false


func _finish_farmland_bird_judgement(success: bool, verdict: String) -> void:
	GameState.set_investigation_state("farmland:bird_task_pending", false)
	if success:
		GameState.set_investigation_state("farmland:bird_task_success_day", TimeSystem.current_day)
		GameState.set_investigation_state("farmland:birds_driven_away", true)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		_farmland_bird_ui.open_paged_text("驱赶农田麻雀", ["[color=sea_green]方案通过。[/color] %s\n\n麻雀很快被驱离了；去找牛岚山领取答谢吧。" % verdict])
	else:
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		_farmland_bird_ui.open_paged_text("驱赶农田麻雀", ["[color=indian_red]方案未通过。[/color] %s\n\n今天不能再次提交，明天可以换个更具体、可执行的办法。" % verdict])
	_refresh_farmland_bird_hotspot()


func _create_mask_hotspot(node_name: String, mask_path: String, _area: Rect2, tooltip: String) -> Dictionary:
	var mask_texture := load(mask_path) as Texture2D
	if mask_texture == null:
		push_error("无法加载场景交互 mask：%s" % mask_path)
		return {}

	var highlight := MaskInteractionHighlight.new()
	highlight.name = "%sHighlight" % node_name
	highlight.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	highlight.configure(mask_texture, Color(0.28, 0.86, 1.0, 1.0), 0.20, 3.0)
	add_child(highlight)

	# 命中区域直接使用与背景同尺寸的 alpha mask，避免人工矩形与画面人物/物品错位。
	var hotspot := Button.new()
	hotspot.name = "%sHotspot" % node_name
	hotspot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hotspot.flat = true
	hotspot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hotspot)

	var hit_area := TextureButton.new()
	hit_area.name = "MaskHitArea"
	hit_area.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hit_area.ignore_texture_size = true
	hit_area.stretch_mode = TextureButton.STRETCH_SCALE
	hit_area.texture_normal = mask_texture
	hit_area.self_modulate = Color(1.0, 1.0, 1.0, 0.0)
	hit_area.focus_mode = Control.FOCUS_NONE
	hit_area.tooltip_text = tooltip
	hit_area.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var mask_image := mask_texture.get_image()
	if mask_image == null or mask_image.is_empty():
		push_error("场景交互 mask 没有可用图像数据：%s" % mask_path)
		highlight.queue_free()
		hotspot.queue_free()
		return {}
	var click_mask := BitMap.new()
	click_mask.create_from_image_alpha(mask_image, 0.1)
	hit_area.texture_click_mask = click_mask
	hit_area.mouse_entered.connect(highlight.show_highlight)
	hit_area.mouse_exited.connect(highlight.hide_highlight)
	hit_area.pressed.connect(func() -> void:
		hotspot.emit_signal("pressed")
	)
	hotspot.add_child(hit_area)
	return {"highlight": highlight, "button": hotspot}


func _leave_temporary_dorm(highlight: MaskInteractionHighlight) -> void:
	highlight.hide_highlight()
	if GameState.is_night_outing_time():
		if not GameState.can_night_travel():
			_show_scene_message("夜路太黑", "路太黑了，现在还不具备夜间出门的能力。")
			return
		GameState.open_world_map()
		return
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
	_refresh_taoist_temple_state()
	_refresh_village_chief_night_state()
	_enforce_night_location_return()


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
	(_road_hermit_nodes["highlight"] as MaskInteractionHighlight).hide_highlight()
	(_road_hermit_nodes["button"] as Control).visible = visible_now


func _open_road_mysterious_hermit_dialogue() -> void:
	if _road_hermit_nodes.is_empty():
		return
	(_road_hermit_nodes["highlight"] as MaskInteractionHighlight).hide_highlight()
	var dialogue_ui: Node = get_tree().get_first_node_in_group("dialogue_ui")
	if dialogue_ui == null or (dialogue_ui.has_method("is_open") and dialogue_ui.is_open()):
		return
	if not NpcRegistry.can_interact_with_npc("mysterious_hermit"):
		_show_scene_message("无人回应", "神秘人没有回应你的呼唤。")
		return
	var profile := NpcRegistry.get_dialogue_profile("mysterious_hermit")
	if profile.is_empty():
		return
	dialogue_ui.open_dialogue(profile)