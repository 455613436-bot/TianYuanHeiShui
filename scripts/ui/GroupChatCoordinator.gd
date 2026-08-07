extends Node
## GroupChatCoordinator
## 公聊模式调度器（§9）。当当前地点 NPC >= 2 时由 NpcPresenceBar 触发。
##
## 关键设计（文档 §9.3 / §9.5）：
## - 每个参与 NPC **独立**调一次 LLMService.chat()，使用各自完整 profile + memory + history
## - prompt 分层严格保持顺序，最大化服务端 prompt cache 命中
## - 公聊缓冲区仅在本次公聊内共享，散场丢弃；玩家话进所有参与者 history，NPC 话只进自己 history
## - 上限：6 轮 / 30 分钟游戏时间；每轮最多显示 3 条发言
##
## UI：复用 DialogueUI 面板，由 GroupChatCoordinator 驱动；
## 为避免大幅改动 DialogueUI，M6 先用独立 CanvasLayer 渲染公聊气泡。

signal round_completed(round: int)
signal session_ended(reason: String)
signal npc_spoke(npc_id: String, text: String, round: int)

const MAX_ROUNDS := 6
const MAX_TIME_MINUTES := 30
const MAX_SPEAKERS_PER_ROUND := 3
const LLM_TIMEOUT_SEC := 40.0

## 当前公聊会话状态
var _active: bool = false
var _loc_id: String = ""
var _participant_ids: Array[String] = []
var _round: int = 0
## 公聊缓冲区：[{sender:"player"|"npc_id", text:String, round:int}]
var _buffer: Array = []
## 本轮在途的 LLM 请求：request_id -> npc_id
var _inflight: Dictionary = {}
## 本轮已收到的回复：npc_id -> reply dict
var _replies: Dictionary = {}
## 会话开始时的绝对分钟数（用于 30 分钟上限判定）
var _start_total_minutes: int = 0

var _timeout_timer: SceneTreeTimer = null


func _ready() -> void:
	LLMService.reply_received.connect(_on_llm_reply)
	LLMService.reply_failed.connect(_on_llm_failed)


## 开启一次公聊会话。返回 true 表示成功启动。
func start_session(loc_id: String, npc_ids: Array[String]) -> bool:
	if _active:
		return false
	if loc_id == "" or npc_ids.size() < 2:
		return false
	_active = true
	_loc_id = loc_id
	_participant_ids = npc_ids.duplicate()
	_round = 0
	_start_total_minutes = TimeSystem.total_minutes()
	_buffer.clear()
	_inflight.clear()
	_replies.clear()
	# 让 DialogueUI 关闭（若开着）
	var ui := get_tree().get_first_node_in_group("dialogue_ui")
	if ui != null and ui.has_method("is_open") and ui.is_open():
		ui.close_dialogue()
	print("[GroupChat] 开始公聊：地点=%s，参与者=%s" % [_loc_id, ",".join(_participant_ids)])
	return true


## 玩家提交一句话 → 并行为每个参与 NPC 发起 LLM 调用
func submit_player_message(text: String) -> void:
	if not _active or _round >= MAX_ROUNDS:
		_end_session("round_limit")
		return
	_round += 1
	_buffer.append({"sender": "player", "text": text, "round": _round})
	_inflight.clear()
	_replies.clear()
	# 为每个参与 NPC 构建独立请求
	for npc_id in _participant_ids:
		var profile := NpcRegistry.get_dialogue_profile(npc_id)
		if profile.is_empty():
			continue
		# 注入场景状态 + 公聊上下文（文档 §9.3 段4-7）
		var scene_block := NpcRegistry.build_scene_prompt_block(npc_id)
		if scene_block != "":
			profile["system_prompt"] = String(profile.get("system_prompt", "")) + "\n\n" + scene_block
		var mem_block := MemoryStore.build_memory_prompt_block(npc_id)
		if mem_block != "":
			profile["system_prompt"] = String(profile.get("system_prompt", "")) + mem_block
		# 公聊上下文：本次公聊此前几轮的发言（段6）
		var group_ctx := _build_group_context_for(npc_id)
		if group_ctx != "":
			profile["system_prompt"] = String(profile.get("system_prompt", "")) + "\n\n## 公聊上下文（本轮此前他人发言）\n" + group_ctx
		# 发言决策指令（段7 附加）
		profile["system_prompt"] = String(profile.get("system_prompt", "")) + "\n\n## 公聊发言决策\n请在 JSON 里额外输出 speak 字段：true 表示你这轮要发言，false 表示沉默。text 字段是你的台词（speak=false 时留空）。action 字段复用说服裁决器 schema。"
		# 该 NPC 自己的 history
		var npc_history := MemoryStore.get_history(npc_id)
		# 玩家最新一句作为 user_text
		var request_id := LLMService.chat(profile, npc_history, text, _round, "group_chat")
		_inflight[request_id] = npc_id
	_start_timeout()


