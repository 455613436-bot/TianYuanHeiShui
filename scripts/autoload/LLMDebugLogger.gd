extends Node
## 游戏运行时 LLM 调试日志。
## 日志写入项目外的 D:/siyuan_llm_log，按会话、调用类型分目录保存。
## 绝不记录 HTTP Authorization 请求头；递归写盘前会遮蔽常见密钥字段。

const LOG_ROOT := "D:/siyuan_llm_log"

var _session_dir := ""
var _summary_counter := 0
var _latest_summary_index_by_npc: Dictionary = {}
var _warned_io_error := false


func _ready() -> void:
	var session_slug := _timestamp_slug()
	_session_dir = LOG_ROOT.path_join(session_slug)
	for category in ["chat", "summary", "events"]:
		var err := DirAccess.make_dir_recursive_absolute(_session_dir.path_join(category))
		if err != OK:
			_warn_write_error("无法创建 LLM 调试日志目录，err=%d" % err)
			return
	_write_json("session.json", {
		"event": "session_start",
		"timestamp": Time.get_datetime_string_from_system(),
		"log_root": LOG_ROOT,
		"security": "HTTP 请求头与常见密钥字段不会写入日志。",
	})


## OpenAILLM 在真正发送 HTTP 请求前调用。
## sent_payload 不包含 HTTP 认证头；仍会递归遮蔽敏感字段以避免配置误入日志。
func on_chat_request(request_id: int, npc_profile: Dictionary, sent_messages: Array, sent_payload: Dictionary, provider_info: Dictionary) -> void:
	_write_json("chat/request_%06d.json" % request_id, {
		"event": "chat_request",
		"timestamp": Time.get_datetime_string_from_system(),
		"request_id": request_id,
		"npc": {
			"id": npc_profile.get("id", ""),
			"display_name": npc_profile.get("display_name", ""),
		},
		"provider": provider_info,
		"payload": sent_payload,
		"messages": sent_messages,
	})
	_append_event("chat_request", {"request_id": request_id, "npc_id": npc_profile.get("id", "")})


## OpenAILLM 在收到 HTTP body 后调用，包含成功和失败响应。
func on_chat_raw_response(request_id: int, npc_id: String, http_status: int, raw_text: String, latency_ms: int) -> void:
	_write_json("chat/response_%06d.json" % request_id, {
		"event": "chat_raw_response",
		"timestamp": Time.get_datetime_string_from_system(),
		"request_id": request_id,
		"npc_id": npc_id,
		"http_status": http_status,
		"latency_ms": latency_ms,
		"raw_response": raw_text,
	})
	_append_event("chat_raw_response", {
		"request_id": request_id,
		"npc_id": npc_id,
		"http_status": http_status,
		"latency_ms": latency_ms,
	})


## LLMService 在 SuggestionGuard 解析和本地 meta 合并后调用。
func log_chat_final_reply(request_id: int, context: Dictionary, reply: Dictionary) -> void:
	_write_json("chat/final_%06d.json" % request_id, {
		"event": "chat_final_reply",
		"timestamp": Time.get_datetime_string_from_system(),
		"request_id": request_id,
		"npc_id": context.get("npc_id", ""),
		"session_id": context.get("session_id", 0),
		"purpose": context.get("purpose", "dialogue"),
		"final_reply": reply,
	})
	_append_event("chat_final_reply", {
		"request_id": request_id,
		"npc_id": context.get("npc_id", ""),
		"purpose": context.get("purpose", "dialogue"),
	})


func log_chat_failure(request_id: int, context: Dictionary, error: String) -> void:
	_write_json("chat/failure_%06d.json" % request_id, {
		"event": "chat_failure",
		"timestamp": Time.get_datetime_string_from_system(),
		"request_id": request_id,
		"npc_id": context.get("npc_id", ""),
		"session_id": context.get("session_id", 0),
		"purpose": context.get("purpose", "dialogue"),
		"error": error,
	})
	_append_event("chat_failure", {"request_id": request_id, "npc_id": context.get("npc_id", "")})


## OpenAILLM 在记忆总结请求发送前调用。
func on_summary_request(npc_id: String, previous_summary: String, recent_turns: Array, sent_messages: Array) -> void:
	_summary_counter += 1
	_latest_summary_index_by_npc[npc_id] = _summary_counter
	_write_json("summary/request_%03d_%s.json" % [_summary_counter, _safe_file_part(npc_id)], {
		"event": "summary_request",
		"timestamp": Time.get_datetime_string_from_system(),
		"summary_index": _summary_counter,
		"npc_id": npc_id,
		"previous_summary": previous_summary,
		"recent_turns": recent_turns,
		"messages": sent_messages,
	})
	_append_event("summary_request", {"summary_index": _summary_counter, "npc_id": npc_id})


