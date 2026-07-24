extends RefCounted
class_name TraceLogger
## 把 LLM 一次调用的完整过程（system prompt / few-shot / history / raw response /
## parsed reply / meta / check_request / 记忆快照）落盘，方便离线调试。
##
## 落盘目录：
##   user://llm_trace/<session_ts>/                     ← Godot 用户目录（跨平台通用）
##   res://../llm_trace/<session_ts>/  (可选 mirror)    ← 项目根旁边，便于直接翻看
##
## 每个 session 目录里：
##   session.log.jsonl   —— 一行一个事件（chat_request / chat_response / summary_request / summary_response / cmd）
##   turn_XX.md          —— 每一轮"人类可读"的 markdown（把 messages 拼开）
##   summary_XX.md       —— 每次记忆总结的可读版本

var _dir_user: String = ""     ## 例如 user://llm_trace/20260723_181205/
var _dir_mirror: String = ""   ## 例如 <project_root>/llm_trace/20260723_181205/  空表示不 mirror
var _session_start_ts: String = ""
var _turn_counter: int = 0
var _summary_counter: int = 0
var _enabled: bool = true


func _init(mirror_to_project_root: bool = true) -> void:
	_session_start_ts = _timestamp_slug()
	_dir_user = "user://llm_trace/%s" % _session_start_ts
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir_user))
	if mirror_to_project_root:
		# 项目根 = res:// 全局化后的目录
		var project_root: String = ProjectSettings.globalize_path("res://")
		_dir_mirror = project_root.path_join("llm_trace").path_join(_session_start_ts)
		DirAccess.make_dir_recursive_absolute(_dir_mirror)
	_append_jsonl({
		"event": "session_start",
		"ts": Time.get_datetime_string_from_system(),
		"user_dir": ProjectSettings.globalize_path(_dir_user),
		"mirror_dir": _dir_mirror,
	})


func set_enabled(v: bool) -> void:
	_enabled = v


func is_enabled() -> bool:
	return _enabled


func session_dirs() -> Dictionary:
	return {
		"user": ProjectSettings.globalize_path(_dir_user),
		"mirror": _dir_mirror,
	}


## 记一条自由文本（例如 CLI 命令、切换 NPC、清空记忆等）
func log_event(event_type: String, data: Dictionary) -> void:
	if not _enabled: return
	var rec := data.duplicate(true)
	rec["event"] = event_type
	rec["ts"] = Time.get_datetime_string_from_system()
	_append_jsonl(rec)


## 记录一次 chat_request：把 provider 真正会发送给 LLM 的 messages 全部落盘
func log_chat_request(request_id: int, npc_profile: Dictionary, memory_block: String, history: Array, user_text: String, provider_info: Dictionary, sent_messages: Array, sent_payload: Dictionary) -> void:
	if not _enabled: return
	_turn_counter += 1
	var idx := _turn_counter

	# 1) jsonl
	_append_jsonl({
		"event": "chat_request",
		"turn": idx,
		"ts": Time.get_datetime_string_from_system(),
		"request_id": request_id,
		"npc_id": npc_profile.get("id", ""),
		"npc_display": npc_profile.get("display_name", ""),
		"user_text": user_text,
		"provider": provider_info,
		"payload_meta": {
			"model": sent_payload.get("model", ""),
			"temperature": sent_payload.get("temperature", 0),
			"max_tokens": sent_payload.get("max_tokens", 0),
		},
		"messages": sent_messages,
		"memory_block_len": memory_block.length(),
		"history_len": history.size(),
	})

	# 2) human-readable turn markdown
	var lines: PackedStringArray = []
	lines.append("# Turn %d — %s" % [idx, Time.get_datetime_string_from_system()])
	lines.append("")
	lines.append("- NPC: **%s** (`%s`)" % [npc_profile.get("display_name", ""), npc_profile.get("id", "")])
	lines.append("- request_id: `%d`" % request_id)
	lines.append("- provider: `%s` @ `%s` model=`%s`" % [provider_info.get("class", ""), provider_info.get("base_url", ""), provider_info.get("model", "")])
	lines.append("- 玩家输入: `%s`" % user_text)
	lines.append("")
	lines.append("## 记忆块（拼在 system_prompt 尾部）")
	lines.append("```")
	lines.append(memory_block if memory_block != "" else "(empty)")
	lines.append("```")
	lines.append("")
	lines.append("## Sent Messages (顺序 = 实际请求体)")
	for i in range(sent_messages.size()):
		var m: Dictionary = sent_messages[i]
		lines.append("### [%d] role=%s" % [i, m.get("role", "?")])
		lines.append("```")
		lines.append(String(m.get("content", "")))
		lines.append("```")
		lines.append("")
	_write_file(_turn_path(idx), "\n".join(lines))