func _build_group_context_for(npc_id: String) -> String:
	if _buffer.is_empty():
		return ""
	var lines: PackedStringArray = []
	for entry in _buffer:
		var sender := String(entry.get("sender", ""))
		var text := String(entry.get("text", ""))
		var r := int(entry.get("round", 0))
		if sender == "player":
			lines.append("【第%d轮·玩家】%s" % [r, text])
		elif sender != npc_id:
			lines.append("【第%d轮·%s】%s" % [r, NpcRegistry.get_short_name(sender), text])
	return "\n".join(lines)


func _on_llm_reply(request_id: int, _session_id: int, npc_id: String, reply: Dictionary) -> void:
	if not _inflight.has(request_id):
		return
	_inflight.erase(request_id)
	_replies[npc_id] = reply
	_check_round_complete()


func _on_llm_failed(request_id: int, _session_id: int, npc_id: String, _error: String) -> void:
	if not _inflight.has(request_id):
		return
	_inflight.erase(request_id)
	# 失败的 NPC 视为本轮沉默
	_replies[npc_id] = {"text": "", "speak": false}
	_check_round_complete()


func _check_round_complete() -> void:
	if not _inflight.is_empty():
		return
	_cancel_timeout()
	# 处理本轮所有回复
	var speakers: Array = []
	for npc_id in _replies:
		var reply: Dictionary = _replies[npc_id]
		var text := String(reply.get("text", "")).strip_edges()
		# 公聊里 LLM 可能输出 speak 字段；无 speak 字段时默认有 text 就发言
		var speak_raw: Variant = reply.get("speak", null)
		var speak := true
		if speak_raw is bool:
			speak = bool(speak_raw)
		elif speak_raw is String and String(speak_raw).to_lower() == "false":
			speak = false
		if speak and text != "":
			speakers.append({"npc_id": npc_id, "text": text, "reply": reply})
	# 按 importance + sort_priority 排序
	speakers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := int(NpcRegistry.IMPORTANCE_RANK.get(String(NpcRegistry.get_npc(String(a.npc_id)).get("importance", "normal")), 1))
		var rb := int(NpcRegistry.IMPORTANCE_RANK.get(String(NpcRegistry.get_npc(String(b.npc_id)).get("importance", "normal")), 1))
		if ra != rb:
			return ra < rb
		var pa := int(NpcRegistry.get_npc(String(a.npc_id)).get("sort_priority", 100))
		var pb := int(NpcRegistry.get_npc(String(b.npc_id)).get("sort_priority", 100))
		if pa != pb:
			return pa < pb
		return String(a.npc_id) < String(b.npc_id))
	# 最多显示 3 条
	var shown := 0
	for speaker in speakers:
		if shown >= MAX_SPEAKERS_PER_ROUND:
			break
		var npc_id := String(speaker.npc_id)
		var text := String(speaker.text)
		_buffer.append({"sender": npc_id, "text": text, "round": _round})
		# 写入该 NPC 自己的 history（文档 §9.5）
		MemoryStore.append_turn(npc_id, "", text, [])
		npc_spoke.emit(npc_id, text, _round)
		shown += 1
		# 处理 action（公聊里也能被说服）
		var action_raw: Variant = (speaker.reply as Dictionary).get("action", {})
		if action_raw is Dictionary and not (action_raw as Dictionary).is_empty():
			NpcRegistry.apply_llm_action(npc_id, action_raw)
	# 推进游戏时间
	TimeSystem.on_dialogue_turn_completed()
	round_completed.emit(_round)
	# 检查结束条件
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
		if timer != _timeout_timer:
			return
		# 超时：把未返回的 NPC 视为沉默
		for request_id in _inflight.keys().duplicate():
			var npc_id := String(_inflight[request_id])
			LLMService.cancel_request(int(request_id))
			_inflight.erase(request_id)
			_replies[npc_id] = {"text": "", "speak": false}
		_check_round_complete())


func _cancel_timeout() -> void:
	_timeout_timer = null


func _end_session(reason: String) -> void:
	if not _active:
		return
	_active = false
	# 散场：写一句全局记忆（规则拼接）
	var npc_names: PackedStringArray = []
	for npc_id in _participant_ids:
		npc_names.append(NpcRegistry.get_short_name(npc_id))
	MemoryStore.add_global_memory(
		"外来者在%s召集了%s一起谈话。" % [NpcRegistry.get_location_name(_loc_id), "、".join(npc_names)],
		["group_chat", _loc_id])
	_buffer.clear()
	_inflight.clear()
	_replies.clear()
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
