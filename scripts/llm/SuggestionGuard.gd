extends RefCounted
## 对 LLM 返回的玩家建议做知识边界、剧透和相关性校验。

const DEFAULT_FORBIDDEN_TERMS: Array[String] = [
	"iphone", "chatgpt", "人工智能", "提示词", "大模型", "语言模型",
]
const GENERIC_ENTITY_NAMES: Array[String] = [
	"村子", "村里", "这里", "那里", "那边", "事情", "东西", "大家", "年轻人", "老人",
]
const GREETING_CHOICES: Array[String] = [
	"您好，我是刚到村里的。",
	"我想了解一下村里的近况。",
	"最近村里有没有发生什么特别的事？",
	"您是这里的村长吗？",
	"我只是四处看看，顺便认识一下大家。",
]
const SAFE_GENERIC_CHOICES: Array[String] = [
	"这件事能再说详细一点吗？",
	"为什么你会这么认为？",
	"后来又发生了什么？",
	"这件事最早是什么时候发生的？",
	"当时还有谁在场？",
	"你是从哪里知道这件事的？",
	"这件事对村里有什么影响？",
	"还有什么细节是我遗漏的吗？",
	"你对此最担心的是什么？",
	"我们也可以换个话题。",
]

static func parse(raw_content: String, prior_context: String, current_user_text: String, profile: Dictionary) -> Dictionary:
	var fallback_text := raw_content.strip_edges()
	if fallback_text == "":
		fallback_text = "……"

	# 抽取真正的 JSON 主体：去掉 markdown 代码块围栏，再用括号平衡找完整对象
	var json_body := _extract_json_object(fallback_text)
	if json_body == "":
		return _fallback_reply(fallback_text, prior_context, current_user_text, profile)

	var parsed = JSON.parse_string(json_body)
	if typeof(parsed) != TYPE_DICTIONARY:
		return _fallback_reply(fallback_text, prior_context, current_user_text, profile)

	var reply_text := ""
	for key in ["text", "reply", "content", "message"]:
		if parsed.has(key) and not (parsed[key] is Dictionary or parsed[key] is Array):
			reply_text = String(parsed[key]).strip_edges()
			if reply_text != "":
				break
	# 主 key 未命中或值为空时，尝试从 JSON 里其它字符串字段抢救出一段人话
	# （避免直接给玩家一个空 "……"，同时不泄漏 raw JSON）
	if reply_text == "":
		reply_text = _salvage_text_from_parsed(parsed)
	# 依然没抢救出：给一个中性的场景描述，让开场不至于空白
	if reply_text == "":
		reply_text = "……（对方看着你，一时没开口。）"

	var knowledge_context := prior_context + "\n" + current_user_text
	var new_mentions := _parse_new_mentions(parsed.get("mentions", []), reply_text, knowledge_context, profile)
	var raw_choices: Variant = []
	for key in ["choices", "options", "suggestions"]:
		if parsed.has(key):
			raw_choices = parsed[key]
			break
	var choice_values: Array = []
	if raw_choices is Array:
		choice_values = raw_choices
	elif raw_choices is String:
		choice_values = String(raw_choices).split("\n", false)

	var grounded_choices: Array[String] = []
	var other_choices: Array[String] = []
	var valid_model_choices := 0
	for item in choice_values:
		var choice := ""
		var kind := ""
		var grounded_in := ""
		if item is Dictionary:
			choice = String(item.get("text", item.get("content", ""))).strip_edges()
			kind = String(item.get("kind", "")).strip_edges().to_lower()
			grounded_in = String(item.get("grounded_in", "")).strip_edges()
		else:
			choice = String(item).strip_edges()
		for prefix in ["- ", "• ", "1. ", "2. ", "3. ", "1、", "2、", "3、"]:
			choice = choice.trim_prefix(prefix)
		choice = choice.left(80)
		if not _choice_is_safe(choice, grounded_in, reply_text, knowledge_context, profile):
			continue
		valid_model_choices += 1
		if kind == "follow_up" and grounded_in != "" and _mention_is_new(grounded_in, new_mentions):
			if not grounded_choices.has(choice):
				grounded_choices.append(choice)
		elif not other_choices.has(choice):
			other_choices.append(choice)

	# 模型漏写追问时，本地为本轮首次出现的实体补足 1～2 条。
	var wanted_grounded := mini(2, new_mentions.size())
	for mention in new_mentions:
		if grounded_choices.size() >= wanted_grounded:
			break
		var generated := _make_followup(mention)
		if _choice_is_safe(generated, String(mention.get("name", "")), reply_text, knowledge_context, profile):
			_append_unique(grounded_choices, generated)

	var choices: Array[String] = []
	for choice in grounded_choices:
		_append_unique(choices, choice)
		if choices.size() >= 2:
			break
	for choice in other_choices:
		if choices.size() >= 3:
			break
		_append_unique(choices, choice)
	_fill_safe_choices(choices, reply_text, knowledge_context, profile)

	var check_request := _parse_check_request(parsed.get("check_request", null))
	# 若本轮触发检定，则强制把 text 收敛为一段"NPC 正在犹豫"的中性过渡句，
	# 防止 LLM 一次把"完整拒绝/答复"和"检定"同时输出，让玩家看到"回复→骰→再回复"的三段体。
	if not check_request.is_empty():
		reply_text = _sanitize_hesitation_text(reply_text, profile)

	# 道具工具：item_used（玩家使用/出示了物品）+ item_request（NPC 要求玩家出示）
	# 通用意图工具：offer_request（NPC 主动送物 / 请求玩家做某事 → 玩家点接受/拒绝）
	# 它们都可能占用 choice_row，优先级：check_request > offer_request > item_request > 普通 choices
	var item_used := _parse_item_used(parsed.get("item_used", null))
	var item_request := _parse_item_request(parsed.get("item_request", null))
	var offer_request := _parse_offer_request(parsed.get("offer_request", null))
	if not check_request.is_empty():
		# 有检定则丢掉 item_request / offer_request（避免 UI 冲突），
		# 但保留 item_used（玩家可能在检定同轮出示了道具作为筹码）
		item_request = {}
		offer_request = {}
	elif not offer_request.is_empty():
		# offer_request 已经占用了选项区，不再叠加 item_request
		item_request = {}

	# 透传 mood 字段（值由 DialogueUI/MoodPortrait 侧再做归一化和白名单校验，
	# 这里只保留原始字符串，避免耦合 UI 层的常量）
	var mood_raw: String = ""
	var mood_value: Variant = parsed.get("mood", null)
	if mood_value is String:
		mood_raw = String(mood_value).strip_edges().to_lower()
		if mood_raw.length() > 20:
			mood_raw = ""
	# 公聊使用 speak 决定该 NPC 是否发言；未提供时维持默认发言。
	var speak := true
	var speak_value: Variant = parsed.get("speak", true)
	if speak_value is bool:
		speak = bool(speak_value)
	elif speak_value is String:
		speak = String(speak_value).strip_edges().to_lower() != "false"

	return {
		"text": reply_text,
		"choices": choices,
		"mentions": new_mentions,
		"format_valid": valid_model_choices >= 2,
		"check_request": check_request,
		"item_used": item_used,
		"item_request": item_request,
		"offer_request": offer_request,
		"mood": mood_raw,
		"speak": speak,
		"action": _parse_action(parsed.get("action", null)),
	}


