extends Node
## MockLLM
## 假 LLM —— 用「关键词命中 fallback_lines / 场景化台词」模拟真实回复。
## 现在 meta（污染/好感/道具/线索）由 LLMService 统一计算，Mock 只负责生成 text。
##
## Provider 契约：
##   generate(npc_profile, history, user_text, service)
##   完成后调用 service.deliver_reply(npc_id, {text, meta?})
##   或 service.deliver_failure(npc_id, error)

const THINKING_DELAY_MS_MIN := 500
const THINKING_DELAY_MS_MAX := 1200

var _cancelled_requests: Dictionary = {}


func generate(request_id: int, npc_profile: Dictionary, _history: Array, user_text: String, service: Node) -> void:
	if _cancelled_requests.erase(request_id) or not is_instance_valid(service) or not service.is_request_active(request_id):
		return
	var delay_ms := randi_range(THINKING_DELAY_MS_MIN, THINKING_DELAY_MS_MAX)
	await get_tree().create_timer(delay_ms / 1000.0).timeout
	if not is_instance_valid(service) or not service.is_request_active(request_id):
		return

	var npc_id: String = String(npc_profile.get("id", "?"))
	var text := _pick_reply(npc_profile, user_text)
	var choices := _build_choices(npc_profile, user_text)
	service.deliver_reply(request_id, npc_id, {"text": text, "choices": choices, "meta": {}, "npc_id": npc_id})


func cancel_request(request_id: int) -> void:
	_cancelled_requests[request_id] = true


func _pick_reply(profile: Dictionary, user_text: String) -> String:
	# 首先尝试从 few-shot 里找一条 assistant 回复作为随机响应
	var fewshots: Array = profile.get("fewshots", [])
	var assistant_lines: Array = []
	for m in fewshots:
		if m.get("role", "") == "assistant":
			assistant_lines.append(String(m.get("content", "")))

	# 如果玩家输入命中了 few-shot 里对应的 user 行，就返回下一条 assistant
	var lower := user_text.to_lower()
	for i in range(fewshots.size() - 1):
		var m: Dictionary = fewshots[i]
		var m2: Dictionary = fewshots[i + 1]
		if m.get("role", "") != "user": continue
		if m2.get("role", "") != "assistant": continue
		var u := String(m.get("content", ""))
		if _similar(user_text, u) or _similar(lower, u.to_lower()):
			return String(m2.get("content", ""))

	# 否则用 fallback_lines 或随机 assistant 台词
	var fallbacks: Array = profile.get("fallback_lines", [])
	if fallbacks.is_empty(): fallbacks = assistant_lines
	if fallbacks.is_empty():
		var style: String = String(profile.get("style_hint", ""))
		return "（%s）……" % style if style != "" else "……"
	return String(fallbacks[randi() % fallbacks.size()])


## 简单相似判断：任一方包含另一方前 6 个字符
static func _similar(a: String, b: String) -> bool:
	if a == "" or b == "": return false
	var min_ab: int = min(a.length(), b.length())
	var n: int = min(6, min_ab)
	var pref_a := a.substr(0, n)
	var pref_b := b.substr(0, n)
	return a.contains(pref_b) or b.contains(pref_a)


func _build_choices(_profile: Dictionary, user_text: String) -> Array[String]:
	# Mock 只提供安全的通用选项，不再把人设 few-shot 中的未来提问泄露给玩家。
	var candidates: Array[String] = [
		"这件事能再说详细一点吗？",
		"为什么你会这么认为？",
		"后来又发生了什么？",
	]
	var result: Array[String] = []
	for choice in candidates:
		if choice != user_text:
			result.append(choice)
	return result