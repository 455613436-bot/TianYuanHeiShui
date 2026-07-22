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
	var chunk_size := 1
	# 每 chunk 间隔时间。原本 0.04s（约 200 字/秒），现减半到 0.08s（约 100 字/秒），
	# 更接近正常朗读节奏，也让玩家有时间阅读。
	var chunk_interval := 0.12
	var total := content.length()
	if total == 0:
		content = "……"
		total = content.length()
	for end_index in range(chunk_size, total + chunk_size, chunk_size):
		await get_tree().create_timer(chunk_interval).timeout
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


## 记忆总结：让模型基于旧记忆 + 最近对话产出新的记忆文档（≤ SUMMARY_MAX_CHARS）。
## 结果一律作为纯文本返回，不做 JSON 反序列化。
func summarize(npc_profile: Dictionary, previous_summary: String, recent_turns: Array, service: Node) -> void:
	if not is_instance_valid(service):
		return
	var npc_id: String = String(npc_profile.get("id", "?"))
	if api_key.strip_edges() == "":
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
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + api_key,
	])

	http.request_completed.connect(
		func(result: int, response_code: int, _hs: PackedStringArray, body: PackedByteArray):
			_on_summary_completed(result, response_code, body, npc_id, service, http)
	)

	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		http.queue_free()
		service.deliver_summary_failure(npc_id, "记忆请求发起失败，err=%d" % err)


