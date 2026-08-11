extends CanvasLayer
## 公聊调度桥接层。
## GroupChatCoordinator 负责串行请求，DialogueUI 负责输入、历史、逐字回复和表情立绘。

var _coordinator: Node = null
var _dialogue_ui: Node = null
var _coordinator_connected := false
var _dialogue_connected := false


func _ready() -> void:
	layer = 12
	$RootPanel.visible = false


func set_coordinator(coordinator: Node) -> void:
	if coordinator == null:
		return
	if _coordinator == coordinator and _coordinator_connected:
		return
	_coordinator = coordinator
	_coordinator.round_completed.connect(_on_round_completed)
	_coordinator.session_ended.connect(_on_session_ended)
	_coordinator.npc_turn_started.connect(_on_npc_turn_started)
	_coordinator.npc_speech_chunk.connect(_on_npc_speech_chunk)
	_coordinator.npc_silent.connect(_on_npc_silent)
	_coordinator.npc_spoke.connect(_on_npc_spoke)
	_coordinator_connected = true


func open(loc_id: String, npc_ids: Array[String]) -> void:
	if _coordinator == null or not _coordinator.start_session(loc_id, npc_ids):
		return
	if not _ensure_dialogue_bridge() or not _dialogue_ui.open_group_chat(npc_ids):
		_coordinator._end_session("ui_unavailable")


func _ensure_dialogue_bridge() -> bool:
	if not is_instance_valid(_dialogue_ui):
		_dialogue_ui = get_tree().get_first_node_in_group("dialogue_ui")
	if _dialogue_ui == null:
		return false
	if not _dialogue_connected:
		_dialogue_ui.group_message_submitted.connect(_on_dialogue_group_message)
		_dialogue_ui.group_close_requested.connect(_on_dialogue_group_close_requested)
		_dialogue_connected = true
	return true


func _on_dialogue_group_message(text: String) -> void:
	if _coordinator != null and _coordinator.is_active():
		_coordinator.submit_player_message(text)


func _on_dialogue_group_close_requested() -> void:
	if _coordinator != null and _coordinator.is_active():
		_coordinator._end_session("player_ended")


func _on_npc_turn_started(npc_id: String) -> void:
	if is_instance_valid(_dialogue_ui):
		_dialogue_ui.begin_group_npc_turn(npc_id)


func _on_npc_speech_chunk(npc_id: String, accumulated_text: String) -> void:
	if is_instance_valid(_dialogue_ui):
		_dialogue_ui.update_group_npc_speech(npc_id, accumulated_text)


func _on_npc_silent(npc_id: String) -> void:
	if is_instance_valid(_dialogue_ui):
		_dialogue_ui.discard_group_npc_stream(npc_id)


func _on_npc_spoke(npc_id: String, text: String, _round: int, mood: String) -> void:
	if is_instance_valid(_dialogue_ui):
		_dialogue_ui.append_group_npc_speech(npc_id, text, mood)


func _on_round_completed(_round: int) -> void:
	if is_instance_valid(_dialogue_ui):
		_dialogue_ui.complete_group_round()


func _on_session_ended(reason: String) -> void:
	if is_instance_valid(_dialogue_ui):
		_dialogue_ui.finish_group_chat(reason)


func is_ui_open() -> bool:
	return is_instance_valid(_dialogue_ui) and _dialogue_ui.is_open()


func close_top_ui() -> void:
	if is_instance_valid(_dialogue_ui) and _dialogue_ui.is_open():
		_dialogue_ui.close_dialogue()