## 若 text 看起来已经给出决定性回答（答应 / 拒绝 / 转移话题），把它替换为中性犹豫过渡句。
## 只有非常明显是"纯犹豫描写"的 text 才会原样保留。
const _HESITATION_FALLBACKS: Array[String] = [
	"（对方神情微微一凝，手指下意识地攥紧，一时没答话……）",
	"（眉头轻皱，像是在心里飞快地掂量什么，没马上开口。）",
	"唔——这个嘛，让我想想……",
	"（顿住脚步，眯起眼上下打量了一下，没作声。）",
	"（对方明显犹豫了一下，脸上闪过复杂的神色。）",
]
## 表示"已经给出决定"的关键词——命中即视为违规
const _DECISIVE_MARKERS: Array[String] = [
	"没啥好看的", "没什么好看的", "没什么可看", "没啥可看",
	"不能", "不行", "不可以", "拒绝",
	"好吧", "行吧", "可以", "答应你", "满足你",
	"你走吧", "滚开", "滚出去", "别在这", "别再来",
	"要不", "不如", "咱们去", "咱去", "换个话题",
	"我告诉你", "让我告诉", "其实是", "实话跟你说",
]

static func _sanitize_hesitation_text(text: String, _profile: Dictionary) -> String:
	var trimmed := text.strip_edges()
	if trimmed == "":
		return _pick_hesitation_fallback()
	# 过长本身就不像犹豫过渡（阈值宽一点，避免误伤合法的犹豫描写）
	if trimmed.length() > 60:
		return _pick_hesitation_fallback()
	# 命中"决定性"关键词就直接替换
	for marker in _DECISIVE_MARKERS:
		if trimmed.contains(marker):
			return _pick_hesitation_fallback()
	# 出现问号 / 感叹号且不是纯语气词，通常代表已经作出反应
	if (trimmed.contains("？") or trimmed.contains("?")) and not trimmed.begins_with("（") and not trimmed.begins_with("("):
		return _pick_hesitation_fallback()
	if trimmed.contains("！") or trimmed.contains("!"):
		return _pick_hesitation_fallback()
	return trimmed


