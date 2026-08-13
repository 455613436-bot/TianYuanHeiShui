extends Control
## 地图地点的共享占位场景。后续可用真正的探索场景替换各地点文件。

const MAP_SCENE := "res://scenes/map/WorldMap.tscn"

@export var location_number: String = "?"
@export var location_name: String = "未命名地点"
## 该地点在 locations.json 里的 id；留空则由 NpcSpawner 按 scene path 反查
@export var location_id: String = ""
@export_multiline var location_description: String = "该地点仍在建设中。"
@export var background_texture: Texture2D
## 同一地点的第二个视角；设置后会自动生成场景切换按键。
@export var alternate_background_texture: Texture2D
@export var alternate_view_label: String = "切换至后方"
@export var accent_color: Color = Color(0.45, 0.58, 0.36)

var _showing_alternate_view := false
var _view_toggle_button: Button
var _uses_time_based_background := false

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
	if _uses_time_based_background:
		TimeSystem.minute_changed.connect(_on_time_changed)
		_refresh_time_based_background()
	elif alternate_background_texture != null:
		_create_view_toggle_button()
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
		_create_clinic_door_hotspot()
	elif location_id == "village_committee":
		_create_factory_notice_hotspot()
	elif location_id == "temporary_dorm":
		_create_temporary_dorm_hotspots()
		call_deferred("_start_dorm_tutorial_if_needed")
	call_deferred("_apply_responsive_layout")


func _on_item_added(item_id: String) -> void:
	if item_id == GameState.VILLAGE_MAP_ITEM_ID:
		_refresh_map_access()


func _refresh_map_access() -> void:
	var unlocked := GameState.can_open_world_map()
	return_button.disabled = not unlocked
	return_button.tooltip_text = "打开地图" if unlocked else "先向村长询问并取得村庄手绘地图"
	return_button.text = "打开地图  M / Esc" if unlocked else "地图尚未解锁"


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
	hotspot.pressed.connect(func() -> void:
		mask.hide_highlight()
		interaction_ui.open_choice({
			"id": "abandoned_clinic_door_lock",
			"title": "诊所大门",
			"description": "这是一个摇摇欲坠的锁。锈蚀的锁芯仍勉强卡住门闩。",
			"choices": [
				{
					"id": "pry_lock",
					"label": "撬锁（敏捷检定）",
					"type": "check",
					"attribute": "敏捷",
					"difficulty": 12,
					"reason": "尝试撬开废弃诊所大门的锁",
					"success_text": "锁芯发出一声轻响，门闩松开了。",
					"failure_text": "铁片从锁眼滑开，锈蚀的锁仍纹丝不动。",
				},
				{"id": "leave", "label": "离开", "close": true},
			],
		})
	)


func _create_factory_notice_hotspot() -> void:
	var highlight := MaskInteractionHighlight.new()
	highlight.name = "FactoryNoticeHighlight"
	highlight.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	highlight.configure(
		load("res://assets/scenes/masks/factory_notice_mask.png"),
		Color(0.28, 0.86, 1.0, 1.0),
		0.20,
		3.0
	)
	add_child(highlight)

	var hotspot := Button.new()
	hotspot.name = "FactoryNoticeHotspot"
	hotspot.anchor_left = 0.265
	hotspot.anchor_top = 0.135
	hotspot.anchor_right = 0.445
	hotspot.anchor_bottom = 0.225
	hotspot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hotspot.tooltip_text = "工厂撤出通知"
	hotspot.flat = true
	hotspot.mouse_entered.connect(func() -> void:
		highlight.show_highlight()
	)
	hotspot.mouse_exited.connect(func() -> void:
		highlight.hide_highlight()
	)
	add_child(hotspot)

	var interaction_ui := SceneItemInteraction.new()
	interaction_ui.name = "FactoryNoticeInteraction"
	add_child(interaction_ui)
	hotspot.pressed.connect(func() -> void:
		highlight.hide_highlight()
		interaction_ui.open_document(
			"甘艾工业园区撤出计划",
			load("res://assets/documents/notice.png"),
			{
				"id": "factory_withdrawal_notice",
				"title": "甘艾工业园区撤出计划",
				"summary": "村委处未贴出的公示，写着甘艾工厂早已撤出的消息。",
				"image_path": "res://assets/documents/notice.png",
			}
		)
	)


func _start_dorm_tutorial_if_needed() -> void:
	const TUTORIAL_STATE_ID := "onboarding:temporary_dorm_tutorial"
	if bool(GameState.get_investigation_state(TUTORIAL_STATE_ID, false)):
		return
	var tutorial_pages: Array[String] = [
		"欢迎来到思源村。你会从临时宿舍开始每一天的调查：前往地图上的地点、与村民交谈并观察环境，逐步拼出事件的真相。",
		"完成本指引后，这份教程会被收录在右侧的线索册中，方便你随时重看。",
		"点击场景中高亮人物或物品可以进行交互。与村民对话时，可以直接打字，也可以打开背包附带物品并说明用途。",
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
	var npc_ids := NpcRegistry.get_npcs_at(loc_id)
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
	background.texture = alternate_background_texture if _showing_alternate_view else background_texture
	if is_instance_valid(_view_toggle_button):
		_view_toggle_button.text = "切换至前方" if _showing_alternate_view else alternate_view_label


func _on_time_changed(_day: int, _minute_of_day: int) -> void:
	_refresh_time_based_background()


func _refresh_time_based_background() -> void:
	if not _uses_time_based_background:
		return
	# 临时宿舍在 19:00（含）后显示夜景，其余时间显示日景；两张图尺寸相同，遮罩坐标无需变动。
	var is_night := TimeSystem.minute_of_day >= 19 * 60
	background.texture = alternate_background_texture if is_night else background_texture
	background.visible = background.texture != null


func _open_map() -> void:
	InputManager.request_open_map()
