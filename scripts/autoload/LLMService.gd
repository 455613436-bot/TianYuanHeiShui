extends Node
## LLMService
## 大模型对话服务（autoload 单例）。策略模式，可插拔 Provider。
##
## 关键设计：**meta 效果（污染/好感/道具/线索）不由 LLM 决定**，
## 而是 LLMService 自己根据 NPC profile 里的 triggers 关键词表匹配玩家输入来算。
## 原因：LLM 输出的结构化字段不可靠，会漏、会瞎给道具。触发器由规则控制，稳定。
##
## Provider 只负责生成 text，返回时 LLMService 会在 emit 之前合并 meta。

signal reply_received(request_id: int, session_id: int, npc_id: String, reply: Dictionary)
signal reply_failed(request_id: int, session_id: int, npc_id: String, error: String)
signal reply_chunk(request_id: int, session_id: int, npc_id: String, accumulated_text: String)
signal request_cancelled(request_id: int, session_id: int, npc_id: String)
signal summary_ready(npc_id: String, summary: String)
signal summary_failed(npc_id: String, error: String)

const MockLLMScript := preload("res://scripts/llm/MockLLM.gd")

var _provider: Node = null

## 当前正在进行的会话上下文：npc_id -> {profile, user_text}
var _next_request_id: int = 1
## 用于在收到 provider 回复时能查回 triggers 计算 meta
var _inflight: Dictionary = {}


func _ready() -> void:
	# 默认装 Mock；LLMConfig 会在稍后一帧根据环境变量 / 用户配置切换
	var mock = MockLLMScript.new()
	mock.name = "MockLLM"
	add_child(mock)
	_provider = mock
	print("[LLMService] 已装载默认 Provider: MockLLM")


func set_provider(provider: Node) -> void:
	cancel_all_requests()
	if _provider:
		_provider.queue_free()
	_provider = provider
	add_child(provider)
	# OpenAI Provider 通过 tracer 记录实际请求与原始响应；日志器从不接收请求头或 API Key。
	var logger := get_node_or_null("/root/LLMDebugLogger")
	if logger != null and "tracer" in provider:
		provider.set("tracer", logger)
	# Provider 通过 service.reply_received.emit(...) 回调；不直接连信号
	print("[LLMService] 切换 Provider -> %s" % provider.name)



## 由 DialogueUI 调用
func chat(npc_profile: Dictionary, history: Array, user_text: String, session_id: int = 0, purpose: String = "dialogue") -> int:
	var npc_id: String = String(npc_profile.get("id", "?"))
	# 记录本轮的上下文，用于收到 Provider 回复时合并 meta
	var request_id := _next_request_id
	_next_request_id += 1
	_inflight[request_id] = {
		"session_id": session_id,
		"npc_id": npc_id,
		"profile": npc_profile,
		"user_text": user_text,
		"purpose": purpose,
	}
	if _provider == null:
		call_deferred("deliver_failure", request_id, npc_id, "no provider")
		return request_id
	# Deferred dispatch lets the caller store request_id before a provider can reply.
	_provider.call_deferred("generate", request_id, npc_profile, history, user_text, self)
	return request_id


## 覆盖 Node.emit_signal 无用，我们自己拦截 Provider 的信号发送
## 实际做法：Provider 直接 service.reply_received.emit(...)，我们在这里
## 通过 override 的 emit_signal 拦截，但 GDScript 不能 override 内置 emit_signal
## → 换一种做法：Provider 调用 service.emit_reply(...) / service.emit_failed(...)
##   来替代直接 emit，这样我们能合并 meta。
##
## 但为了兼容之前 Provider 里直接写的 emit，我们保留两种入口：
## - 直接 emit reply_received：走 _post_process 之前的路径。为此我们把
##   reply_received 连到自己的一个 pre-hook，去合并 meta 后再 relay。
##
## 我用一个更简单的方案：在这个类内定义一个 relay 方法给 Provider 调。
## 修改 Provider：把 service.reply_received.emit(...) 改为 service.deliver_reply(...)

func deliver_reply(request_id: int, npc_id: String, reply: Dictionary) -> void:
	if not _inflight.has(request_id):
		return
	var ctx: Dictionary = _inflight[request_id]
	if String(ctx.get("npc_id", "")) != npc_id:
		return
	_inflight.erase(request_id)
	var final_meta: Dictionary = _compute_meta(ctx.get("profile", {}), ctx.get("user_text", ""))
	# 合并（Provider 也可能自己带 meta，Mock 就带；真 LLM 不带）
	var provider_meta: Dictionary = reply.get("meta", {})
	for k in provider_meta.keys():
		if not final_meta.has(k) or final_meta[k] == "" or final_meta[k] == 0:
			final_meta[k] = provider_meta[k]
	reply["meta"] = final_meta
	var logger := get_node_or_null("/root/LLMDebugLogger")
	if logger != null and logger.has_method("log_chat_final_reply"):
		logger.call("log_chat_final_reply", request_id, ctx, reply)
	reply_received.emit(request_id, int(ctx.get("session_id", 0)), npc_id, reply)



func deliver_chunk(request_id: int, npc_id: String, accumulated_text: String) -> void:
	if not _inflight.has(request_id):
		return
	var ctx: Dictionary = _inflight[request_id]
	if String(ctx.get("npc_id", "")) != npc_id:
		return
	reply_chunk.emit(request_id, int(ctx.get("session_id", 0)), npc_id, accumulated_text)


