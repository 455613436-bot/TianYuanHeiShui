extends Node
## OpenAILLM
## 兼容 OpenAI Chat Completions 协议的 LLM Provider（非流式稳定版）。
## 用 HTTPRequest 一次性拿完整回复，UI 侧用定时器模拟逐字打字机效果。
##
## 兼容 endpoint：DeepSeek / OpenAI / 通义千问 / 智谱 GLM / 月之暗面 / Ollama 等。

@export var api_key: String = ""
@export var base_url: String = "https://api.deepseek.com/v1"
@export var model_name: String = "deepseek-chat"
@export var request_timeout: float = 30.0
@export var http_max_body_bytes: int = 4 * 1024 * 1024

## 由 LLMService 调用
func generate(npc_profile: Dictionary, history: Array, user_text: String, service: Node) -> void:
	var npc_id: String = String(npc_profile.get("id", "?"))

	if api_key.strip_edges() == "":
		service.deliver_failure(npc_id, "api_key 为空，请配置 llm_config.json")
		return

	var messages := _build_messages(npc_profile, history, user_text)
	var payload := {
		"model": model_name,
		"messages": messages,
		"temperature": float(npc_profile.get("model", {}).get("temperature", 0.85)),
		"max_tokens": int(npc_profile.get("model", {}).get("max_tokens", 300)),
		"stream": false,
	}

	var http := HTTPRequest.new()
	http.timeout = request_timeout
	http.body_size_limit = http_max_body_bytes
	add_child(http)

	var url := base_url.rstrip("/") + "/chat/completions"
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + api_key,
	])

	http.request_completed.connect(
		func(result: int, response_code: int, _hs: PackedStringArray, body: PackedByteArray):
			_on_completed(result, response_code, body, npc_id, service, http)
	)

	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		service.deliver_failure(npc_id, "发起 HTTP 请求失败，err=%d" % err)
		http.queue_free()


func _on_completed(result: int, response_code: int, body: PackedByteArray, npc_id: String, service: Node, http: HTTPRequest) -> void:
	http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS:
		var err_names := {
			2: "连接失败",
			3: "TLS握手失败",
			4: "无响应",
			5: "body超限",
			6: "请求超时",
		}
		var desc: String = err_names.get(result, "网络错误")
		service.deliver_failure(npc_id, "%s (result=%d)" % [desc, result])
		return

	var text := body.get_string_from_utf8()

	if response_code < 200 or response_code >= 300:
		push_warning("[OpenAILLM] HTTP %d: %s" % [response_code, text.substr(0, 300)])
		service.deliver_failure(npc_id, "HTTP %d: %s" % [response_code, text.substr(0, 200)])
		return

	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		service.deliver_failure(npc_id, "响应非 JSON: " + text.substr(0, 150))
		return

	if parsed.has("error"):
		var msg = parsed["error"]
		if typeof(msg) == TYPE_DICTIONARY:
			msg = msg.get("message", str(msg))
		service.deliver_failure(npc_id, "API 错误: " + str(msg))
		return

	var choices: Array = parsed.get("choices", [])
	if choices.is_empty():
		service.deliver_failure(npc_id, "响应缺少 choices 字段: " + text.substr(0, 200))
		return

	var raw_content: String = String(choices[0].get("message", {}).get("content", "")).strip_edges()
	var model_reply := _parse_model_reply(raw_content)
	# 只对 NPC 正文做打字机效果，选项在正文完成后一起交给 UI。
	_emit_typewriter_stable(npc_id, model_reply, service)


## 把完整 content 分段发给 UI，制造逐字打字机效果
## 每 40ms 发一段（约 8 字），让玩家感觉字在"流"出来
func _emit_typewriter(npc_id: String, reply: Dictionary, service: Node) -> void:
	var content: String = String(reply.get("text", "……"))
	var chunk_size: int = 8
	var interval_ms: int = 40
	var total: int = content.length()
	# 把所有可变状态 + callable 引用放进同一个 dict，
	# 避免 GDScript 闭包捕获 null callable 或 int 值拷贝的问题
	var ctx: Dictionary = {"i": 0, "fn": Callable()}

	var step: Callable = func():
		if ctx["i"] >= total:
			reply["meta"] = {}
			reply["npc_id"] = npc_id
			service.deliver_reply(npc_id, reply)
			return
		ctx["i"] = mini(int(ctx["i"]) + chunk_size, total)
		service.deliver_chunk(npc_id, content.substr(0, int(ctx["i"])))
		var t: SceneTreeTimer = service.get_tree().create_timer(interval_ms / 1000.0)
		t.timeout.connect(ctx["fn"])

	ctx["fn"] = step   # 先赋值再连接，保证闭包拿到的不是 null

	var t0: SceneTreeTimer = service.get_tree().create_timer(0.05)
	t0.timeout.connect(ctx["fn"])