static func _pick_hesitation_fallback() -> String:
	if _HESITATION_FALLBACKS.is_empty():
		return "（对方沉默了一下，没马上答话……）"
	return _HESITATION_FALLBACKS[randi() % _HESITATION_FALLBACKS.size()]


## 智能提取一段可解析的 JSON 对象字符串。
## 处理：
##   - 前后 markdown 代码块围栏 ``` 或 ```json
##   - 前后中/英文散文
##   - 多段并列时只取第一个平衡完整的 {...}
##   - 忽略字符串内部的 { }（走引号状态机）
## 找不到就返回 ""。
static func _extract_json_object(raw: String) -> String:
	var text := raw.strip_edges()
	if text == "":
		return ""

	# 去掉常见的 markdown 代码块围栏
	text = _strip_code_fences(text)

	# 用括号平衡 + 引号状态机找第一个完整的 { ... }
	var start := text.find("{")
	if start < 0:
		return ""
	var depth := 0
	var in_string := false
	var escape := false
	for i in range(start, text.length()):
		var ch: String = text[i]
		if in_string:
			if escape:
				escape = false
			elif ch == "\\":
				escape = true
			elif ch == "\"":
				in_string = false
			continue
		if ch == "\"":
			in_string = true
			continue
		if ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				return text.substr(start, i - start + 1)
	return ""


## 剥掉 ```json ... ``` / ``` ... ``` 这种 markdown 代码块包裹
static func _strip_code_fences(text: String) -> String:
	var trimmed := text.strip_edges()
	if not trimmed.begins_with("```"):
		# 也可能围栏在中间；粗暴替换掉所有围栏行
		trimmed = trimmed.replace("```json", "").replace("```JSON", "").replace("```Json", "")
		trimmed = trimmed.replace("```", "")
		return trimmed.strip_edges()
	# 去掉开头围栏
	var first_newline := trimmed.find("\n")
	if first_newline >= 0:
		trimmed = trimmed.substr(first_newline + 1)
	else:
		trimmed = trimmed.substr(3)
	# 去掉结尾围栏
	var last_fence := trimmed.rfind("```")
	if last_fence >= 0:
		trimmed = trimmed.substr(0, last_fence)
	return trimmed.strip_edges()


