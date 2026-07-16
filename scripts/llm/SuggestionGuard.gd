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
	var json_start := fallback_text.find("{")
	var json_end := fallback_text.rfind("}")
	if json_start < 0 or json_end <= json_start:
		return _fallback_reply(fallback_text, prior_context, current_user_text, profile)

	var parsed = JSON.parse_string(fallback_text.substr(json_start, json_end - json_start + 1))
	if typeof(parsed) != TYPE_DICTIONARY:
		return _fallback_reply(fallback_text, prior_context, current_user_text, profile)

	var reply_text := ""
	for key in ["text", "reply", "content", "message"]:
		if parsed.has(key) and not (parsed[key] is Dictionary or parsed[key] is Array):
			reply_text = String(parsed[key]).strip_edges()
			if reply_text != "":
				break
	if reply_text == "":
		reply_text = fallback_text

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

	return {
		"text": reply_text,
		"choices": choices,
		"mentions": new_mentions,
		"format_valid": valid_model_choices >= 2,
		"check_request": check_request,
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
	var choices: Array[String] = []
	_fill_safe_choices(choices, reply_text, prior_context + "\n" + current_user_text, profile)
	return {"text": reply_text, "choices": choices, "mentions": [], "format_valid": false, "check_request": {}}


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