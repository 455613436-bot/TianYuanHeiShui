extends Node
const SuggestionGuard = preload("res://scripts/llm/SuggestionGuard.gd")
const DialoguePromptScript = preload("res://scripts/llm/DialoguePrompt.gd")
## OpenAILLM
## 兼容 OpenAI Chat Completions 协议的 LLM Provider（非流式稳定版）。
## 用 HTTPRequest 一次性拿完整回复，UI 侧用定时器模拟逐字打字机效果。
##
## 兼容 endpoint：DeepSeek / OpenAI / 通义千问 / 智谱 GLM / 月之暗面 / Ollama 等。

@export var api_key: String = ""
@export var base_url: String = "https://api.deepseek.com/v1"
@export var model_name: String = "deepseek-chat"
## Web 版通过 CloudBase 代理时关闭；真实模型 Key 只由云函数从环境变量读取。
@export var send_authorization: bool = true
@export var request_timeout: float = 90.0
@export var http_max_body_bytes: int = 4 * 1024 * 1024
var _active_http: Dictionary = {}
## HTTP 已完整返回、正在本地逐字展示的请求。Dictionary 引用供 await 循环与快进操作共享。
var _pending_typewriters: Dictionary = {}
## 可选：外部（如调试 CLI）注入一个 tracer，用于记录本 provider 实际发出去的 payload / 原始响应。
## 不注入时业务行为完全等同旧版。约定的方法（用 has_method 检查后再调）：
##   on_chat_request(request_id, npc_profile, sent_messages, sent_payload, provider_info)
##   on_chat_raw_response(request_id, npc_id, http_status, raw_text, latency_ms)
##   on_summary_request(npc_id, previous_summary, recent_turns, sent_messages)
##   on_summary_raw_response(npc_id, http_status, raw_text, latency_ms)
var tracer: Object = null
## 记 request_id → 发起时刻 usec，用于算 latency
var _req_started_usec: Dictionary = {}


## 由 LLMService 调用
func generate(request_id: int, npc_profile: Dictionary, history: Array, user_text: String, service: Node) -> void:
	if not is_instance_valid(service) or not service.is_request_active(request_id):
		return
	var npc_id: String = String(npc_profile.get("id", "?"))

	if send_authorization and api_key.strip_edges() == "":
		service.deliver_failure(request_id, npc_id, "api_key 为空，请配置 llm_config.json")
		return

	var messages := _build_messages(npc_profile, history, user_text)
	var prior_context := _history_text(history)
	var payload := {
		"model": model_name,
		"messages": messages,
		"temperature": float(npc_profile.get("model", {}).get("temperature", 0.85)),
		# 正文以短回复为主，同时给结构化 JSON 与检定字段留出足够空间。
		"max_tokens": clampi(int(npc_profile.get("model", {}).get("max_tokens", 300)), 220, 360),
		"stream": false,
	}

	var http := HTTPRequest.new()
	http.timeout = request_timeout
	http.body_size_limit = http_max_body_bytes
	add_child(http)
	_active_http[request_id] = http

	var url := base_url.rstrip("/") + "/chat/completions"
	var headers := _build_request_headers()

	http.request_completed.connect(
		func(result: int, response_code: int, _hs: PackedStringArray, body: PackedByteArray):
			_on_completed(result, response_code, body, request_id, npc_id, npc_profile, prior_context, user_text, service, http)
	)

	# --- tracer hook: 让调试 CLI 拿到"即将发出去"的完整 payload ---
	if tracer != null and is_instance_valid(tracer) and tracer.has_method("on_chat_request"):
		var provider_info := {
			"class": "OpenAILLM",
			"base_url": base_url,
			"model": model_name,
		}
		tracer.call("on_chat_request", request_id, npc_profile, messages, payload, provider_info)
	_req_started_usec[request_id] = Time.get_ticks_usec()

	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		_active_http.erase(request_id)
		service.deliver_failure(request_id, npc_id, "发起 HTTP 请求失败，err=%d" % err)
		http.queue_free()


