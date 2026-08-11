extends CanvasLayer
## NpcPresenceBar
## 场景 HUD 顶部横条：显示"这里还有谁"。
## - 点击某个 NPC 头像 = 切换私聊对象（关闭当前对话、开新对象的私聊）
## - 右侧提供消磨时间入口；公共聊天入口暂时停用。
##
## 挂载：作为 Main.tscn / LocationBase.tscn 的子节点（CanvasLayer, layer=8）

signal npc_selected(npc_id: String)
signal group_chat_requested()

const NPC_SCRIPT := preload("res://scripts/entities/NpcInteractable.gd")

@onready var bar_panel: Panel = $BarPanel
@onready var presence_scroll: ScrollContainer = $BarPanel/Scroll
@onready var presence_container: HBoxContainer = $BarPanel/Scroll/PresenceRow
@onready var group_chat_btn: Button = $BarPanel/GroupChatBtn
@onready var clock_label: Label = $ClockLabel

## 当前地点 id；留空则按 scene path 反查
var location_id: String = ""
var _current_npc_buttons: Dictionary = {} # npc_id -> Button
var _time_popup: PopupPanel
var _target_hour: SpinBox
var _target_minute: SpinBox
var _time_hint_label: Label
var _advance_button: Button
var _popup_clock_label: Label


func _ready() -> void:
	layer = 8
	# 暂时将原公聊入口替换为时间管理入口，不再发出 group_chat_requested。
	group_chat_btn.visible = true
	group_chat_btn.disabled = false
	group_chat_btn.text = "消磨时间"
	group_chat_btn.tooltip_text = "消磨至当天较晚时刻，或休息到次日 09:00"
	group_chat_btn.offset_left = -136.0
	presence_scroll.offset_right = -144.0
	group_chat_btn.pressed.connect(_open_time_pass_popup)
	# 时钟刷新
	TimeSystem.minute_changed.connect(func(_d, _m): _update_clock())
	_update_clock()
	call_deferred("_refresh")


func get_location_id() -> String:
	if location_id != "":
		return location_id
	var scene := get_tree().current_scene
	if scene == null:
		return ""
	return NpcRegistry.location_id_for_scene(String(scene.scene_file_path))


func _process(_delta: float) -> void:
	# 用一个简单的脏标记：若 NPC 列表与固定地点配置不符就刷新。
	var loc_id := get_location_id()
	if loc_id == "":
		return
	var actual := NpcRegistry.get_npcs_at(loc_id).size()
	if actual != _current_npc_buttons.size():
		call_deferred("_refresh")


func _update_clock() -> void:
	if clock_label != null:
		clock_label.text = TimeSystem.format_clock()
	if is_instance_valid(_popup_clock_label):
		_popup_clock_label.text = "当前时间：%s" % TimeSystem.format_clock()
	if is_instance_valid(_time_popup) and _time_popup.visible:
		_update_time_target_state()


func _open_time_pass_popup() -> void:
	_ensure_time_pass_popup()
	_seed_time_target()
	_time_popup.popup_centered(Vector2i(420, 270))


