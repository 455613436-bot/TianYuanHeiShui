extends Node
const SuggestionGuard = preload("res://scripts/llm/SuggestionGuard.gd")
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
var _active_http: Dictionary = {}


## 由 LLMService 调用
func generate(request_id: int, npc_profile: Dictionary, history: Array, user_text: String, service: Node) -> void:
	if not is_instance_valid(service) or not service.is_request_active(request_id):
		return
	var npc_id: String = String(npc_profile.get("id", "?"))

	if api_key.strip_edges() == "":
		service.deliver_failure(request_id, npc_id, "api_key 为空，请配置 llm_config.json")
		return

	var messages := _build_messages(npc_profile, history, user_text)
	var prior_context := _history_text(history)
	var payload := {
		"model": model_name,
		"messages": messages,
		"temperature": float(npc_profile.get("model", {}).get("temperature", 0.85)),
		"max_tokens": maxi(int(npc_profile.get("model", {}).get("max_tokens", 300)), 420),
		"stream": false,
	}

	var http := HTTPRequest.new()
	http.timeout = request_timeout
	http.body_size_limit = http_max_body_bytes
	add_child(http)
	_active_http[request_id] = http

	var url := base_url.rstrip("/") + "/chat/completions"
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + api_key,
	])

	http.request_completed.connect(
		func(result: int, response_code: int, _hs: PackedStringArray, body: PackedByteArray):
			_on_completed(result, response_code, body, request_id, npc_id, npc_profile, prior_context, user_text, service, http)
	)

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

	if result != HTTPRequest.RESULT_SUCCESS:
		var err_names := {
			2: "连接失败",
			3: "TLS握手失败",
			4: "无响应",
			5: "body超限",
			6: "请求超时",
		}
		var desc: String = err_names.get(result, "网络错误")
		service.deliver_failure(request_id, npc_id, "%s (result=%d)" % [desc, result])
		return

	var text := body.get_string_from_utf8()

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
	var chunk_size := 8
	var total := content.length()
	if total == 0:
		content = "……"
		total = content.length()
	for end_index in range(chunk_size, total + chunk_size, chunk_size):
		await get_tree().create_timer(0.04).timeout
		if not is_instance_valid(service) or not service.is_request_active(request_id):
			return
		var visible_length := mini(end_index, total)
		service.deliver_chunk(request_id, npc_id, content.substr(0, visible_length))
		if visible_length >= total:
			break
	reply["meta"] = {}
	reply["npc_id"] = npc_id
	service.deliver_reply(request_id, npc_id, reply)


func cancel_request(request_id: int) -> void:
	if not _active_http.has(request_id):
		return
	var http: HTTPRequest = _active_http[request_id]
	_active_http.erase(request_id)
	if is_instance_valid(http):
		http.cancel_request()
		http.queue_free()


func _build_messages(profile: Dictionary, history: Array, user_text: String) -> Array:
	var messages: Array = []
	var system_prompt := String(profile.get("system_prompt", ""))
	if system_prompt == "":
		system_prompt = "你是 %s，请始终保持角色扮演，用角色语气简洁回答。" % profile.get("display_name", "?")
	system_prompt += """

## 对话建议生成规则（最高优先级）
你同时要生成 2～3 条玩家下一步可以直接说出口的建议，但建议只能来自玩家当前已经知道的内容。
- NPC 人设中的秘密、禁区和内部知识不是玩家知识，绝不能因为它们出现在 system prompt 或 few-shot 中就写进建议。
- few-shot 的玩家提问只用于展示 NPC 如何回答，绝不是建议问题素材。
- 先从本次 NPC 正文中找出首次出现、且正文逐字包含的人物、地点、物品或事件，写入 mentions。
- 如果存在新 mentions，choices 中必须有 1～2 条 follow_up，追问这些新信息。
- 每条 follow_up 的 grounded_in 必须逐字出现在本次 NPC 正文中，不得引用仅存在于人设、秘密或旧示例里的词。
- 如果没有新信息，不要编造 mentions；改为围绕本轮正文继续询问或自然回应。
- 问候、欢迎、新面孔之类的寒暄不是可追问事件；禁止把 NPC 整句原话套进“能详细一点吗”或“还知道些什么”模板。
- 面对寒暄，建议玩家自然地自我介绍、说明来意，或主动询问村里的近况。
- 禁止现代越界测试、元话题、无关科技、剧透和玩家尚未获得的线索。
- 建议应简短、自然、含义不同，不能替玩家决定行动结果，也不能重复历史建议。

只输出合法 JSON，不要 Markdown 或额外文字：
{"text":"NPC 正文","mentions":[{"name":"正文中的名称","type":"person|place|item|event"}],"choices":[{"text":"玩家可直接说的话","kind":"follow_up|response|topic_shift","grounded_in":"follow_up 所依据的正文原词，其他类型可为空"}]}
"""

	messages.append({"role": "system", "content": system_prompt})

	# Few-shot only teaches voice. Unsafe/adversarial player examples are omitted,
	# and assistant examples never carry generated choices.
	var fewshots: Array = profile.get("fewshots", [])
	var pair_limit := mini(fewshots.size(), 12)
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
	for entry in history:
		var role := String(entry.get("role", ""))
		var text := String(entry.get("text", ""))
		if text == "":
			continue
		if role == "user":
			messages.append({"role": "user", "content": text})
		elif role == "npc":
			messages.append({"role": "assistant", "content": JSON.stringify({"text": text})})
			var old_choices: Variant = entry.get("choices", [])
			if old_choices is Array:
				for old_choice in old_choices:
					var old_text := String(old_choice).strip_edges()
					if old_text != "" and not previous_choices.has(old_text):
						previous_choices.append(old_text)

	var current_prompt := user_text
	if not previous_choices.is_empty():
		current_prompt += "\n\n【系统补充】以下建议已经出现过，本轮不得原样重复：" + "；".join(previous_choices)
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