func _on_completed(result: int, response_code: int, body: PackedByteArray, request_id: int, npc_id: String, npc_profile: Dictionary, prior_context: String, user_text: String, service: Node, http: HTTPRequest) -> void:
	_active_http.erase(request_id)
	http.queue_free()
	if not is_instance_valid(service) or not service.is_request_active(request_id):
		return

	# --- tracer hook: 记录 raw response（无论成功失败都记） ---
	var raw_text_for_trace := body.get_string_from_utf8()
	if tracer != null and is_instance_valid(tracer) and tracer.has_method("on_chat_raw_response"):
		var started_usec: int = int(_req_started_usec.get(request_id, Time.get_ticks_usec()))
		var latency_ms: int = int((Time.get_ticks_usec() - started_usec) / 1000)
		tracer.call("on_chat_raw_response", request_id, npc_id, response_code, raw_text_for_trace, latency_ms)
	_req_started_usec.erase(request_id)

	if result != HTTPRequest.RESULT_SUCCESS:
		var err_names := {
			HTTPRequest.RESULT_CANT_CONNECT: "连接失败",
			HTTPRequest.RESULT_CANT_RESOLVE: "DNS 解析失败",
			HTTPRequest.RESULT_CONNECTION_ERROR: "连接中断",
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "TLS 握手失败",
			HTTPRequest.RESULT_NO_RESPONSE: "服务未响应",
			HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: "响应体超限",
			HTTPRequest.RESULT_TIMEOUT: "请求超时",
		}
		var desc: String = err_names.get(result, "网络错误")
		service.deliver_failure(request_id, npc_id, "%s (result=%d)" % [desc, result])
		return

	var text := raw_text_for_trace

	if response_code < 200 or response_code >= 300:
		push_warning("[OpenAILLM] HTTP %d: %s" % [response_code, text.substr(0, 300)])
		service.deliver_failure(request_id, npc_id, "HTTP %d: %s" % [response_code, text.substr(0, 200)])
		return

	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		service.deliver_failure(request_id, npc_id, "响应非 JSON: " + text.substr(0, 150))
		return

	if parsed.has("error"):
		var msg = parsed["error"]
		if typeof(msg) == TYPE_DICTIONARY:
			msg = msg.get("message", str(msg))
		service.deliver_failure(request_id, npc_id, "API 错误: " + str(msg))
		return

	var choices: Array = parsed.get("choices", [])
	if choices.is_empty():
		service.deliver_failure(request_id, npc_id, "响应缺少 choices 字段: " + text.substr(0, 200))
		return

	var raw_content: String = String(choices[0].get("message", {}).get("content", "")).strip_edges()
	var model_reply := _parse_model_reply(raw_content, prior_context, user_text, npc_profile)
	# 只对 NPC 正文做打字机效果，选项在正文完成后一起交给 UI。
	_emit_typewriter_stable(request_id, npc_id, model_reply, service)


## 把完整 content 分段发给 UI，制造逐字打字机效果
## 每 40ms 发一段（约 8 字），让玩家感觉字在"流"出来
func _emit_typewriter(request_id: int, npc_id: String, reply: Dictionary, service: Node) -> void:
	var content: String = String(reply.get("text", "……"))
	var chunk_size: int = 1
	var interval_ms: int = 80
	var total: int = content.length()
	# 把所有可变状态 + callable 引用放进同一个 dict，
	# 避免 GDScript 闭包捕获 null callable 或 int 值拷贝的问题
	var ctx: Dictionary = {"i": 0, "fn": Callable()}

	var step: Callable = func():
		if ctx["i"] >= total:
			reply["meta"] = {}
			reply["npc_id"] = npc_id
			service.deliver_reply(request_id, npc_id, reply)
			return
		ctx["i"] = mini(int(ctx["i"]) + chunk_size, total)
		service.deliver_chunk(request_id, npc_id, content.substr(0, int(ctx["i"])))
		var t: SceneTreeTimer = service.get_tree().create_timer(interval_ms / 1000.0)
		t.timeout.connect(ctx["fn"])

	ctx["fn"] = step   # 先赋值再连接，保证闭包拿到的不是 null

	var t0: SceneTreeTimer = service.get_tree().create_timer(0.05)
	t0.timeout.connect(ctx["fn"])