## 粗略判断字符串看起来像 JSON（未成功解析但含大括号+引号+冒号），
## 用于在完全解析失败时防止把 raw JSON 泄漏给玩家。
static func _looks_like_json(text: String) -> bool:
	if text.length() < 8:
		return false
	if not (text.contains("{") and text.contains("}")):
		return false
	# 至少一对 "xxx": 的模式
	var quote_idx := text.find("\"")
	if quote_idx < 0:
		return false
	# 简单启发：出现 " 后面接 :，或者出现 "text" / "reply" / "choices" 之一
	for probe in ["\"text\"", "\"reply\"", "\"content\"", "\"message\"", "\"choices\"", "\"check_request\"", "\"mood\""]:
		if text.contains(probe):
			return true
	# 兜底：形如 "..." : ... 的模式
	return text.contains("\":") or text.contains("\" :")


## 从解析成功的 dict 里抢救一段"能给玩家看的文字"。
## 场景：LLM 忘了填 text/reply/content/message，但把内容塞到了 dialogue / say / speech / npc_text
## 之类的自造字段里。这里再多兜住一层，找不到才让上层用最终占位。
const _META_KEYS: Array[String] = [
	# 已知的非"正文"字段，遍历时跳过
	"text", "reply", "content", "message",
	"mood", "attribute", "difficulty", "reason",
	"kind", "grounded_in", "type", "name",
	"mentions", "choices", "options", "suggestions",
	"check_request", "meta", "npc_id", "streaming",
	"pollution_delta", "affinity_delta", "clue_id", "give_item",
	"item_used", "item_request", "item_id", "action", "target",
	"consumed", "candidates",
	"offer_request", "kind", "action_id", "prompt",
	"accept_label", "decline_label", "accept_text", "decline_text",
]

static func _salvage_text_from_parsed(parsed: Dictionary) -> String:
	# 优先：明显"像正文"的自造字段名
	for candidate_key in ["dialogue", "say", "speech", "npc_text", "narration", "response", "answer", "line", "utterance"]:
		if parsed.has(candidate_key):
			var v: Variant = parsed[candidate_key]
			if v is String:
				var s := String(v).strip_edges()
				if s.length() >= 2:
					return s
	# 次优：遍历所有字符串字段，找一个非元数据键且长度合适的
	for key in parsed.keys():
		if not (key is String):
			continue
		if _META_KEYS.has(String(key).to_lower()):
			continue
		var val: Variant = parsed[key]
		if not (val is String):
			continue
		var s2 := String(val).strip_edges()
		if s2.length() >= 4 and s2.length() <= 500:
			return s2
	return ""








static func _parse_check_request(value: Variant) -> Dictionary:
	## 校验 LLM 返回的 check_request，非法则返回空 dict
	if value is not Dictionary:
		return {}
	var raw: Dictionary = value
	var attribute_raw: String = String(raw.get("attribute", "")).strip_edges()
	if attribute_raw == "":
		return {}
	var difficulty_raw: Variant = raw.get("difficulty", 0)
	if not (difficulty_raw is int or difficulty_raw is float):
		return {}
	var difficulty := int(difficulty_raw)
	# 只接受工具契约允许的 1-25 范围，超出则视为格式非法
	if difficulty < 1 or difficulty > 25:
		return {}
	var reason: String = String(raw.get("reason", "")).strip_edges()
	# 长度上限，避免 LLM 灌超长文本
	if reason.length() > 160:
		reason = reason.substr(0, 160)
	return {
		"attribute": attribute_raw,
		"difficulty": difficulty,
		"reason": reason,
	}


## 解析 LLM 承认玩家在本轮使用/出示了某件道具。
## 结构：{"item_id":"<id 或 display_name>", "action":"show|give|use_on_self|use_on_target",
##       "target":"<npc_id>可空", "consumed":<bool>}
## 只做「字段级」浅校验：id 非空、字符串长度合理；
## 「玩家是否真的持有」交给 DialogueUI._handle_item_used 做运行时复核（那里能访问 GameState）。
static func _parse_item_used(value: Variant) -> Dictionary:
	if value is not Dictionary:
		return {}
	var raw: Dictionary = value
	var item_id: String = String(raw.get("item_id", "")).strip_edges()
	if item_id.is_empty() or item_id.length() > 40:
		return {}
	var action: String = String(raw.get("action", "show")).strip_edges().to_lower()
	if not ["show", "give", "use_on_self", "use_on_target"].has(action):
		action = "show"
	var target: String = String(raw.get("target", "")).strip_edges()
	if target.length() > 40:
		target = target.substr(0, 40)
	var consumed: bool = false
	if raw.has("consumed"):
		consumed = bool(raw.get("consumed", false))
	return {
		"item_id": item_id,
		"action": action,
		"target": target,
		"consumed": consumed,
	}