func _ensure_time_pass_popup() -> void:
	if is_instance_valid(_time_popup):
		return
	_time_popup = PopupPanel.new()
	_time_popup.name = "TimePassPopup"
	_time_popup.exclusive = true
	# PopupPanel 是 Window，不支持 Control.custom_minimum_size；显示时由 popup_centered 指定尺寸。
	add_child(_time_popup)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	_time_popup.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)

	var title := Label.new()
	title.text = "消磨时间"
	title.add_theme_font_size_override("font_size", 22)
	content.add_child(title)

	_popup_clock_label = Label.new()
	_popup_clock_label.add_theme_color_override("font_color", Color(0.78, 0.76, 0.68))
	content.add_child(_popup_clock_label)

	var target_label := Label.new()
	target_label.text = "消磨至今天"
	content.add_child(target_label)

	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 8)
	content.add_child(time_row)
	_target_hour = _create_time_spin_box(23.0)
	time_row.add_child(_target_hour)
	var hour_label := Label.new()
	hour_label.text = "时"
	time_row.add_child(hour_label)
	_target_minute = _create_time_spin_box(59.0)
	time_row.add_child(_target_minute)
	var minute_label := Label.new()
	minute_label.text = "分"
	time_row.add_child(minute_label)

	_time_hint_label = Label.new()
	_time_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_time_hint_label.add_theme_color_override("font_color", Color(0.9, 0.78, 0.42))
	content.add_child(_time_hint_label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	content.add_child(buttons)
	var rest_button := Button.new()
	rest_button.text = "休息至次日 09:00"
	rest_button.tooltip_text = "直接推进至下一天上午九点"
	rest_button.pressed.connect(_rest_until_next_day)
	buttons.add_child(rest_button)
	_advance_button = Button.new()
	_advance_button.text = "确认消磨"
	_advance_button.pressed.connect(_confirm_advance_to_today)
	buttons.add_child(_advance_button)
	var cancel_button := Button.new()
	cancel_button.text = "取消"
	cancel_button.pressed.connect(func(): _time_popup.hide())
	buttons.add_child(cancel_button)

	_target_hour.value_changed.connect(func(_value: float): _update_time_target_state())
	_target_minute.value_changed.connect(func(_value: float): _update_time_target_state())


func _create_time_spin_box(max_value: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = 0.0
	spin.max_value = max_value
	spin.step = 1.0
	spin.rounded = true
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.custom_minimum_size = Vector2(82, 34)
	return spin


func _seed_time_target() -> void:
	var target := mini(TimeSystem.minute_of_day + 60, TimeSystem.MINUTES_PER_DAY - 1)
	_target_hour.value = target / 60
	_target_minute.value = target % 60
	_update_time_target_state()


func _update_time_target_state() -> void:
	if not is_instance_valid(_target_hour) or not is_instance_valid(_target_minute):
		return
	var target := int(_target_hour.value) * 60 + int(_target_minute.value)
	var delta := target - TimeSystem.minute_of_day
	_popup_clock_label.text = "当前时间：%s" % TimeSystem.format_clock()
	_advance_button.disabled = delta <= 0
	if delta <= 0:
		_time_hint_label.text = "只能选择今天晚于当前时刻的时间。"
		return
	_time_hint_label.text = "将消磨 %d 小时 %d 分钟，至今天 %02d:%02d。" % [delta / 60, delta % 60, target / 60, target % 60]


func _confirm_advance_to_today() -> void:
	var target := int(_target_hour.value) * 60 + int(_target_minute.value)
	if TimeSystem.advance_to_today(target):
		_time_popup.hide()
	else:
		_update_time_target_state()


func _rest_until_next_day() -> void:
	if GameState.rest_at_location(get_location_id()):
		_time_popup.hide()
	else:
		_time_hint_label.text = "请先回临时宿舍休息。"


## 外部可主动调（场景 _ready 后、对话关闭后）
func _refresh() -> void:
	for child in presence_container.get_children():
		child.queue_free()
	_current_npc_buttons.clear()
	var loc_id := get_location_id()
	if loc_id == "":
		bar_panel.visible = false
		return
	bar_panel.visible = true
	var npc_ids := NpcRegistry.get_npcs_at(loc_id)
	for npc_id in npc_ids:
		var btn := Button.new()
		btn.text = NpcRegistry.get_short_name(npc_id)
		btn.tooltip_text = "与 %s 私聊" % NpcRegistry.get_display_name(npc_id)
		btn.custom_minimum_size = Vector2(96, 36)
		btn.add_theme_font_size_override("font_size", 16)
		btn.pressed.connect(func(): npc_selected.emit(npc_id))
		presence_container.add_child(btn)
		_current_npc_buttons[npc_id] = btn
	# 公聊暂时停用；该位置固定提供消磨时间入口，不受在场 NPC 数量影响。
	group_chat_btn.visible = true
	group_chat_btn.disabled = false


## 当前地点 NPC 数量
func npc_count() -> int:
	var loc_id := get_location_id()
	if loc_id == "":
		return 0
	return NpcRegistry.get_npcs_at(loc_id).size()