func _emit_typewriter_stable(request_id: int, npc_id: String, reply: Dictionary, service: Node) -> void:
	var content: String = String(reply.get("text", "……"))
	if content.is_empty():
		content = "……"
	var context := {
		"completed": false,
		"content": content,
		"npc_id": npc_id,
		"reply": reply,
		"service": service,
	}
	_pending_typewriters[request_id] = context
	service.deliver_reply_started(request_id, npc_id, String(reply.get("mood", "")), content)
	# 统一使用每字 0.08 秒的打字机速度。
	var chunk_size := 1
	var chunk_interval := 0.08
	var total := content.length()
	for end_index in range(chunk_size, total + chunk_size, chunk_size):
		await get_tree().create_timer(chunk_interval).timeout
		if bool(context.get("completed", false)):
			return
		if not is_instance_valid(service) or not service.is_request_active(request_id):
			context["completed"] = true
			_pending_typewriters.erase(request_id)
			return
		var visible_length := mini(end_index, total)
		service.deliver_chunk(request_id, npc_id, content.substr(0, visible_length))
		if visible_length >= total:
			break
	_complete_typewriter(request_id, context, false)


func fast_forward_request(request_id: int) -> bool:
	if not _pending_typewriters.has(request_id):
		return false
	var context: Dictionary = _pending_typewriters[request_id]
	if bool(context.get("completed", false)):
		return false
	return _complete_typewriter(request_id, context, true)


func _complete_typewriter(request_id: int, context: Dictionary, reveal_full_text: bool) -> bool:
	if bool(context.get("completed", false)):
		return false
	var service := context.get("service") as Node
	if not is_instance_valid(service) or not service.is_request_active(request_id):
		context["completed"] = true
		_pending_typewriters.erase(request_id)
		return false
	context["completed"] = true
	_pending_typewriters.erase(request_id)
	var npc_id := String(context.get("npc_id", ""))
	var content := String(context.get("content", "……"))
	if reveal_full_text:
		service.deliver_chunk(request_id, npc_id, content)
	var reply: Dictionary = context.get("reply", {})
	reply["meta"] = {}
	reply["npc_id"] = npc_id
	service.deliver_reply(request_id, npc_id, reply)
	return true


func cancel_request(request_id: int) -> void:
	if _pending_typewriters.has(request_id):
		var context: Dictionary = _pending_typewriters[request_id]
		context["completed"] = true
		_pending_typewriters.erase(request_id)
	if _active_http.has(request_id):
		var http: HTTPRequest = _active_http[request_id]
		_active_http.erase(request_id)
		if is_instance_valid(http):
			http.cancel_request()
			http.queue_free()
	_req_started_usec.erase(request_id)


func _build_request_headers() -> PackedStringArray:
	var headers := PackedStringArray(["Content-Type: application/json"])
	if send_authorization:
		headers.append("Authorization: Bearer " + api_key)
	return headers