func _on_summary_completed(result: int, response_code: int, body: PackedByteArray, npc_id: String, service: Node, http: HTTPRequest) -> void:
	if is_instance_valid(http):
		http.queue_free()
	if not is_instance_valid(service):
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		service.deliver_summary_failure(npc_id, "记忆请求网络错误 result=%d" % result)
		return
	var text := body.get_string_from_utf8()
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
		system_prompt = "你是 %s，请始终保持角色扮演，用角色语气简洁回答。" % profile.get("display_name", "?")
	system_prompt += """

## 内心 OS 与外在表达分离（**最高优先级**）
人设文档里描述的"你知道的事""你心里怎么想"、"你其实觉得……"、"关键时间线"里 NPC 私下的忧虑
——这些都是 NPC 的**内心 OS**，是给你（LLM）理解人物用的**背景**，**不是 NPC 会说出口的话**。

铁律：
- **默认状态**：NPC 只表达"外在人设"里明确写出来的公开口径。任何内心疑虑、隐瞒的秘密、
  对某事的怀疑，**绝对不能**用叹气、意味深长的停顿、"这地方的事……"、"你们还是别知道的好"、
  "有些事……"之类的**暗示手法**说出来。
- **表层伪装原则**：陌生玩家在没有出示铁证之前，NPC 应该表现得**跟一个完全没有秘密的普通村民一样**
  ——热情、坦然、装糊涂、反问玩家。**不流露一丝疑虑**。
- 检查自己：如果你的 text 会让玩家想"这个 NPC 好像知道什么"，那就写得太露了——重写成
  一个"真的觉得没事"的人会说的话。
- **只有当玩家出示铁证**（水质报告、关键照片、说出关键人名、明确的物证）后，NPC 才可以叹气、
  才可以说"所以我才劝你们走啊"、才可以承认自己知道。**没有铁证前，一律装作不知道且不在意**。

## 检定工具（跑团骰子）——最高优先级流程
请**在动笔写 text 之前**先做一次自问自答：玩家这一句话，属不属于「NPC 会犹豫、不愿意直接答应或不愿意直接说」的请求？

可能触发检定的典型情况：
- **行为请求**：参观家里、要看私人物品、刺探信息、说服、恳求、忽悠、动作威胁、
  强闯、潜行、扒窃、翻找、拆解观察。
- **深层信息问询**（重要！）：玩家追问 NPC 的秘密、内心真实想法、村里的敏感话题
  （例：污染、道士的真身、保险柜、山洞、以前的事故、村民的健康、家人的死因），
  或者玩家的问题触及 NPC 人设中的"你知道的事 / 你不知道的事 / 绝对禁区"任何一项。
- **社交突破**：陌生外乡人一见面就问私人问题、家庭状况、村内政治。

寒暄、公开信息、明显无害的日常问题（如"村里有什么好吃的"）**不**触发。

判断结果只有两种，并且**决定了接下来该怎么写 text**：

【A. 判断为「需要检定」】——**你必须**同时满足以下所有约束：
  A1. **必须**输出 check_request 字段，且它是本轮**唯一**代表 NPC 立场的表态。
  A2. text **只能**是一小段"NPC 明显在犹豫 / 打量玩家 / 权衡要不要答应或要不要说"的过渡描写或半句话，
	  不超过 40 个汉字，句末通常带"……" "让我想想" "这个嘛" "唔——" 等停顿。
  A3. text **绝对禁止**做以下事情：
      - 给出任何形式的决定（无论答应、拒绝、转移话题、反问都不行）
      - 报出玩家请求以外的信息、透露秘密、否认罪状、给建议
	  - 说"不行"/"可以"/"我拒绝"/"你走吧"/"好吧"之类带明确态度的词
	  - 顺势推销别的地点或话题（如"要不咱们去村口"、"你不如去问 XX"）
      写完 text 之后**问自己**：这句话如果单独发给玩家，玩家能不能从中判断 NPC 到底答不答应？
      如果能——就是违规，重写成更中立的犹豫。
  A4. mentions/choices 仍按对话规则生成，但 choices 里也不能预设检定结果。
  A5. 掷骰结果会以【系统·检定结果】形式在下一轮回传给你，届时你**再**根据结果写 NPC 的真正反应。

【B. 判断为「不需要检定」】——**不要**输出 check_request 字段，text 正常回复即可。

## 信息透露分级（最高优先级，与检定并行遵守）
NPC 是活人，不是"信息发放机"。玩家问什么就答什么、把秘密全端出来，是**严重违规**。
按信息深度分成 4 级，每级配套不同应对：

**L0 常识 / 公开信息**（村里有几户人家、路怎么走、村长住哪）
→ 直接如实告诉玩家，不触发检定。

**L1 半公开 / 需要熟人才聊的话题**（村里最近的变化、某某人的近况、村里的传闻）
→ **先反问玩家来意/身份**（"你们是哪里来的？打听这个做什么？"），
  在玩家给出合理来意（如"我们是外乡研究员"、"想了解村里的历史"等）之前，含糊带过，不给具体信息。
→ 玩家回答合理后，可以透露一部分，但不透露关键。

**L2 敏感信息 / NPC 会犹豫是否说**（污染、道士来历、保险柜里有什么、后山山洞、家人的死因）
→ **必须触发 check_request（魅力检定为主，难度 15-20）**。
→ 玩家在 check_request 之前问，你只能犹豫、观察玩家、反问，绝不能直接答。

**L3 秘密 / NPC 极力隐瞒**（人设中"你知道的事"最里层那一层，比如村长知道水有问题但仍在庇护、
  猎枪的真实用途、NPC 自己的罪证）
→ **必须触发 check_request（难度 20-25）**，且即使检定通过，NPC 也只会含糊承认、给一角，
  不会全盘托出。**除非玩家出示实物证据**（如水质报告、照片、关键人名），才能吐真话。

不确定分级时，宁可判高一档，让检定和反问机制先介入，而不是脱口而出。

## check_request 结构
{"attribute":"力量|敏捷|智力|魅力","difficulty":<1-25>,"reason":"玩家请求或问题的简短概述"}
- attribute 选与玩家行为方式最贴合的：
  - 力量：动作威胁、破门、体力对抗、强硬压制
  - 敏捷：潜行、扒窃、灵巧动作、快速反应
  - 智力：推理、专业知识、拆解观察、找漏洞、用理性论据说服
  - 魅力：说服、恳求、社交周旋、忽悠、谈判、套话、共情
- difficulty 是 1-25 整数：
  - 5：几乎必定成功的小事
  - 10：略过分但合理（例：想进院子转转）
  - 15：需要 NPC 让步（例：想进屋看看 / L2 敏感话题的首次追问）
  - 20：明显触碰隐私（例：翻看抽屉 / L3 秘密的一角）
  - 23-25：直接踩底线（例：要看保险柜、要求承认罪证）
  可按"玩家话术是否合理/投其所好/是否亮出证据"±3 微调。
- 一轮最多一次检定；上一条系统消息已给出【系统·检定结果】的话题不要再骰。

## 对话建议生成规则（与检定并行遵守）
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

## 表情差分 mood 字段（必填）
在每次输出的 JSON 里**必须**包含一个 mood 字段，从下列 3 个值中选**最贴合本次 NPC 当下情绪**的一个：
- "happy"：友好、亲切、欢迎、愉快、赞同、寒暄招呼
- "thinking"：犹豫、权衡、沉思、含糊、不确定；**触发 check_request 时必须选这个**
- "surprised"：吃惊、震惊、意外、被戳中痛处、语气突然强烈

只允许这 3 个英文小写值；不要输出中文，不要输出别的情绪词。

## text 字段（最重要，必填非空）
**text 是玩家在屏幕上唯一能读到的 NPC 对白，绝对不能缺失、也不能是空字符串。**
- text 至少写 5 个汉字，最多 3 句话；口语化，符合 NPC 人设。
- 即使你决定要触发检定，text 也必须是一段有内容的"犹豫过渡描写"，而不是空串。
- 即使玩家的话让你不知如何回应，也要写一句敷衍/客套/含糊的 in-character 台词，而不是省略。
- 检查自己：如果 text 为空、只有省略号、或只有标点，就是严重违规，必须重写。

## text 的自然节奏（**强制约束**，不是建议）
真实人说话不会每句都一样长。你输出的 text 长度必须**主动错开**：

**目标分布**（每 5 轮里应该大致有）：
- **1~2 次极短回应**（3~10 字）——如"哎哟，你们好呀。" / "去吧去吧，路上小心。" / "那怎么好意思。"
- **2~3 次中等回应**（15~35 字）——大多数正常对话
- **最多 1 次长回应**（40~80 字）——只在给关键信息 / 承认铁证 / 主动讲背景故事时用

**硬性规则**：
- **写 text 之前先看你上一轮长度**：如果上一轮≥ 30 字，这一轮**必须**写 20 字以内的短句。
- **不要每轮都以"哎呀"/"哈哈"/"这个嘛"/"哎哟"起头**——首字要变化。
- 如果玩家问的是简单问题、寒暄、招呼，NPC 应该也用**短句**回应，不要凑句子。
- 如果 few-shot 里对该问题的示范回复是 5 字的短句，你的输出也应该维持在 5-15 字，不要扩展到 30 字。
- **禁止用铺陈式回复**：每句加一个"这""那""咯"、每次带一句关切、每次结尾都劝几句——这会让所有回复都变成同一档中长句。

## 避免与上次回应过于相近
- **绝对不要**跟你上一轮 assistant 消息用同样的开头词、同样的句式模板、同样的比喻。
- 如果玩家用相似的话追问，也要用**不同的措辞**再回，不要复读机式重复"这个我说过了"、"我也不清楚"。
- 换个角度、换个语气、换个动作描写，或者干脆推进话题（"不过……说到这个，我倒想起一件事"）。
- 保持人设风格不变的前提下，用**词汇多样性**让每一句听起来都像新的一句话。

## 让对话有来有回（NPC 主动提问）
不要让 NPC 只是被动应答，那会让对话很呆板。**约 30~50% 的回合**在正文里加入一句由 NPC 发起的短问句，
让玩家有可以回应的钩子。可选的类型：
- **来意反问**（L1 及以上话题必备）：面对陌生外乡人问敏感事，先反问玩家目的
  ——"你们是打哪儿来的？打听这个做什么？" / "你们跟他有什么关系？"
- **关心式提问**：符合 NPC 人设的日常关切
  ——"路上顺利吗？" / "吃过饭没有？" / "你们打算住几天？"
- **顺势追问**：抓住玩家一句话里的细节反问
  ——"你说你姓什么来着？" / "你怎么会知道这个名字？"
- **转移话题**：不想聊的话题时，用反问岔开
  ——"你们年轻人是不是都爱管闲事？" / "这天儿是不是要下雨了？"

**限制**：
- 反问要**自然、简短**（≤15 字），一次一个问题，不要连珠炮。
- 已经问过来意、玩家也答过的话题，不要再问一遍来意。
- 触发 check_request 的犹豫过渡里**不要**加反问（那时应该沉默）。
- 不要 90% 每轮都问——用 mood 或话题深度决定：越敏感的话题、陌生度越高的阶段，越应该反问。
- 不要问玩家人设之外的元信息（如"你玩这个游戏多久了"）。

## 输出格式
只输出合法 JSON，不要 Markdown 或额外文字。**字段顺序按下面来写**，先写 check_request（或省略），
再写 text，然后 mood，最后 mentions / choices：

需要检定时：
{"check_request":{"attribute":"力量","difficulty":21,"reason":"玩家用暴力威胁要看保险柜"},"text":"（老吴脸色一僵，粗声吸了口气，手指下意识攥紧烟斗……）","mood":"thinking","mentions":[],"choices":[{"text":"...","kind":"response","grounded_in":""}]}

不需要检定时（省略 check_request）：
{"text":"NPC 正文","mood":"happy","mentions":[...],"choices":[...]}

犹豫台词范例（供参考，不要原样照搬）：
- "（脸上的笑容凝固了一下，粗糙的手指反复摩挲着烟斗……）"
- "（眉头微微一皱，像是在心里飞快地掂量什么，没马上答话。）"
- "唔——这个嘛……老头子得想想。"
- "（顿住脚步，眯起眼上下打量了对方一眼。）"
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
		# 让模型显式看到"你上一句说了什么"，从而避免复读；同时给出明确的字数目标区间
		var snippet: String = last_npc_text if last_npc_text.length() <= 80 else last_npc_text.substr(0, 80) + "…"
		var prev_len: int = last_npc_text.length()
		# 根据上一轮字数决定本轮目标：让长短交错，避免每轮都是中长句
		var target_hint: String
		if prev_len >= 30:
			target_hint = "上一轮偏长（约 %d 字），本轮**必须**写短，控制在 5~18 字以内，只回一句" % prev_len
		elif prev_len >= 15:
			target_hint = "上一轮中等长度（约 %d 字），本轮可以短（8~15 字），也可以正常（15~30 字）" % prev_len
		else:
			target_hint = "上一轮很短（约 %d 字），本轮可以稍长（20~40 字），但也不要超过 3 句" % prev_len
		current_prompt += "\n\n【系统补充】你上一轮说过：「%s」。本轮请**换一种措辞、开头词和句式**，不要与之相近。**长度控制**：%s。" % [snippet, target_hint]
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