func _emit_typewriter_stable(npc_id: String, reply: Dictionary, service: Node) -> void:
	var content: String = String(reply.get("text", "……"))
	var chunk_size := 8
	var total := content.length()
	if total == 0:
		content = "……"
		total = content.length()
	for end_index in range(chunk_size, total + chunk_size, chunk_size):
		await get_tree().create_timer(0.04).timeout
		if not is_instance_valid(service):
			return
		var visible_length := mini(end_index, total)
		service.deliver_chunk(npc_id, content.substr(0, visible_length))
		if visible_length >= total:
			break
	reply["meta"] = {}
	reply["npc_id"] = npc_id
	service.deliver_reply(npc_id, reply)


func _build_messages(profile: Dictionary, history: Array, user_text: String) -> Array:
	var messages: Array = []

	# 1. system prompt（人设全文）
	var sys_prompt: String = String(profile.get("system_prompt", ""))
	if sys_prompt == "":
		sys_prompt = "你是 %s，请始终保持角色扮演，用角色的语气回复，简洁口语化。" % profile.get("display_name", "?")
	sys_prompt += "\n\n【强制输出格式】只输出一个合法 JSON 对象，不要输出 Markdown 代码块或额外文字。格式为：{\"text\":\"NPC 的回复正文\",\"choices\":[\"玩家可说的选项1\",\"玩家可说的选项2\",\"玩家可说的选项3\"]}。choices 必须提供 2～3 个贴合当前最新回复、含义不同、可以直接由玩家说出口的简短选项；不要替玩家决定行动结果。参考历史中已经出现过的 choices，本轮禁止原样重复旧选项。"
	messages.append({"role": "system", "content": sys_prompt})

	# 2. few-shot 样例（最多取前 6 对，控制 prompt 长度）
	var fs: Array = profile.get("fewshots", [])
	var fs_limit: int = mini(fs.size(), 12)   # 6 对 = 12 条消息
	for i in range(fs_limit):
		var m: Dictionary = fs[i]
		var role := String(m.get("role", "user"))
		var content := String(m.get("content", ""))
		if role == "assistant":
			content = JSON.stringify({"text": content, "choices": _collect_fewshot_choices(fs, i)})
		messages.append({"role": role, "content": content})
	# 3. 对话历史
	for entry in history:
		var role: String = entry.get("role", "")
		var t: String = entry.get("text", "")
		if t == "": continue
		match role:
			"user":  messages.append({"role": "user",      "content": t})
			"npc":
				var previous_choices: Variant = entry.get("choices", [])
				messages.append({"role": "assistant", "content": JSON.stringify({"text": t, "choices": previous_choices})})
			_:       pass  # system 提示不进 LLM context

	# 4. 当前输入
	messages.append({"role": "user", "content": user_text})
	return messages



func _parse_model_reply(raw_content: String) -> Dictionary:
	var fallback_text := raw_content.strip_edges()
	if fallback_text == "":
		fallback_text = "……"
	var json_text := fallback_text
	var json_start := json_text.find("{")
	var json_end := json_text.rfind("}")
	if json_start >= 0 and json_end > json_start:
		json_text = json_text.substr(json_start, json_end - json_start + 1)

	var parsed = JSON.parse_string(json_text)
	if typeof(parsed) == TYPE_DICTIONARY:
		var reply_text := String(parsed.get("text", "")).strip_edges()
		if reply_text == "":
			reply_text = fallback_text
		var parsed_choices: Array[String] = []
		var raw_choices: Variant = parsed.get("choices", [])
		if raw_choices is Array:
			for item in raw_choices:
				var choice := String(item).strip_edges()
				if choice == "" or parsed_choices.has(choice):
					continue
				parsed_choices.append(choice.left(80))
				if parsed_choices.size() >= 3:
					break
		return {"text": reply_text, "choices": parsed_choices}

	return {"text": fallback_text, "choices": []}


func _collect_fewshot_choices(fewshots: Array, assistant_index: int) -> Array[String]:
	var result: Array[String] = []
	if fewshots.is_empty(): return result
	for offset in range(1, fewshots.size() + 1):
		var index := (assistant_index + offset) % fewshots.size()
		var candidate: Dictionary = fewshots[index]
		if candidate.get("role", "") != "user": continue
		var choice := String(candidate.get("content", "")).strip_edges()
		if choice == "" or result.has(choice): continue
		result.append(choice.left(80))
		if result.size() >= 3: break
	return result


static func _truncate(s: String, n: int) -> String:
	if s.length() <= n: return s
	return s.substr(0, n) + "..."