## 记忆总结：让模型基于旧记忆 + 最近对话产出新的记忆文档（≤ SUMMARY_MAX_CHARS）。
## 结果一律作为纯文本返回，不做 JSON 反序列化。
func summarize(npc_profile: Dictionary, previous_summary: String, recent_turns: Array, service: Node) -> void:
	if not is_instance_valid(service):
		return
	var npc_id: String = String(npc_profile.get("id", "?"))
	if send_authorization and api_key.strip_edges() == "":
		service.deliver_summary_failure(npc_id, "api_key 为空，无法生成记忆")
		return

	var display_name := String(npc_profile.get("display_name", "该角色"))
	var system_prompt := """你是一个记忆整理助手。请为 NPC「%s」维护一份第一人称的"关键印象笔记"。
输入包含：
1) 上一版记忆文档（可能为空）
2) 最近的几轮 NPC 与玩家对话

要求：
- 输出一份**更新后**的记忆文档，用 NPC 的第一人称口吻记录他/她对玩家目前所记得的关键印象。
- 保留旧记忆里仍然重要的条目，把最近对话中出现的新事实、玩家表现出的态度、承诺、争执、被追问的敏感话题等合并进去；相互矛盾时以最新对话为准。
- 用短句列点或段落均可，务必精炼，不超过 400 字。
- 不要复读原始对话原文，不要出现"上一版记忆"字样。
- 不要输出 JSON、Markdown 代码块或额外解释，直接输出记忆正文。""" % display_name

	var user_lines: PackedStringArray = []
	user_lines.append("【上一版记忆】")
	user_lines.append(previous_summary if previous_summary.strip_edges() != "" else "（还没有记忆）")
	user_lines.append("")
	user_lines.append("【最近对话】")
	for entry in recent_turns:
		if entry is not Dictionary:
			continue
		var role := String((entry as Dictionary).get("role", ""))
		var text := String((entry as Dictionary).get("text", "")).strip_edges()
		if text == "":
			continue
		if role == "user":
			user_lines.append("玩家：" + text)
		elif role == "npc":
			user_lines.append("我（%s）：%s" % [display_name, text])

	var payload := {
		"model": model_name,
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": "\n".join(user_lines)},
		],
		"temperature": 0.3,
		"max_tokens": 600,
		"stream": false,
	}

	var http := HTTPRequest.new()
	http.timeout = request_timeout
	http.body_size_limit = http_max_body_bytes
	add_child(http)

	var url := base_url.rstrip("/") + "/chat/completions"
	var headers := _build_request_headers()

	http.request_completed.connect(
		func(result: int, response_code: int, _hs: PackedStringArray, body: PackedByteArray):
			_on_summary_completed(result, response_code, body, npc_id, service, http)
	)

	# tracer hook
	if tracer != null and is_instance_valid(tracer) and tracer.has_method("on_summary_request"):
		tracer.call("on_summary_request", npc_id, previous_summary, recent_turns, payload["messages"])
	_req_started_usec[-1] = Time.get_ticks_usec()  # 用 -1 存 summary 起始时间（同时刻最多一个）

	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		http.queue_free()
		service.deliver_summary_failure(npc_id, "记忆请求发起失败，err=%d" % err)


func _on_summary_completed(result: int, response_code: int, body: PackedByteArray, npc_id: String, service: Node, http: HTTPRequest) -> void:
	if is_instance_valid(http):
		http.queue_free()
	if not is_instance_valid(service):
		return
	var text := body.get_string_from_utf8()
	# tracer hook
	if tracer != null and is_instance_valid(tracer) and tracer.has_method("on_summary_raw_response"):
		var started_usec: int = int(_req_started_usec.get(-1, Time.get_ticks_usec()))
		var latency_ms: int = int((Time.get_ticks_usec() - started_usec) / 1000)
		tracer.call("on_summary_raw_response", npc_id, response_code, text, latency_ms)
	_req_started_usec.erase(-1)
	if result != HTTPRequest.RESULT_SUCCESS:
		service.deliver_summary_failure(npc_id, "记忆请求网络错误 result=%d" % result)
		return
	if response_code < 200 or response_code >= 300:
		service.deliver_summary_failure(npc_id, "记忆请求 HTTP %d" % response_code)
		return
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		service.deliver_summary_failure(npc_id, "记忆响应非 JSON")
		return
	if (parsed as Dictionary).has("error"):
		service.deliver_summary_failure(npc_id, "记忆响应错误")
		return
	var choices: Array = (parsed as Dictionary).get("choices", [])
	if choices.is_empty():
		service.deliver_summary_failure(npc_id, "记忆响应缺 choices")
		return
	var raw_content: String = String((choices[0] as Dictionary).get("message", {}).get("content", "")).strip_edges()
	if raw_content == "":
		service.deliver_summary_failure(npc_id, "记忆响应为空")
		return
	service.deliver_summary(npc_id, raw_content)