func deliver_failure(request_id: int, npc_id: String, error: String) -> void:
	if not _inflight.has(request_id):
		return
	var ctx: Dictionary = _inflight[request_id]
	if String(ctx.get("npc_id", "")) != npc_id:
		return
	_inflight.erase(request_id)
	var logger := get_node_or_null("/root/LLMDebugLogger")
	if logger != null and logger.has_method("log_chat_failure"):
		logger.call("log_chat_failure", request_id, ctx, error)
	reply_failed.emit(request_id, int(ctx.get("session_id", 0)), npc_id, error)



func cancel_request(request_id: int) -> void:
	if not _inflight.has(request_id):
		return
	var ctx: Dictionary = _inflight[request_id]
	_inflight.erase(request_id)
	if _provider != null and _provider.has_method("cancel_request"):
		_provider.cancel_request(request_id)
	var logger := get_node_or_null("/root/LLMDebugLogger")
	if logger != null and logger.has_method("log_event"):
		logger.call("log_event", "chat_cancelled", {"request_id": request_id, "context": ctx})
	request_cancelled.emit(request_id, int(ctx.get("session_id", 0)), String(ctx.get("npc_id", "")))



func cancel_all_requests() -> void:
	for request_id in _inflight.keys().duplicate():
		cancel_request(int(request_id))


func is_request_active(request_id: int) -> bool:
	return _inflight.has(request_id)


## ─── 记忆总结通道 ──────────────────────────────────────────────
## 由 MemoryStore/DialogueUI 触发，用于把最近若干轮对话浓缩到 NPC 的记忆文档里。
## 与常规对话请求隔离，不占用 request_id 序列，不影响 UI 的 pending state。
##
## Provider 需实现 summarize(npc_profile, previous_summary, recent_turns, service)
## 完成后调用 service.deliver_summary(npc_id, summary_text)
## 或 service.deliver_summary_failure(npc_id, error)
## 如果 Provider 未实现，会走本地兜底拼接（最后 5 条 user/npc 文本压缩）。
func summarize(npc_profile: Dictionary, previous_summary: String, recent_turns: Array) -> void:
	var npc_id: String = String(npc_profile.get("id", "?"))
	if _provider != null and _provider.has_method("summarize"):
		_provider.call_deferred("summarize", npc_profile, previous_summary, recent_turns, self)
	else:
		# 本地兜底：把最近对话直接以「玩家说 / NPC 说」形式拼到已有摘要之后。
		var text := _local_fallback_summary(previous_summary, recent_turns)
		call_deferred("deliver_summary", npc_id, text)


func deliver_summary(npc_id: String, summary: String) -> void:
	var logger := get_node_or_null("/root/LLMDebugLogger")
	if logger != null and logger.has_method("log_summary_result"):
		logger.call("log_summary_result", npc_id, true, summary)
	summary_ready.emit(npc_id, summary)


func deliver_summary_failure(npc_id: String, error: String) -> void:
	var logger := get_node_or_null("/root/LLMDebugLogger")
	if logger != null and logger.has_method("log_summary_result"):
		logger.call("log_summary_result", npc_id, false, error)
	summary_failed.emit(npc_id, error)



func _local_fallback_summary(previous_summary: String, recent_turns: Array) -> String:
	var lines: PackedStringArray = []
	if previous_summary.strip_edges() != "":
		lines.append(previous_summary.strip_edges())
	var latest_lines: PackedStringArray = []
	for entry in recent_turns:
		if entry is not Dictionary:
			continue
		var role := String((entry as Dictionary).get("role", ""))
		var text := String((entry as Dictionary).get("text", "")).strip_edges()
		if text == "":
			continue
		if role == "user":
			latest_lines.append("- 玩家说：" + _short_text(text, 60))
		elif role == "npc":
			latest_lines.append("- 我回应：" + _short_text(text, 60))
	if not latest_lines.is_empty():
		lines.append("最近对话要点：\n" + "\n".join(latest_lines))
	return "\n\n".join(lines)


func _short_text(text: String, limit: int) -> String:
	if text.length() <= limit:
		return text
	return text.substr(0, limit) + "…"


## 根据 profile.triggers 对 user_text 做关键词匹配，聚合所有命中项的 meta
func _compute_meta(profile: Dictionary, user_text: String) -> Dictionary:
	var meta := {
		"pollution_delta": 0,
		"affinity_delta": 0,
		"clue_id": "",
		"give_item": "",
	}
	if profile.is_empty() or user_text == "": return meta
	var lower := user_text.to_lower()
	for t in profile.get("triggers", []):
		var kws: Array = t.get("keywords", [])
		var hit := false
		for kw in kws:
			var kw_s := String(kw)
			if user_text.contains(kw_s) or lower.contains(kw_s.to_lower()):
				hit = true; break
		if not hit: continue
		meta["pollution_delta"] += int(t.get("pollution_delta", 0))
		meta["affinity_delta"]  += int(t.get("affinity_delta", 0))
		# clue_id / give_item：多个命中只保留第一个，避免重复给
		if meta["clue_id"] == "":   meta["clue_id"]   = String(t.get("clue_id", ""))
		if meta["give_item"] == "": meta["give_item"] = String(t.get("give_item", ""))
	return meta