## OpenAILLM 在收到记忆总结 HTTP body 后调用。
func on_summary_raw_response(npc_id: String, http_status: int, raw_text: String, latency_ms: int) -> void:
	var index := int(_latest_summary_index_by_npc.get(npc_id, 0))
	_write_json("summary/response_%03d_%s.json" % [index, _safe_file_part(npc_id)], {
		"event": "summary_raw_response",
		"timestamp": Time.get_datetime_string_from_system(),
		"summary_index": index,
		"npc_id": npc_id,
		"http_status": http_status,
		"latency_ms": latency_ms,
		"raw_response": raw_text,
	})
	_append_event("summary_raw_response", {"summary_index": index, "npc_id": npc_id, "http_status": http_status, "latency_ms": latency_ms})


func log_summary_result(npc_id: String, ok: bool, content: String) -> void:
	var index := int(_latest_summary_index_by_npc.get(npc_id, 0))
	_write_json("summary/final_%03d_%s.json" % [index, _safe_file_part(npc_id)], {
		"event": "summary_final",
		"timestamp": Time.get_datetime_string_from_system(),
		"summary_index": index,
		"npc_id": npc_id,
		"ok": ok,
		"content": content,
	})
	_append_event("summary_final", {"summary_index": index, "npc_id": npc_id, "ok": ok})


func log_event(event_type: String, data: Dictionary) -> void:
	_append_event(event_type, data)


func _append_event(event_type: String, data: Dictionary) -> void:
	var record := data.duplicate(true)
	record["event"] = event_type
	record["timestamp"] = Time.get_datetime_string_from_system()
	_append_text("events/events.jsonl", JSON.stringify(_sanitize(record)) + "\n")


func _write_json(relative_path: String, data: Dictionary) -> void:
	_write_text(relative_path, JSON.stringify(_sanitize(data), "\t"))


func _write_text(relative_path: String, content: String) -> void:
	if _session_dir == "":
		return
	var absolute_path := _session_dir.path_join(relative_path)
	var file := FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		_warn_write_error("无法写入 LLM 调试日志：%s" % absolute_path)
		return
	file.store_string(content)
	file.close()


func _append_text(relative_path: String, content: String) -> void:
	if _session_dir == "":
		return
	var absolute_path := _session_dir.path_join(relative_path)
	var file := FileAccess.open(absolute_path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(absolute_path, FileAccess.WRITE)
	if file == null:
		_warn_write_error("无法追加 LLM 调试日志：%s" % absolute_path)
		return
	file.seek_end()
	file.store_string(content)
	file.close()


## 按字段名遮蔽密钥，并额外清理文本中可能出现的认证字串。
func _sanitize(value: Variant) -> Variant:
	if value is Dictionary:
		var clean: Dictionary = {}
		for raw_key in (value as Dictionary).keys():
			var key := String(raw_key)
			if _is_sensitive_key(key):
				clean[key] = "<redacted>"
			else:
				clean[key] = _sanitize((value as Dictionary)[raw_key])
		return clean
	if value is Array:
		var clean_array: Array = []
		for item in value as Array:
			clean_array.append(_sanitize(item))
		return clean_array
	if value is String:
		return _redact_text(value as String)
	return value


func _is_sensitive_key(key: String) -> bool:
	var normalized := key.to_lower().replace("-", "_")
	return normalized.contains("api_key") or normalized.contains("authorization") or normalized.contains("access_token") or normalized == "token" or normalized.contains("secret") or normalized.contains("password")


func _redact_text(text: String) -> String:
	var result := text
	var authorization := RegEx.new()
	authorization.compile("(?i)(authorization\\s*[:=]\\s*(?:bearer\\s+)?)\\S+")
	result = authorization.sub(result, "$1<redacted>", true)
	var key_field := RegEx.new()
	key_field.compile("(?i)(\\\"?(?:api[_-]?key|access[_-]?token|secret|password)\\\"?\\s*[:=]\\s*\\\"?)[^\\\"\\s,}]+")
	return key_field.sub(result, "$1<redacted>", true)


func _safe_file_part(value: String) -> String:
	var clean := value.strip_edges()
	for character in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]:
		clean = clean.replace(character, "_")
	return clean if clean != "" else "unknown"


func _warn_write_error(message: String) -> void:
	if _warned_io_error:
		return
	_warned_io_error = true
	push_warning("[LLMDebugLogger] " + message)


static func _timestamp_slug() -> String:
	var time := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d" % [time.year, time.month, time.day, time.hour, time.minute, time.second]
