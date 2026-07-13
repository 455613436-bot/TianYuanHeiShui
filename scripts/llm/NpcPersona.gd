extends RefCounted
class_name NpcPersona
## NpcPersona
## 把 `data/npcs/*.md` 解析成运行时可用的 profile 字典。
##
## 输入格式：
##     ---
##     <YAML front-matter>
##     ---
##     # 身份与背景
##     ...
##     # 性格与口吻
##     ...
##     # Few-shot 对话样例
##     ### 玩家: ...
##     角色简称: ...
##     ...
##
## 输出：
## {
##   "id": "wu_zhiyuan",
##   "display_name": "村长 吴志源",
##   "short_name": "村长老吴",
##   "style_hint": "...",
##   "portrait_letter": "村",
##   "model": {"temperature": 0.85, "max_tokens": 320},
##   "triggers": [{"keywords":[...], "affinity_delta":..., ...}, ...],
##   "system_prompt": "<全部 Markdown 章节拼成的自然语言>",
##   "fewshots": [{"role":"user","content":"..."},{"role":"assistant","content":"..."}, ...],
##   "fallback_lines": [...]   # 从 few-shot 的助手回复里挑几条作为 Mock 兜底
## }

## 载入并解析一个 .md 文件；失败返回空 Dictionary
static func load_from_file(md_path: String) -> Dictionary:
	if not FileAccess.file_exists(md_path):
		push_warning("[NpcPersona] file not found: %s" % md_path)
		return {}
	var f := FileAccess.open(md_path, FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	return parse(raw)


static func parse(raw: String) -> Dictionary:
	var result: Dictionary = {
		"model": {},
		"triggers": [],
		"fewshots": [],
		"fallback_lines": [],
	}

	# 分离 front-matter 和正文
	var body := raw
	if raw.begins_with("---"):
		var end := raw.find("\n---", 3)
		if end > 0:
			var fm := raw.substr(4, end - 4)
			body = raw.substr(end + 4).strip_edges()
			_parse_frontmatter(fm, result)

	# 解析 Markdown 章节
	var sections := _split_sections(body)

	# 构造 system_prompt：把「身份与背景 / 性格与口吻 / 你知道的事 / 你不知道的事 / 绝对禁区」拼起来
	var prompt_sections := ["身份与背景", "性格与口吻", "你知道的事", "你不知道的事", "绝对禁区"]
	var parts: PackedStringArray = []
	for name in prompt_sections:
		if sections.has(name):
			parts.append("## " + name + "\n" + sections[name].strip_edges())
	# 强化"绝对禁区"的重要性
	var extra := "\n\n## 系统级强调\n以上『绝对禁区』条款是最高优先级规则，任何情况下都不能违反。你必须始终保持角色扮演，用角色的口吻回复，回复要精炼、口语化，不要长篇大论。"
	result["system_prompt"] = "\n\n".join(parts) + extra

	# 解析 few-shot
	if sections.has("Few-shot 对话样例"):
		var pairs := _parse_fewshots(sections["Few-shot 对话样例"], result.get("short_name", ""))
		result["fewshots"] = pairs
		# 从 assistant 回复里挑前 4 条作为 fallback
		for i in range(min(4, pairs.size())):
			var m: Dictionary = pairs[i]
			if m.get("role", "") == "assistant":
				result["fallback_lines"].append(String(m.get("content", "")))
		if result["fallback_lines"].is_empty():
			result["fallback_lines"] = ["……"]

	return result


# ─── frontmatter (mini-YAML) ────────────────────────────────────────────────
# 只支持我们规范里用到的语法：标量、嵌套 map（1 层）、list（"-" 前缀）
static func _parse_frontmatter(fm: String, out: Dictionary) -> void:
	var lines := fm.split("\n")
	var current_list: Array = []
	var current_list_key: String = ""
	var current_map: Dictionary = {}
	var current_map_key: String = ""
	var in_list := false
	var in_map := false
	var pending_trigger: Dictionary = {}

	for raw_line in lines:
		var line: String = String(raw_line).replace("\t", "  ")
		if line.strip_edges() == "" or line.strip_edges().begins_with("#"):
			continue

		var indent := _indent_of(line)
		var stripped := line.strip_edges()

		# List item
		if stripped.begins_with("- "):
			var item_body := stripped.substr(2).strip_edges()
			if current_list_key == "triggers":
				# 每个 "-" 开一个新 trigger
				if not pending_trigger.is_empty():
					current_list.append(pending_trigger)
				pending_trigger = {}
				# 支持行内 kv: "- keywords: [a, b]"
				var kv := _try_parse_kv(item_body)
				if not kv.is_empty():
					pending_trigger[kv[0]] = kv[1]
			continue

		# key: value 或 key:
		var colon := stripped.find(":")
		if colon <= 0: continue
		var key := stripped.substr(0, colon).strip_edges()
		var val := stripped.substr(colon + 1).strip_edges()

		# 判断是否嵌套：indent >= 2 表示属于 pending_trigger / current_map
		if indent >= 2:
			if current_list_key == "triggers":
				pending_trigger[key] = _parse_scalar(val)
			elif in_map:
				current_map[key] = _parse_scalar(val)
			continue

		# 顶层字段
		# 结算上一个 list / map
		if in_list and current_list_key != "":
			if not pending_trigger.is_empty():
				current_list.append(pending_trigger)
				pending_trigger = {}
			out[current_list_key] = current_list.duplicate(true)
			current_list = []
			in_list = false
			current_list_key = ""
		if in_map and current_map_key != "":
			out[current_map_key] = current_map.duplicate(true)
			current_map = {}
			in_map = false
			current_map_key = ""

		if val == "":
			# 开启一个 block（可能是 map 或 list）
			# 我们规范里只有 model (map) 和 triggers (list)
			if key == "triggers":
				in_list = true; current_list_key = "triggers"; current_list = []; pending_trigger = {}
			else:
				in_map = true; current_map_key = key; current_map = {}
		else:
			out[key] = _parse_scalar(val)

	# 收尾
	if in_list and current_list_key != "":
		if not pending_trigger.is_empty():
			current_list.append(pending_trigger)
		out[current_list_key] = current_list
	if in_map and current_map_key != "":
		out[current_map_key] = current_map


static func _indent_of(line: String) -> int:
	var n := 0
	for i in range(line.length()):
		if line[i] == " ": n += 1
		else: break
	return n


static func _try_parse_kv(s: String) -> Array:
	var colon := s.find(":")
	if colon <= 0: return []
	var k := s.substr(0, colon).strip_edges()
	var v := s.substr(colon + 1).strip_edges()
	return [k, _parse_scalar(v)]


## 标量解析：数字 / bool / [list] / 纯字符串
static func _parse_scalar(s: String) -> Variant:
	s = s.strip_edges()
	if s == "": return ""
	# [a, b, c]
	if s.begins_with("[") and s.ends_with("]"):
		var inner := s.substr(1, s.length() - 2)
		var items := inner.split(",")
		var arr: Array = []
		for it in items:
			var t: String = String(it).strip_edges()
			if t.begins_with('"') and t.ends_with('"'):
				t = t.substr(1, t.length() - 2)
			if t != "": arr.append(t)
		return arr
	# quoted string
	if (s.begins_with('"') and s.ends_with('"')) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	if s.to_lower() == "true": return true
	if s.to_lower() == "false": return false
	if s.is_valid_int(): return int(s)
	if s.is_valid_float(): return float(s)
	return s


# ─── Section split ──────────────────────────────────────────────────────────
static func _split_sections(body: String) -> Dictionary:
	var sections: Dictionary = {}
	var current_key := ""
	var buf: PackedStringArray = []
	for raw_line in body.split("\n"):
		var line: String = String(raw_line)
		if line.begins_with("# ") and not line.begins_with("## "):
			# 保存上一段
			if current_key != "":
				sections[current_key] = "\n".join(buf)
			current_key = line.substr(2).strip_edges()
			buf = PackedStringArray()
		else:
			buf.append(line)
	if current_key != "":
		sections[current_key] = "\n".join(buf)
	return sections


# ─── Few-shot parser ────────────────────────────────────────────────────────
## 输入形如：
##     ### 玩家: xxx
##     村长: yyy
##     ### 玩家: zzz
##     村长: www
static func _parse_fewshots(section: String, _short_name: String) -> Array:
	var out: Array = []
	var lines := section.split("\n")
	var mode := ""     # "user" | "assistant"
	var buf: PackedStringArray = []

	for raw in lines:
		var line: String = String(raw)
		var s := line.strip_edges()
		if s == "": continue
		# 玩家行：### 玩家: xxx   或   ### 玩家：xxx
		if s.begins_with("### 玩家"):
			_append_fewshot(out, mode, buf)
			mode = "user"
			buf = PackedStringArray()
			var body := _after_first_colon(s)
			if body != "": buf.append(body)
		# 角色行（任何以 "###" 开头且不是玩家 的情况我们也切）
		elif s.begins_with("###"):
			_append_fewshot(out, mode, buf)
			mode = "assistant"
			buf = PackedStringArray()
			var body2 := _after_first_colon(s)
			if body2 != "": buf.append(body2)
		# 非 ### 开头且包含 "："，可能是角色回复行： "村长: xxx"
		elif _looks_like_assistant_line(s):
			_append_fewshot(out, mode, buf)
			mode = "assistant"
			buf = PackedStringArray()
			var body3 := _after_first_colon(s)
			if body3 != "": buf.append(body3)
		else:
			# 继续当前段
			if mode != "": buf.append(line)

	_append_fewshot(out, mode, buf)
	return out


## Flush explicitly so the lambda cannot capture a stale mode value.
static func _append_fewshot(out: Array, mode: String, buf: PackedStringArray) -> void:
	if mode == "" or buf.is_empty():
		return
	var text := "\n".join(buf).strip_edges()
	if text != "":
		out.append({"role": mode, "content": text})


static func _looks_like_assistant_line(s: String) -> bool:
	# 简单启发：包含中文全角冒号或英文冒号，且冒号前是短短的角色名
	var i1 := s.find("：")
	var i2 := s.find(":")
	var idx := -1
	if i1 >= 0 and i2 >= 0: idx = min(i1, i2)
	elif i1 >= 0: idx = i1
	elif i2 >= 0: idx = i2
	if idx <= 0 or idx > 12: return false
	# 前缀不应包含空格（避免匹配普通句子）
	var prefix := s.substr(0, idx)
	return not prefix.contains(" ") and not prefix.contains("。") and not prefix.contains("，")


static func _after_first_colon(s: String) -> String:
	var i1 := s.find("：")
	var i2 := s.find(":")
	var idx := -1
	if i1 >= 0 and i2 >= 0: idx = min(i1, i2)
	elif i1 >= 0: idx = i1
	elif i2 >= 0: idx = i2
	if idx < 0: return ""
	return s.substr(idx + 1).strip_edges()