## 解析 LLM 请求玩家出示物品的 item_request。
## 结构：{"candidates":["<item_id>",...], "reason":"<为什么想看>"}
## 校验后 candidates 至少 1 条、每项字符串长度合理、去重。
static func _parse_item_request(value: Variant) -> Dictionary:
	if value is not Dictionary:
		return {}
	var raw: Dictionary = value
	var raw_candidates: Variant = raw.get("candidates", [])
	if not (raw_candidates is Array):
		return {}
	var candidates: Array = []
	for c in raw_candidates:
		var id_str: String = String(c).strip_edges()
		if id_str.is_empty() or id_str.length() > 40:
			continue
		if not candidates.has(id_str):
			candidates.append(id_str)
		if candidates.size() >= 6:
			break
	if candidates.is_empty():
		return {}
	var reason: String = String(raw.get("reason", "")).strip_edges()
	if reason.length() > 160:
		reason = reason.substr(0, 160)
	return {
		"candidates": candidates,
		"reason": reason,
	}


## 人物地点固定，忽略模型的 action 行程字段。
static func _parse_action(_value: Variant) -> Dictionary:
	return {}


## 解析 LLM 主动向玩家提出的"提议 / 请求"，玩家将用"接受/拒绝"两个按钮回应。
## 目前支持的 kind：
##   - "give_item"      NPC 想送玩家一件物品；需要 item_id
##   - "request_item"   NPC 想向玩家索要/借用一件物品；需要 item_id
##   - "request_action" NPC 请求玩家做某事（跟我走、等等我、帮我看着……）；建议给 action_id
##   - "custom"         其他自定义 yes/no 决策；仅依赖 prompt + accept/decline_text
static func _parse_offer_request(value: Variant) -> Dictionary:
	if value is not Dictionary:
		return {}
	var raw: Dictionary = value
	var kind: String = String(raw.get("kind", "")).strip_edges().to_lower()
	var allowed_kinds := ["give_item", "request_item", "request_action", "custom"]
	if not allowed_kinds.has(kind):
		return {}

	var item_id: String = String(raw.get("item_id", "")).strip_edges()
	if item_id.length() > 40:
		item_id = ""
	if (kind == "give_item" or kind == "request_item") and item_id.is_empty():
		return {}

	var action_id: String = String(raw.get("action_id", "")).strip_edges()
	if action_id.length() > 40:
		action_id = action_id.substr(0, 40)

	var prompt_text: String = String(raw.get("prompt", "")).strip_edges()
	if prompt_text.is_empty() or prompt_text.length() > 160:
		# prompt 是给玩家看的一句话总结，缺失或过长都视为无效
		if prompt_text.length() > 160:
			prompt_text = prompt_text.substr(0, 160)
		else:
			return {}

	var accept_label: String = _clip_label(raw.get("accept_label", ""), _default_accept_label(kind))
	var decline_label: String = _clip_label(raw.get("decline_label", ""), _default_decline_label(kind))
	var accept_text: String = _clip_reply(raw.get("accept_text", ""), _default_accept_text(kind))
	var decline_text: String = _clip_reply(raw.get("decline_text", ""), _default_decline_text(kind))

	return {
		"kind": kind,
		"item_id": item_id,
		"action_id": action_id,
		"prompt": prompt_text,
		"accept_label": accept_label,
		"decline_label": decline_label,
		"accept_text": accept_text,
		"decline_text": decline_text,
	}


static func _clip_label(value: Variant, fallback: String) -> String:
	var s: String = String(value).strip_edges()
	if s.is_empty():
		return fallback
	if s.length() > 12:
		s = s.substr(0, 12)
	return s


