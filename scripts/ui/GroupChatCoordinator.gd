extends Node
## GroupChatCoordinator
## 公聊按固定顺序串行请求 NPC：后一个 NPC 会看到本轮前序 NPC 的发言，
## 并通过 LLMService 的 reply_chunk 信号逐字推送到复用的 DialogueUI。

signal round_completed(round: int)
signal session_ended(reason: String)
signal npc_turn_started(npc_id: String)
signal npc_speech_chunk(npc_id: String, accumulated_text: String)
signal npc_silent(npc_id: String)
signal npc_spoke(npc_id: String, text: String, round: int, mood: String)

const MAX_ROUNDS := 6
const MAX_TIME_MINUTES := 30
const LLM_TIMEOUT_SEC := 90.0

var _active := false
var _loc_id := ""
var _participant_ids: Array[String] = []
var _round := 0
## [{sender:"player"|npc_id, text:String, round:int}]
var _buffer: Array = []
var _start_total_minutes := 0

## 当前轮次按顺序待处理的 NPC；每次只保留一个 LLM 请求在途。
var _speaker_queue: Array[String] = []
var _active_request_id := 0
var _active_npc_id := ""
var _current_player_text := ""
var _timeout_timer: SceneTreeTimer = null


func _ready() -> void:
	LLMService.reply_received.connect(_on_llm_reply)
	LLMService.reply_failed.connect(_on_llm_failed)
	LLMService.reply_chunk.connect(_on_llm_chunk)


func start_session(loc_id: String, npc_ids: Array[String]) -> bool:
	if _active or loc_id == "" or npc_ids.size() < 2:
		return false
	_active = true
	_loc_id = loc_id
	_participant_ids = npc_ids.duplicate()
	_round = 0
	_start_total_minutes = TimeSystem.total_minutes()
	_buffer.clear()
	_speaker_queue.clear()
	_active_request_id = 0
	_active_npc_id = ""
	_current_player_text = ""
	var ui := get_tree().get_first_node_in_group("dialogue_ui")
	if ui != null and ui.has_method("is_open") and ui.is_open():
		ui.close_dialogue()
	print("[GroupChat] 开始串行公聊：地点=%s，参与者=%s" % [_loc_id, ",".join(_participant_ids)])
	return true


## 每轮按确定顺序逐个请求 NPC；后续 NPC 会在 prompt 中读到此前 NPC 已说的话。
func submit_player_message(text: String) -> void:
	if not _active or _active_request_id != 0:
		return
	if _round >= MAX_ROUNDS:
		_end_session("round_limit")
		return
	_current_player_text = text.strip_edges()
	if _current_player_text == "":
		return
	_round += 1
	_buffer.append({"sender": "player", "text": _current_player_text, "round": _round})
	_speaker_queue = _ordered_participants()
	_request_next_speaker()


func _ordered_participants() -> Array[String]:
	var result: Array[String] = _participant_ids.duplicate()
	result.sort_custom(func(a: String, b: String) -> bool:
		var rank_a := int(NpcRegistry.IMPORTANCE_RANK.get(String(NpcRegistry.get_npc(a).get("importance", "normal")), 1))
		var rank_b := int(NpcRegistry.IMPORTANCE_RANK.get(String(NpcRegistry.get_npc(b).get("importance", "normal")), 1))
		if rank_a != rank_b:
			return rank_a < rank_b
		var priority_a := int(NpcRegistry.get_npc(a).get("sort_priority", 100))
		var priority_b := int(NpcRegistry.get_npc(b).get("sort_priority", 100))
		if priority_a != priority_b:
			return priority_a < priority_b
		return a < b)
	return result


func _request_next_speaker() -> void:
	if not _active:
		return
	_cancel_timeout()
	_active_request_id = 0
	_active_npc_id = ""
	if _speaker_queue.is_empty():
		_finish_round()
		return

	var npc_id: String = _speaker_queue.pop_front()
	var profile: Dictionary = NpcRegistry.build_llm_profile(NpcRegistry.get_dialogue_profile(npc_id))
	if profile.is_empty():
		call_deferred("_request_next_speaker")
		return

	var scene_block := NpcRegistry.build_scene_prompt_block(npc_id)
	if scene_block != "":
		profile["system_prompt"] = String(profile.get("system_prompt", "")) + "\n\n" + scene_block
	var memory_block := MemoryStore.build_memory_prompt_block(npc_id)
	if memory_block != "":
		profile["system_prompt"] = String(profile.get("system_prompt", "")) + memory_block
	profile["system_prompt"] = String(profile.get("system_prompt", "")) + _build_group_scene_instruction(npc_id)
	var group_context := _build_group_context_for(npc_id)
	if group_context != "":
		profile["system_prompt"] = String(profile.get("system_prompt", "")) + "\n\n## 本次公聊已发生的发言\n" + group_context
	profile["system_prompt"] = String(profile.get("system_prompt", "")) + "\n\n## 公聊发言规则\n你会按顺序发言。先阅读上方当前地点与此前发言；若其他 NPC 刚刚说过话，应自然回应、补充或反驳其内容，不能假装没听见。请在 JSON 额外输出 speak：true 表示发言，false 表示沉默。发言时 text 必须是角色台词；沉默时 text 留空。mood 必须选择当前情绪。"

	_active_npc_id = npc_id
	var npc_history := MemoryStore.get_history(npc_id)
	_active_request_id = LLMService.chat(profile, npc_history, _current_player_text, _round, "group_chat_serial")
	npc_turn_started.emit(npc_id)
	_start_timeout()