func _build_messages(profile: Dictionary, history: Array, user_text: String) -> Array:
	var messages: Array = []
	var system_prompt := String(profile.get("system_prompt", ""))
	if system_prompt == "":
		system_prompt = "你是 %s。只根据明确提供的信息，用自然简短的日常口语回答；不知道就直说，不编造。" % profile.get("display_name", "?")
	# 在请求出口统一注入真实背包，覆盖私聊、公聊和专用 LLM 请求，避免上层遗漏。
	if not system_prompt.contains("【玩家当前持有】"):
		system_prompt += "\n\n" + ItemDB.build_inventory_prompt_block(GameState.inventory)
	system_prompt += DialoguePromptScript.SHARED_CONTRACT

	messages.append({"role": "system", "content": system_prompt})

	# Few-shot only teaches voice. Unsafe/adversarial player examples are omitted,
	# and assistant examples never carry generated choices.
	var fewshots: Array = profile.get("fewshots", [])
	# Voice examples are useful, but six messages (three pairs) are sufficient and
	# avoid paying for the same characterization on every request.
	var pair_limit := mini(fewshots.size(), 6)
	var index := 0
	while index + 1 < pair_limit:
		var user_example: Dictionary = fewshots[index]
		var assistant_example: Dictionary = fewshots[index + 1]
		if (
			user_example.get("role", "") == "user"
			and assistant_example.get("role", "") == "assistant"
			and _is_training_example_safe(String(user_example.get("content", "")), profile)
		):
			messages.append({"role": "user", "content": String(user_example.get("content", ""))})
			messages.append({
				"role": "assistant",
				"content": JSON.stringify({"text": String(assistant_example.get("content", ""))}),
			})
		index += 2

	var previous_choices: PackedStringArray = []
	var last_npc_text := ""
	for entry in history:
		var role := String(entry.get("role", ""))
		var text := String(entry.get("text", ""))
		if text == "":
			continue
		if role == "user":
			messages.append({"role": "user", "content": text})
		elif role == "npc":
			messages.append({"role": "assistant", "content": JSON.stringify({"text": text})})
			last_npc_text = text
			var old_choices: Variant = entry.get("choices", [])
			if old_choices is Array:
				for old_choice in old_choices:
					var old_text := String(old_choice).strip_edges()
					if old_text != "" and not previous_choices.has(old_text):
						previous_choices.append(old_text)

	var current_prompt := user_text
	if not previous_choices.is_empty():
		current_prompt += "\n\n【系统补充】以下建议已经出现过，本轮不得原样重复：" + "；".join(previous_choices)
	if last_npc_text != "":
		# 只提醒避免复读，不根据上一轮字数强制本轮长短。
		var snippet: String = last_npc_text if last_npc_text.length() <= 80 else last_npc_text.substr(0, 80) + "…"
		current_prompt += "\n\n【系统补充】你上一轮说过：「%s」。本轮请避免机械复读；篇幅完全按当前问题需要决定，复杂问题可以完整展开。" % snippet
	messages.append({"role": "user", "content": current_prompt})
	return messages

func _parse_model_reply(raw_content: String, prior_context: String = "", current_user_text: String = "", profile: Dictionary = {}) -> Dictionary:
	return SuggestionGuard.parse(raw_content, prior_context, current_user_text, profile)


func _history_text(history: Array) -> String:
	return SuggestionGuard.history_text(history)


func _is_training_example_safe(text: String, profile: Dictionary) -> bool:
	return SuggestionGuard.training_example_is_safe(text, profile)

static func _truncate(s: String, n: int) -> String:
	if s.length() <= n: return s
	return s.substr(0, n) + "..."
