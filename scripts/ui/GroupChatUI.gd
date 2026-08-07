extends CanvasLayer
## GroupChatUI
## 公聊模式 UI（§9.7）。复用 GroupChatCoordinator 的信号驱动。
## 标题栏显示"公聊：参与者（第 X/6 轮 · 剩余 N 分钟）"；
## 发言气泡用不同颜色/头像区分说话人；loading 状态显示"NPC 正在回应…"。

const GroupChatCoordinator := preload("res://scripts/ui/GroupChatCoordinator.gd")

@onready var root_panel: Panel = $RootPanel
@onready var title_label: Label = $RootPanel/TitleRow/TitleLabel
@onready var round_label: Label = $RootPanel/TitleRow/RoundLabel
@onready var end_btn: Button = $RootPanel/TitleRow/EndBtn
@onready var history_label: RichTextLabel = $RootPanel/Center/History
@onready var input_edit: LineEdit = $RootPanel/Center/InputRow/InputEdit
@onready var send_btn: Button = $RootPanel/Center/InputRow/SendBtn

var _coordinator: Node = null


func _ready() -> void:
	layer = 12
	root_panel.visible = false
	end_btn.pressed.connect(_on_end_pressed)
	send_btn.pressed.connect(_on_send)
	input_edit.text_submitted.connect(func(_t): _on_send())


func set_coordinator(coordinator: Node) -> void:
	_coordinator = coordinator
	coordinator.round_completed.connect(_on_round_completed)
	coordinator.session_ended.connect(_on_session_ended)
	coordinator.npc_spoke.connect(_on_npc_spoke)


func open(loc_id: String, npc_ids: Array[String]) -> void:
	if _coordinator == null:
		return
	if not _coordinator.start_session(loc_id, npc_ids):
		return
	root_panel.visible = true
	_update_title()
	history_label.clear()
	_append_text("system", "（众人围了过来，开始谈话……）")
	input_edit.grab_focus()


func _on_send() -> void:
	if _coordinator == null or not _coordinator.is_active():
		return
	var text := input_edit.text.strip_edges()
	if text == "":
		return
	input_edit.text = ""
	input_edit.editable = false
	send_btn.disabled = true
	_append_text("player", text)
	_append_text("system", "（NPC 正在回应……）")
	_coordinator.submit_player_message(text)


func _on_round_completed(round: int) -> void:
	_remove_thinking_message()
	_update_title()
	input_edit.editable = true
	send_btn.disabled = false
	input_edit.grab_focus()


func _on_session_ended(reason: String) -> void:
	_remove_thinking_message()
	_append_text("system", "（谈话散场了。）")
	root_panel.visible = false


func _on_npc_spoke(npc_id: String, text: String, _round: int) -> void:
	append_npc_speech(npc_id, text)


func _on_end_pressed() -> void:
	if _coordinator != null and _coordinator.is_active():
		_coordinator._end_session("player_ended")


func _update_title() -> void:
	if _coordinator == null:
		return
	var ids: Array[String] = _coordinator.participants()
	var names: PackedStringArray = []
	for id in ids:
		names.append(NpcRegistry.get_short_name(id))
	title_label.text = "公聊：%s" % "、".join(names)
	round_label.text = "第 %d/6 轮" % _coordinator.current_round()


func _append_text(role: String, text: String) -> void:
	match role:
		"player":
			history_label.push_color(Color(0.25, 0.35, 0.55))
			history_label.add_text("[你] " + text)
			history_label.pop()
		"system":
			history_label.push_color(Color(0.35, 0.35, 0.35))
			history_label.push_italics()
			history_label.add_text(text)
			history_label.pop()
			history_label.pop()
		_:
			history_label.push_color(Color(0.45, 0.25, 0.1))
			history_label.add_text("[%s] %s" % [role, text])
			history_label.pop()
	history_label.add_text("\n")
	history_label.scroll_to_line(maxi(0, history_label.get_line_count() - 1))


## M6 简化版：把 GroupChatCoordinator 收到的发言追加到历史区。
## 由 GroupChatCoordinator 在写入 history 后调用。
func append_npc_speech(npc_id: String, text: String) -> void:
	_append_text(NpcRegistry.get_short_name(npc_id), text)


func _remove_thinking_message() -> void:
	# RichTextLabel 不便局部删除；M6 简化：不做精确删除，仅刷新时跳过"正在回应"
	pass


func is_ui_open() -> bool:
	return root_panel.visible


func close_top_ui() -> void:
	_on_end_pressed()