## 当前玩家句由 LLMService 的最后一条 user message 提供，避免在 system context 中重复。
## 前序 NPC 发言会在串行请求期间即时写入 _buffer，因此后一个 NPC 一定能看到。
func _build_group_context_for(npc_id: String) -> String:
	var lines: PackedStringArray = []
	for entry in _buffer:
		var sender := String(entry.get("sender", ""))
		var text := String(entry.get("text", ""))
		var round := int(entry.get("round", 0))
		if sender == "player":
			if round == _round and text == _current_player_text:
				continue
			lines.append("【第%d轮·玩家】%s" % [round, text])
		elif sender != npc_id:
			lines.append("【第%d轮·%s】%s" % [round, NpcRegistry.get_short_name(sender), text])
	return "\n".join(lines)


func _build_group_scene_instruction(npc_id: String) -> String:
	var location := NpcRegistry.get_location_info(_loc_id)
	var location_name := String(location.get("name", NpcRegistry.get_location_name(_loc_id)))
	var description := String(location.get("description", ""))
	var tags: Variant = location.get("tags", [])
	var tag_text := "、".join(tags) if tags is Array else ""
	var other_names: PackedStringArray = []
	for other_id in _participant_ids:
		if other_id != npc_id:
			other_names.append(NpcRegistry.get_short_name(other_id))
	return "\n\n## 公聊现场感知（必须融入判断）\n- 当前地点：%s（id: %s）\n- 场景描述：%s\n- 场景标签：%s\n- 你正与玩家及%s在同一地点面对面交谈。请基于这个具体地点、现场氛围与在场者发言回应，不要把地点当作未知信息。" % [location_name, _loc_id, description, tag_text, "、".join(other_names)]


func _on_llm_chunk(request_id: int, _session_id: int, npc_id: String, accumulated_text: String) -> void:
	if not _active or request_id != _active_request_id or npc_id != _active_npc_id:
		return
	npc_speech_chunk.emit(npc_id, accumulated_text)


func _on_llm_reply(request_id: int, _session_id: int, npc_id: String, reply: Dictionary) -> void:
	if not _active or request_id != _active_request_id or npc_id != _active_npc_id:
		return
	_cancel_timeout()
	_active_request_id = 0
	_active_npc_id = ""
	var text := String(reply.get("text", "")).strip_edges()
	var speak := _should_speak(reply)
	if speak and text != "":
		var mood := String(reply.get("mood", ""))
		_buffer.append({"sender": npc_id, "text": text, "round": _round})
		MemoryStore.append_turn(npc_id, _current_player_text, text, [])
		npc_spoke.emit(npc_id, text, _round, mood)
		_apply_group_action(npc_id, reply)
	else:
		npc_silent.emit(npc_id)
	call_deferred("_request_next_speaker")


func _on_llm_failed(request_id: int, _session_id: int, npc_id: String, _error: String) -> void:
	if not _active or request_id != _active_request_id or npc_id != _active_npc_id:
		return
	_cancel_timeout()
	_active_request_id = 0
	_active_npc_id = ""
	call_deferred("_request_next_speaker")


func _should_speak(reply: Dictionary) -> bool:
	var raw: Variant = reply.get("speak", true)
	if raw is bool:
		return bool(raw)
	if raw is String:
		return String(raw).strip_edges().to_lower() != "false"
	return true


func _apply_group_action(npc_id: String, reply: Dictionary) -> void:
	var action: Variant = reply.get("action", {})
	if action is Dictionary and not (action as Dictionary).is_empty():
		NpcRegistry.apply_llm_action(npc_id, action)


func _finish_round() -> void:
	if not _active:
		return
	var rest_required: bool = GameState.complete_player_dialogue_round()
	if rest_required:
		_end_session("night_rest")
		return
	round_completed.emit(_round)
	if _round >= MAX_ROUNDS:
		_end_session("round_limit")
		return
	if TimeSystem.total_minutes() - _start_total_minutes >= MAX_TIME_MINUTES:
		_end_session("time_limit")
		return
	if _participant_ids.size() < 2:
		_end_session("too_few_participants")


func _start_timeout() -> void:
	_timeout_timer = get_tree().create_timer(LLM_TIMEOUT_SEC)
	var timer := _timeout_timer
	timer.timeout.connect(func():
		if timer != _timeout_timer or not _active or _active_request_id == 0:
			return
		var timed_out_id := _active_request_id
		LLMService.cancel_request(timed_out_id)
		_active_request_id = 0
		_active_npc_id = ""
		call_deferred("_request_next_speaker"))


func _cancel_timeout() -> void:
	_timeout_timer = null


func _end_session(reason: String) -> void:
	if not _active:
		return
	_active = false
	_cancel_timeout()
	if _active_request_id != 0:
		LLMService.cancel_request(_active_request_id)
	var npc_names: PackedStringArray = []
	for npc_id in _participant_ids:
		npc_names.append(NpcRegistry.get_short_name(npc_id))
	MemoryStore.add_global_memory(
		"外来者在%s召集了%s一起谈话。" % [NpcRegistry.get_location_name(_loc_id), "、".join(npc_names)],
		["group_chat", _loc_id])
	_active_request_id = 0
	_active_npc_id = ""
	_speaker_queue.clear()
	_participant_ids.clear()
	_round = 0
	session_ended.emit(reason)


func is_active() -> bool:
	return _active


func current_round() -> int:
	return _round


func remaining_rounds() -> int:
	return maxi(0, MAX_ROUNDS - _round)


func participants() -> Array[String]:
	return _participant_ids.duplicate()