static func _clip_reply(value: Variant, fallback: String) -> String:
	var s: String = String(value).strip_edges()
	if s.is_empty():
		return fallback
	if s.length() > 60:
		s = s.substr(0, 60)
	return s


static func _default_accept_label(kind: String) -> String:
	match kind:
		"give_item": return "收下"
		"request_item": return "给他"
		"request_action": return "答应"
		_: return "好"


static func _default_decline_label(kind: String) -> String:
	match kind:
		"give_item": return "婉拒"
		"request_item": return "不给"
		"request_action": return "拒绝"
		_: return "不"


static func _default_accept_text(kind: String) -> String:
	match kind:
		"give_item": return "那我收下了，谢谢。"
		"request_item": return "拿去吧。"
		"request_action": return "好，我答应你。"
		_: return "好。"


static func _default_decline_text(kind: String) -> String:
	match kind:
		"give_item": return "不必了，谢谢你的好意。"
		"request_item": return "这个恐怕不方便给你。"
		"request_action": return "抱歉，做不到。"
		_: return "还是算了吧。"


static func history_text(history: Array) -> String:
	var parts := PackedStringArray()
	for entry in history:
		var text := String(entry.get("text", "")).strip_edges()
		if text != "":
			parts.append(text)
		var choices: Variant = entry.get("choices", [])
		if choices is Array:
			for choice in choices:
				parts.append(String(choice))
	return "\n".join(parts)


static func training_example_is_safe(text: String, profile: Dictionary) -> bool:
	if _contains_forbidden_term(text, profile):
		return false
	# 受线索保护的示例不能进入上下文，否则模型可能提前把秘密建议给玩家。
	var locks: Variant = profile.get("choice_locks", {})
	if locks is Dictionary:
		for clue_id in locks:
			var terms: Variant = locks[clue_id]
			if terms is Array:
				for term in terms:
					if text.to_lower().contains(String(term).to_lower()):
						return false
	return true


static func _fallback_reply(reply_text: String, prior_context: String, current_user_text: String, profile: Dictionary) -> Dictionary:
	# 如果 raw 看起来像 JSON 但主路径没能解析出来，说明 LLM 输出了畸形 JSON。
	# 直接把它当 text 展示会让玩家看到 { "text": ... } 一堆花括号，非常糟糕。
	# 此时用中性占位覆盖，并打一条 warning 方便定位。
	var display_text := reply_text
	if _looks_like_json(reply_text):
		push_warning("[SuggestionGuard] LLM 输出疑似畸形 JSON，已回退为中性文本；原文前 200 字: %s" % reply_text.substr(0, 200))
		display_text = "……"
	var choices: Array[String] = []
	_fill_safe_choices(choices, display_text, prior_context + "\n" + current_user_text, profile)
	return {"text": display_text, "choices": choices, "mentions": [], "format_valid": false, "check_request": {}, "item_used": {}, "item_request": {}, "offer_request": {}, "mood": ""}