## 记录 provider 拿到的原始响应文本
func log_chat_raw_response(request_id: int, npc_id: String, http_status: int, raw_text: String, latency_ms: int) -> void:
	if not _enabled: return
	_append_jsonl({
		"event": "chat_raw_response",
		"turn": _turn_counter,
		"ts": Time.get_datetime_string_from_system(),
		"request_id": request_id,
		"npc_id": npc_id,
		"http_status": http_status,
		"latency_ms": latency_ms,
		"raw": raw_text,
	})
	# 追加到 turn markdown 尾（走 _append_text 保证 user + mirror 双份都写到）
	var section := "\n## Raw Response (HTTP %d, %dms)\n```\n%s\n```\n" % [http_status, latency_ms, raw_text]
	_append_text(_turn_path(_turn_counter), section)


## 记录经过 SuggestionGuard 解析 + 服务端 meta 合并后的最终 reply
func log_chat_final_reply(request_id: int, npc_id: String, reply: Dictionary) -> void:
	if not _enabled: return
	_append_jsonl({
		"event": "chat_final_reply",
		"turn": _turn_counter,
		"ts": Time.get_datetime_string_from_system(),
		"request_id": request_id,
		"npc_id": npc_id,
		"reply": reply,
	})
	var pretty := JSON.stringify(reply, "  ")
	var section := "\n## Final Parsed Reply (meta 已合并)\n```json\n%s\n```\n" % pretty
	_append_text(_turn_path(_turn_counter), section)


func log_chat_failure(request_id: int, npc_id: String, error: String) -> void:
	if not _enabled: return
	_append_jsonl({
		"event": "chat_failure",
		"turn": _turn_counter,
		"ts": Time.get_datetime_string_from_system(),
		"request_id": request_id,
		"npc_id": npc_id,
		"error": error,
	})


func log_summary_request(npc_id: String, previous_summary: String, recent_turns: Array, sent_messages: Array) -> void:
	if not _enabled: return
	_summary_counter += 1
	var idx := _summary_counter
	_append_jsonl({
		"event": "summary_request",
		"summary_idx": idx,
		"ts": Time.get_datetime_string_from_system(),
		"npc_id": npc_id,
		"previous_summary": previous_summary,
		"recent_turns": recent_turns,
		"sent_messages": sent_messages,
	})
	var lines: PackedStringArray = []
	lines.append("# Summary Request #%d — npc=%s — %s" % [idx, npc_id, Time.get_datetime_string_from_system()])
	lines.append("")
	lines.append("## 上一版记忆")
	lines.append("```")
	lines.append(previous_summary if previous_summary.strip_edges() != "" else "(empty)")
	lines.append("```")
	lines.append("")
	lines.append("## 最近对话（送给记忆模型）")
	for e in recent_turns:
		var role := String((e as Dictionary).get("role", ""))
		var text := String((e as Dictionary).get("text", ""))
		lines.append("- **%s**: %s" % [role, text])
	lines.append("")
	lines.append("## Sent Messages")
	for m in sent_messages:
		lines.append("### role=%s" % (m as Dictionary).get("role", ""))
		lines.append("```")
		lines.append(String((m as Dictionary).get("content", "")))
		lines.append("```")
	_write_file(_summary_path(idx), "\n".join(lines))


func log_summary_result(npc_id: String, ok: bool, summary_or_error: String) -> void:
	if not _enabled: return
	_append_jsonl({
		"event": "summary_result",
		"summary_idx": _summary_counter,
		"ts": Time.get_datetime_string_from_system(),
		"npc_id": npc_id,
		"ok": ok,
		"content": summary_or_error,
	})
	var tag := "New Summary" if ok else "Summary FAILED"
	var section := "\n## %s\n```\n%s\n```\n" % [tag, summary_or_error]
	_append_text(_summary_path(_summary_counter), section)


# ─── 内部 IO ───────────────────────────────────────────────────────────

func _turn_path(idx: int) -> String:
	return "turn_%03d.md" % idx


func _summary_path(idx: int) -> String:
	return "summary_%03d.md" % idx


func _append_jsonl(rec: Dictionary) -> void:
	var line := JSON.stringify(rec)
	_append_text("session.log.jsonl", line + "\n")


func _write_file(rel_name: String, content: String) -> void:
	_write_text(rel_name, content, false)


func _append_text(rel_name: String, content: String) -> void:
	_write_text(rel_name, content, true)


func _write_text(rel_name: String, content: String, append: bool) -> void:
	# user:// 落一份
	var user_path := _dir_user.path_join(rel_name)
	if append and FileAccess.file_exists(user_path):
		var f := FileAccess.open(user_path, FileAccess.READ_WRITE)
		if f:
			f.seek_end()
			f.store_string(content)
			f.close()
	else:
		var f := FileAccess.open(user_path, FileAccess.WRITE)
		if f:
			f.store_string(content)
			f.close()
	# mirror 到项目根一份（可选）
	if _dir_mirror != "":
		var mirror_path := _dir_mirror.path_join(rel_name)
		if append and FileAccess.file_exists(mirror_path):
			var f2 := FileAccess.open(mirror_path, FileAccess.READ_WRITE)
			if f2:
				f2.seek_end()
				f2.store_string(content)
				f2.close()
		else:
			var f2 := FileAccess.open(mirror_path, FileAccess.WRITE)
			if f2:
				f2.store_string(content)
				f2.close()


static func _timestamp_slug() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d" % [t.year, t.month, t.day, t.hour, t.minute, t.second]
