extends Node
## MemoryStore
## 记忆系统 autoload：
## 1) 全局记忆 global_memory：村庄级共享的关键事件条目（自然语言），
##    所有 NPC 都能在 system prompt 里看到。
## 2) NPC 原始对话历史 npc_histories[npc_id]：仅保留最近 MAX_TURNS 轮
##    (一轮 = 一对 user + npc)，退出会话不清空。system 提示行不进入这里。
## 3) NPC 总结记忆文档 npc_summaries[npc_id]：每 SUMMARIZE_EVERY_TURNS 轮
##    触发一次异步 LLM 更新，把最近 5 轮浓缩到已有记忆文档上。
##
## 数据都会随 GameState.save_game() / load_game() 一起持久化。

signal history_updated(npc_id: String)
signal summary_updated(npc_id: String, summary: String)
signal global_memory_added(entry: Dictionary)

const MAX_TURNS: int = 15               ## 每个 NPC 保留的最大轮次
const SUMMARIZE_EVERY_TURNS: int = 5    ## 每累积多少轮触发一次总结
const GLOBAL_MEMORY_LIMIT: int = 40     ## 全局记忆条目上限（滑动窗口）
const SUMMARY_MAX_CHARS: int = 2000     ## 单个 NPC 记忆文档最长字符数（LLM 输出会被截断）
const NPC_TURNS_TO_SEND_LLM: int = 15   ## 每次请求送给 LLM 的最近轮次数
const MEM_VERSION: int = 1

## npc_id -> Array[Dictionary{role, text}]，role in {"user", "npc"}
var npc_histories: Dictionary = {}
## npc_id -> String，LLM 生成的记忆文档；也可能是本地兜底
var npc_summaries: Dictionary = {}
## npc_id -> int，从上次总结起，已积累的新轮次数（用于触发 5 轮阈值）
var _turns_since_summary: Dictionary = {}
## npc_id -> bool，是否有一个正在飞行的总结请求（避免并发）
var _summarize_inflight: Dictionary = {}
## 全局记忆：Array[Dictionary{ts:int, text:String, tags:Array[String]}]
var global_memory: Array = []


# ─── NPC 原始对话历史 ──────────────────────────────────────────────────────

func get_history(npc_id: String) -> Array:
	if npc_id.is_empty():
		return []
	var raw: Variant = npc_histories.get(npc_id, [])
	if raw is Array:
		return (raw as Array).duplicate(true)
	return []


func append_turn(npc_id: String, user_text: String, npc_text: String, npc_choices: Array = []) -> void:
	## 追加一对 user + npc 到历史。system 提示行绝不进入。
	if npc_id.is_empty():
		return
	user_text = user_text.strip_edges()
	npc_text = npc_text.strip_edges()
	if user_text == "" and npc_text == "":
		return
	var list: Array = npc_histories.get(npc_id, [])
	if list is not Array:
		list = []
	if user_text != "":
		list.append({"role": "user", "text": user_text})
	if npc_text != "":
		var npc_entry := {"role": "npc", "text": npc_text}
		if not npc_choices.is_empty():
			var normalized: Array[String] = []
			for c in npc_choices:
				var s := String(c).strip_edges()
				if s != "":
					normalized.append(s)
			if not normalized.is_empty():
				npc_entry["choices"] = normalized
		list.append(npc_entry)
	list = _trim_turns(list, MAX_TURNS)
	npc_histories[npc_id] = list
	_turns_since_summary[npc_id] = int(_turns_since_summary.get(npc_id, 0)) + 1
	history_updated.emit(npc_id)


func _trim_turns(list: Array, max_turns: int) -> Array:
	## 从尾部往前数 max_turns 个 user 行，把最靠前的多余 user + 后续 npc 一起丢弃
	var kept_pairs := 0
	for i in range(list.size() - 1, -1, -1):
		if String(list[i].get("role", "")) == "user":
			kept_pairs += 1
			if kept_pairs > max_turns:
				return list.slice(i + 1)
	return list