static func _parse_new_mentions(raw_mentions: Variant, reply_text: String, knowledge_context: String, profile: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not raw_mentions is Array:
		return result
	var type_aliases := {
		"person": "person", "人物": "person",
		"place": "place", "地点": "place",
		"item": "item", "物品": "item",
		"event": "event", "事件": "event",
	}
	for value in raw_mentions:
		if not value is Dictionary:
			continue
		var name := String(value.get("name", "")).strip_edges()
		var entity_type := String(value.get("type", "")).strip_edges().to_lower()
		if name.length() < 2 or name.length() > 24:
			continue
		if not reply_text.contains(name) or knowledge_context.contains(name):
			continue
		if GENERIC_ENTITY_NAMES.has(name) or not type_aliases.has(entity_type):
			continue
		if _contains_forbidden_term(name, profile) or _contains_locked_term(name, knowledge_context, profile):
			continue
		var duplicate := false
		for existing in result:
			if existing.get("name", "") == name:
				duplicate = true
				break
		if not duplicate:
			result.append({"name": name, "type": type_aliases[entity_type]})
	return result


static func _choice_is_safe(choice: String, grounded_in: String, reply_text: String, knowledge_context: String, profile: Dictionary) -> bool:
	if choice == "" or knowledge_context.contains(choice):
		return false
	if grounded_in != "" and not reply_text.contains(grounded_in):
		return false
	if _is_mechanical_echo(choice, reply_text):
		return false
	if _contains_forbidden_term(choice, profile):
		return false
	if _contains_locked_term(choice, knowledge_context, profile):
		return false
	return true


static func _is_mechanical_echo(choice: String, reply_text: String) -> bool:
	var mechanical_question := (
		choice.contains("详细一点")
		or choice.contains("具体一些")
		or choice.contains("还知道些什么")
		or choice.contains("再说说")
	)
	if choice.begins_with("你刚才说") and mechanical_question:
		return true
	if _is_greeting(reply_text) and mechanical_question:
		return true
	return false

static func _contains_forbidden_term(text: String, profile: Dictionary) -> bool:
	var lowered := text.to_lower()
	for term in DEFAULT_FORBIDDEN_TERMS:
		if lowered.contains(term):
			return true
	var custom_terms: Variant = profile.get("choice_forbidden_terms", [])
	if custom_terms is Array:
		for value in custom_terms:
			var term := String(value).strip_edges().to_lower()
			if term != "" and lowered.contains(term):
				return true
	return false


static func _contains_locked_term(text: String, knowledge_context: String, profile: Dictionary) -> bool:
	var locks: Variant = profile.get("choice_locks", {})
	if not locks is Dictionary:
		return false
	var unlocked: Variant = profile.get("unlocked_clues", [])
	for clue_id in locks:
		if unlocked is Array and unlocked.has(clue_id):
			continue
		var terms: Variant = locks[clue_id]
		if not terms is Array:
			continue
		for value in terms:
			var term := String(value).strip_edges()
			if term != "" and text.to_lower().contains(term.to_lower()) and not knowledge_context.to_lower().contains(term.to_lower()):
				return true
	return false


static func _mention_is_new(name: String, mentions: Array[Dictionary]) -> bool:
	for mention in mentions:
		if String(mention.get("name", "")) == name:
			return true
	return false


static func _make_followup(mention: Dictionary) -> String:
	var name := String(mention.get("name", ""))
	match String(mention.get("type", "")):
		"person": return "你刚提到的%s是谁？" % name
		"place": return "你说的%s在哪里？" % name
		"item": return "你提到的%s是做什么用的？" % name
		"event": return "关于%s，能再说详细一点吗？" % name
	return "关于%s，能再说详细一点吗？" % name


static func _append_unique(choices: Array[String], choice: String) -> void:
	if choice != "" and not choices.has(choice):
		choices.append(choice)


static func _fill_safe_choices(choices: Array[String], reply_text: String, knowledge_context: String, profile: Dictionary) -> void:
	# 寒暄不包含值得追问的事实，不能把整句问候机械套进“详细说说”模板。
	var candidates: Array[String] = (
		GREETING_CHOICES.duplicate()
		if _is_greeting(reply_text)
		else SAFE_GENERIC_CHOICES.duplicate()
	)

	# 优先使用尚未出现过的自然回应；实体追问已经在前面的 mentions 流程生成。
	for candidate in candidates:
		if choices.size() >= 3:
			break
		if _choice_is_safe(candidate, "", "", knowledge_context, profile):
			_append_unique(choices, candidate)

	# 历史去重不能让选项消失；候选耗尽时只复用安全自然句，不复述 NPC 原话。
	if choices.size() < 2:
		for candidate in candidates:
			if choices.size() >= 2:
				break
			if _contains_forbidden_term(candidate, profile):
				continue
			if _contains_locked_term(candidate, knowledge_context, profile):
				continue
			_append_unique(choices, candidate)


static func _is_greeting(reply_text: String) -> bool:
	var normalized := reply_text.to_lower().replace(" ", "")
	for marker in ["你好", "您好", "欢迎", "新面孔", "又来了", "来了啊", "哟", "哪位", "找谁", "什么事"]:
		if normalized.contains(marker):
			return true
	return false