func clear_history(npc_id: String) -> void:
	if npc_id.is_empty():
		return
	npc_histories.erase(npc_id)
	_turns_since_summary[npc_id] = 0
	history_updated.emit(npc_id)


# ─── NPC 独立记忆文档（总结） ─────────────────────────────────────────────

func get_summary(npc_id: String) -> String:
	return String(npc_summaries.get(npc_id, ""))


func set_summary(npc_id: String, summary: String) -> void:
	if npc_id.is_empty():
		return
	var trimmed := summary.strip_edges()
	if trimmed.length() > SUMMARY_MAX_CHARS:
		trimmed = trimmed.substr(0, SUMMARY_MAX_CHARS).strip_edges() + "…"
	npc_summaries[npc_id] = trimmed
	summary_updated.emit(npc_id, trimmed)


func should_summarize(npc_id: String) -> bool:
	## 每累积 SUMMARIZE_EVERY_TURNS 轮触发一次
	var accum := int(_turns_since_summary.get(npc_id, 0))
	return accum >= SUMMARIZE_EVERY_TURNS and not bool(_summarize_inflight.get(npc_id, false))


func mark_summarize_started(npc_id: String) -> void:
	_summarize_inflight[npc_id] = true


func mark_summarize_finished(npc_id: String, success: bool) -> void:
	_summarize_inflight[npc_id] = false
	if success:
		_turns_since_summary[npc_id] = 0


func get_recent_turns_for_summary(npc_id: String, turns: int = SUMMARIZE_EVERY_TURNS) -> Array:
	## 取最近 N 对 user+npc（可能不足）
	var list: Array = npc_histories.get(npc_id, [])
	if list is not Array or list.is_empty():
		return []
	var user_indices: Array[int] = []
	for i in range(list.size()):
		if String(list[i].get("role", "")) == "user":
			user_indices.append(i)
	if user_indices.is_empty():
		return list.duplicate(true)
	var start_index: int = user_indices[maxi(0, user_indices.size() - turns)]
	return list.slice(start_index).duplicate(true)


# ─── 全局记忆 ─────────────────────────────────────────────────────────────

func add_global_memory(text: String, tags: Array = []) -> void:
	var trimmed := text.strip_edges()
	if trimmed == "":
		return
	if trimmed.length() > 240:
		trimmed = trimmed.substr(0, 240).strip_edges() + "…"
	# 去重：最近 5 条完全相同的就不重复插
	for i in range(maxi(0, global_memory.size() - 5), global_memory.size()):
		if String((global_memory[i] as Dictionary).get("text", "")) == trimmed:
			return
	var clean_tags: Array[String] = []
	for t in tags:
		var ts := String(t).strip_edges()
		if ts != "" and not clean_tags.has(ts):
			clean_tags.append(ts)
	var entry := {
		"ts": int(Time.get_unix_time_from_system()),
		"text": trimmed,
		"tags": clean_tags,
	}
	global_memory.append(entry)
	if global_memory.size() > GLOBAL_MEMORY_LIMIT:
		global_memory = global_memory.slice(global_memory.size() - GLOBAL_MEMORY_LIMIT)
	global_memory_added.emit(entry)


func get_global_memory_text() -> String:
	if global_memory.is_empty():
		return ""
	var lines: PackedStringArray = []
	for entry in global_memory:
		var text := String((entry as Dictionary).get("text", ""))
		if text != "":
			lines.append("- " + text)
	return "\n".join(lines)


# ─── LLM Prompt 组装 ─────────────────────────────────────────────────────

func build_memory_prompt_block(npc_id: String) -> String:
	## 组装成一段可直接拼到 system_prompt 末尾的记忆上下文
	var parts: PackedStringArray = []
	var global_text := get_global_memory_text()
	if global_text != "":
		parts.append("## 村庄共享记忆（所有村民共知的近期事件）\n" + global_text)
	var summary := get_summary(npc_id)
	if summary != "":
		parts.append("## 你（该 NPC）与玩家的既往关键印象\n" + summary)
	if parts.is_empty():
		return ""
	return "\n\n" + "\n\n".join(parts) + "\n\n（以上是你的记忆，用于保持对话连贯，不要主动复读上述文字。）"


# ─── 持久化 ───────────────────────────────────────────────────────────────

func to_dict() -> Dictionary:
	return {
		"mem_version": MEM_VERSION,
		"npc_histories": _sanitize_histories(npc_histories),
		"npc_summaries": _sanitize_summaries(npc_summaries),
		"turns_since_summary": _sanitize_int_dict(_turns_since_summary),
		"global_memory": _sanitize_global_memory(global_memory),
	}


func load_from_dict(data: Variant) -> void:
	reset()
	if data is not Dictionary:
		return
	var d: Dictionary = data
	var version_value: Variant = d.get("mem_version", 0)
	var version: int = int(version_value) if (version_value is int or version_value is float) else 0
	if version != MEM_VERSION:
		# 未知/更旧版本：安全丢弃
		return
	npc_histories = _sanitize_histories(d.get("npc_histories", {}))
	npc_summaries = _sanitize_summaries(d.get("npc_summaries", {}))
	_turns_since_summary = _sanitize_int_dict(d.get("turns_since_summary", {}))
	global_memory = _sanitize_global_memory(d.get("global_memory", []))


func reset() -> void:
	npc_histories.clear()
	npc_summaries.clear()
	_turns_since_summary.clear()
	_summarize_inflight.clear()
	global_memory.clear()


# ─── Sanitizers ──────────────────────────────────────────────────────────

func _sanitize_histories(value: Variant) -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	for key in (value as Dictionary):
		if key is not String:
			continue
		var raw: Variant = value[key]
		if raw is not Array:
			continue
		var list: Array = []
		for entry in raw:
			if entry is not Dictionary:
				continue
			var role := String((entry as Dictionary).get("role", ""))
			var text := String((entry as Dictionary).get("text", ""))
			if role != "user" and role != "npc":
				continue
			if text.strip_edges() == "":
				continue
			var clean: Dictionary = {"role": role, "text": text}
			var choices_raw: Variant = (entry as Dictionary).get("choices", null)
			if choices_raw is Array:
				var choices: Array[String] = []
				for c in (choices_raw as Array):
					var cs := String(c).strip_edges()
					if cs != "":
						choices.append(cs)
				if not choices.is_empty():
					clean["choices"] = choices
			list.append(clean)
		result[key] = _trim_turns(list, MAX_TURNS)
	return result


func _sanitize_summaries(value: Variant) -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	for key in (value as Dictionary):
		if key is not String:
			continue
		var text := String(value[key]).strip_edges()
		if text == "":
			continue
		if text.length() > SUMMARY_MAX_CHARS:
			text = text.substr(0, SUMMARY_MAX_CHARS).strip_edges() + "…"
		result[key] = text
	return result


func _sanitize_int_dict(value: Variant) -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	for key in (value as Dictionary):
		if key is not String:
			continue
		var v: Variant = value[key]
		if v is int or v is float:
			result[key] = maxi(0, int(v))
	return result


func _sanitize_global_memory(value: Variant) -> Array:
	var result: Array = []
	if value is not Array:
		return result
	for entry in (value as Array):
		if entry is not Dictionary:
			continue
		var text := String((entry as Dictionary).get("text", "")).strip_edges()
		if text == "":
			continue
		var ts_raw: Variant = (entry as Dictionary).get("ts", 0)
		var ts: int = int(ts_raw) if (ts_raw is int or ts_raw is float) else 0
		var tags_raw: Variant = (entry as Dictionary).get("tags", [])
		var tags: Array[String] = []
		if tags_raw is Array:
			for t in (tags_raw as Array):
				var ts_str := String(t).strip_edges()
				if ts_str != "" and not tags.has(ts_str):
					tags.append(ts_str)
		result.append({"ts": ts, "text": text, "tags": tags})
	if result.size() > GLOBAL_MEMORY_LIMIT:
		result = result.slice(result.size() - GLOBAL_MEMORY_LIMIT)
	return result
