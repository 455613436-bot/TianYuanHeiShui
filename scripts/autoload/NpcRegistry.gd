extends Node
const NpcDisclosureScript := preload("res://scripts/llm/NpcDisclosure.gd")
## NpcRegistry
## NPC 数据仓库 + 固定地点索引 + 事件规则（autoload）。
##
## NPC 位置由各自 JSON 的 current_location 固定配置；运行时不再根据时间、事件、
## 对话或玩家场景变化移动人物。
##
## 数据来源：
## - data/locations.json       地点表（id 是稳定主键）
## - data/npcs/<id>.json       NPC 位置/日程字段（人设对话字段仍以 .md 为准）
## - data/npc_rules/<id>.json  事件 → 行为覆盖规则（可选）

signal npc_moved(npc_id: String, from_loc: String, to_loc: String, reason: String)
signal follow_changed(npc_id: String, is_following: bool)

const LOCATIONS_PATH := "res://data/locations.json"
const NPCS_DIR := "res://data/npcs/"
const RULES_DIR := "res://data/npc_rules/"

const IMPORTANCE_RANK := {"main": 0, "normal": 1, "ambient": 2}
## 人物位置固定，不接受 LLM 生成的跟随、移动或离开动作。
const LLM_ACTION_TYPES: Array[String] = []
const POSTPONE_LEAVE_MINUTES := 15
const DISMISS_DURATION_MINUTES := 120

## loc_id -> 地点信息 dict（来自 locations.json）
var _locations: Dictionary = {}
## scene_path -> loc_id
var _scene_to_location: Dictionary = {}
## npc_id -> NPC 数据（json 原始字段：current_location/home_location/importance/...）
var _npcs: Dictionary = {}
## npc_id -> 对话用 profile（md 人设 + json 位置字段合并，缓存）
var _profile_cache: Dictionary = {}
## npc_id -> loc_id（运行时位置，存档写这里）
var _current_locations: Dictionary = {}
## 被玩家成功劝离的 NPC。保留原始固定地点，但查询在场人物时会过滤；该状态写入存档。
var _dismissed_npcs: Dictionary = {}
## 被攻击致死的人物：永久不再出现在任何场景中。
var _killed_npcs: Dictionary = {}
## 攻击失败后拒绝与玩家交互的人物；仍会留在场景中。
var _hostile_npcs: Dictionary = {}
## 保留旧存档兼容字段；跟随功能已停用。
var _following: Dictionary = {}
## npc_id -> {location, until_total_minutes, reason}（事件规则的临时位移）
var _temp_overrides: Dictionary = {}
## npc_id -> total_minutes（说服成功后推迟离场的截止时刻）
var _postpone_leave_until: Dictionary = {}
## 事件规则列表：[{...rule, "_npc_id": <来自文件名>}]
var _rules: Array = []


func _ready() -> void:
	load_all()
	if not TimeSystem.minute_changed.is_connected(_on_time_advanced):
		TimeSystem.minute_changed.connect(_on_time_advanced)


# ─── 数据装载 ──────────────────────────────────────────────────────────────

func load_all() -> void:
	_load_locations()
	_load_npcs()
	_load_rules()
	_init_runtime_locations()


func _load_locations() -> void:
	_locations.clear()
	_scene_to_location.clear()
	if not FileAccess.file_exists(LOCATIONS_PATH):
		push_warning("[NpcRegistry] 找不到地点表：%s" % LOCATIONS_PATH)
		return
	var f := FileAccess.open(LOCATIONS_PATH, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is not Array:
		push_warning("[NpcRegistry] 地点表格式非法（应为数组）")
		return
	for entry in parsed:
		if entry is not Dictionary:
			continue
		var loc_id := String(entry.get("id", "")).strip_edges()
		if loc_id == "":
			continue
		_locations[loc_id] = (entry as Dictionary).duplicate(true)
		var scene_path := String(entry.get("scene", ""))
		if scene_path != "":
			_scene_to_location[scene_path] = loc_id
	print("[NpcRegistry] 已加载 %d 个地点" % _locations.size())


func _load_npcs() -> void:
	_npcs.clear()
	_profile_cache.clear()
	var dir := DirAccess.open(NPCS_DIR)
	if dir == null:
		push_warning("[NpcRegistry] 找不到 NPC 目录：%s" % NPCS_DIR)
		return
	for file_name in dir.get_files():
		if not file_name.ends_with(".json"):
			continue
		var path := NPCS_DIR + file_name
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is not Dictionary:
			continue
		var npc_id := String((parsed as Dictionary).get("id", file_name.get_basename())).strip_edges()
		if npc_id == "":
			continue
		_npcs[npc_id] = (parsed as Dictionary).duplicate(true)
	print("[NpcRegistry] 已加载 %d 个 NPC 数据" % _npcs.size())


func _load_rules() -> void:
	_rules.clear()
	var dir := DirAccess.open(RULES_DIR)
	if dir == null:
		return # 规则目录可不存在（M4 之前没有规则文件）
	for file_name in dir.get_files():
		if not file_name.ends_with(".json"):
			continue
		var npc_id := file_name.get_basename()
		var f := FileAccess.open(RULES_DIR + file_name, FileAccess.READ)
		if f == null:
			continue
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is not Array:
			continue
		for rule in parsed:
			if rule is Dictionary and String((rule as Dictionary).get("id", "")) != "":
				var r: Dictionary = (rule as Dictionary).duplicate(true)
				r["_npc_id"] = npc_id
				_rules.append(r)
	_rules.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("priority", 0)) < int(b.get("priority", 0)))
	if not _rules.is_empty():
		print("[NpcRegistry] 已加载 %d 条事件规则" % _rules.size())


## 启动与新游戏时从 JSON 的固定 current_location 初始化 NPC；旧存档位置不会覆盖它。
func _init_runtime_locations() -> void:
	_current_locations.clear()
	_dismissed_npcs.clear()
	_killed_npcs.clear()
	_hostile_npcs.clear()
	_following.clear()
	_temp_overrides.clear()
	_postpone_leave_until.clear()
	for npc_id in _npcs:
		var data: Dictionary = _npcs[npc_id]
		var location := String(data.get("current_location", data.get("home_location", "")))
		if _locations.has(location):
			_current_locations[npc_id] = location


func reset_runtime() -> void:
	_init_runtime_locations()


# ─── 查询 ──────────────────────────────────────────────────────────────────

func has_npc(npc_id: String) -> bool:
	return _npcs.has(npc_id)


func get_npc(npc_id: String) -> Dictionary:
	return _npcs.get(npc_id, {})


func all_npc_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in _npcs:
		ids.append(String(key))
	return ids


func get_location_of(npc_id: String) -> String:
	return String(_current_locations.get(npc_id, ""))


func get_npcs_at(location_id: String) -> Array[String]:
	_restore_expired_dismissals()
	var result: Array[String] = []
	for npc_id in _current_locations:
		if String(npc_id) == "mysterious_hermit" and not is_mysterious_hermit_road_time():
			continue
		if not _is_li_leshui_active(String(npc_id)):
			continue
		if String(_current_locations[npc_id]) == location_id and not _dismissed_npcs.has(npc_id) and not _killed_npcs.has(npc_id):
			result.append(String(npc_id))
	result.sort_custom(func(a: String, b: String) -> bool:
		var ra := int(IMPORTANCE_RANK.get(String(_npcs.get(a, {}).get("importance", "normal")), 1))
		var rb := int(IMPORTANCE_RANK.get(String(_npcs.get(b, {}).get("importance", "normal")), 1))
		if ra != rb:
			return ra < rb
		var pa := int(_npcs.get(a, {}).get("sort_priority", 100))
		var pb := int(_npcs.get(b, {}).get("sort_priority", 100))
		if pa != pb:
			return pa < pb
		return a < b)
	return result


func is_npc_present_at(npc_id: String, location_id: String) -> bool:
	_restore_expired_dismissals()
	if npc_id == "mysterious_hermit" and not is_mysterious_hermit_road_time():
		return false
	if not _is_li_leshui_active(npc_id):
		return false
	return not _dismissed_npcs.has(npc_id) and not _killed_npcs.has(npc_id) and String(_current_locations.get(npc_id, "")) == location_id


func get_interactable_npcs_at(location_id: String) -> Array[String]:
	var result: Array[String] = []
	for npc_id in get_npcs_at(location_id):
		if can_interact_with_npc(npc_id):
			result.append(npc_id)
	return result


func _is_li_leshui_active(npc_id: String) -> bool:
	if npc_id == "li_leshui_day":
		return TimeSystem.minute_of_day >= 6 * 60 and TimeSystem.minute_of_day < 19 * 60
	if npc_id == "li_leshui_night":
		return TimeSystem.minute_of_day >= 19 * 60 or TimeSystem.minute_of_day < 6 * 60
	return true


func is_mysterious_hermit_road_time() -> bool:
	return (
		TimeSystem.current_day >= 3
		and TimeSystem.minute_of_day >= 16 * 60 + 50
		and TimeSystem.minute_of_day < 18 * 60
	)


func dismiss_npc(npc_id: String, reason: String = "被玩家劝离") -> bool:
	if not _npcs.has(npc_id) or _dismissed_npcs.has(npc_id):
		return false
	var from_location := String(_current_locations.get(npc_id, ""))
	if from_location.is_empty():
		return false
	_dismissed_npcs[npc_id] = {
		"location": from_location,
		"reason": reason.strip_edges(),
		"day": TimeSystem.current_day,
		"minute": TimeSystem.minute_of_day,
		"until_total_minutes": TimeSystem.total_minutes() + DISMISS_DURATION_MINUTES,
	}
	MemoryStore.add_global_memory("%s被外来者劝离了%s。" % [get_short_name(npc_id), get_location_name(from_location)], ["dismiss", npc_id, from_location])
	npc_moved.emit(npc_id, from_location, "", reason)
	return true


func restore_dismissed_npc(npc_id: String) -> bool:
	if not _dismissed_npcs.erase(npc_id):
		return false
	var location := String(_current_locations.get(npc_id, ""))
	npc_moved.emit(npc_id, "", location, "恢复在场")
	return true


func is_npc_dismissed(npc_id: String) -> bool:
	_restore_expired_dismissals()
	return _dismissed_npcs.has(npc_id)


func _on_time_advanced(_day: int, _minute_of_day: int) -> void:
	_restore_expired_dismissals()


func _restore_expired_dismissals() -> void:
	var expired_ids: Array[String] = []
	var now := TimeSystem.total_minutes()
	for raw_id in _dismissed_npcs:
		var record: Variant = _dismissed_npcs[raw_id]
		if record is not Dictionary:
			continue
		var until := int((record as Dictionary).get("until_total_minutes", -1))
		if until >= 0 and now >= until:
			expired_ids.append(String(raw_id))
	for npc_id in expired_ids:
		var location := String(_current_locations.get(npc_id, ""))
		_dismissed_npcs.erase(npc_id)
		MemoryStore.add_global_memory("%s在两小时后回到了%s。" % [get_short_name(npc_id), get_location_name(location)], ["dismiss_return", npc_id, location])
		npc_moved.emit(npc_id, "", location, "劝离时限结束")


func kill_npc(npc_id: String, reason: String = "被玩家攻击致死") -> bool:
	if not _npcs.has(npc_id) or _killed_npcs.has(npc_id):
		return false
	var from_location := String(_current_locations.get(npc_id, ""))
	if from_location.is_empty():
		return false
	_killed_npcs[npc_id] = {"location": from_location, "reason": reason.strip_edges(), "day": TimeSystem.current_day, "minute": TimeSystem.minute_of_day}
	npc_moved.emit(npc_id, from_location, "", reason)
	return true


func mark_npc_hostile(npc_id: String, reason: String = "攻击失败") -> bool:
	if not _npcs.has(npc_id) or _killed_npcs.has(npc_id):
		return false
	_hostile_npcs[npc_id] = {"reason": reason.strip_edges(), "day": TimeSystem.current_day, "minute": TimeSystem.minute_of_day}
	return true


func can_interact_with_npc(npc_id: String) -> bool:
	return _npcs.has(npc_id) and not _dismissed_npcs.has(npc_id) and not _killed_npcs.has(npc_id) and not _hostile_npcs.has(npc_id)


## F5：未探索地点的 NPC 显示为 "？？？"（返回空数组，由 UI 层画占位）
func known_npcs_at(location_id: String) -> Array[String]:
	if not GameState.has_visited(location_id):
		return []
	return get_npcs_at(location_id)


func get_location_info(loc_id: String) -> Dictionary:
	return _locations.get(loc_id, {})


func get_location_name(loc_id: String) -> String:
	return String(_locations.get(loc_id, {}).get("name", loc_id))


func all_locations() -> Array:
	var result: Array = []
	for loc_id in _locations:
		result.append((_locations[loc_id] as Dictionary).duplicate(true))
	return result


func location_id_for_scene(scene_path: String) -> String:
	return String(_scene_to_location.get(scene_path, ""))


## LLM 输出的地点可能是 id 也可能是中文名；都解析成 id，解析不了返回 ""
func resolve_location_id(raw: String) -> String:
	var key := raw.strip_edges()
	if key == "":
		return ""
	if _locations.has(key):
		return key
	for loc_id in _locations:
		if String((_locations[loc_id] as Dictionary).get("name", "")) == key:
			return String(loc_id)
	return ""


func get_display_name(npc_id: String) -> String:
	return String(_npcs.get(npc_id, {}).get("display_name", npc_id))


func get_short_name(npc_id: String) -> String:
	var data: Dictionary = _npcs.get(npc_id, {})
	return String(data.get("short_name", data.get("display_name", npc_id)))


## 对话用完整 profile：md 人设（fewshots/system_prompt）优先，json 位置字段合并进去
func get_dialogue_profile(npc_id: String) -> Dictionary:
	if _profile_cache.has(npc_id):
		return (_profile_cache[npc_id] as Dictionary).duplicate(true)
	var base: Dictionary = _npcs.get(npc_id, {}).duplicate(true)
	var md_path := NPCS_DIR + npc_id + ".md"
	var persona: Dictionary = {}
	if FileAccess.file_exists(md_path):
		persona = NpcPersona.load_from_file(md_path)
	if persona.is_empty():
		# 没有 md 就纯用 json（json 自带 system_prompt/triggers 的旧格式）
		persona = base
	else:
		# md 赢人设字段；json 补位置/日程字段
		for key in base:
			if not persona.has(key):
				persona[key] = base[key]
	persona["id"] = npc_id
	_profile_cache[npc_id] = persona
	return persona.duplicate(true)


## 为一次 LLM 请求构建受披露等级约束的副本；原始 profile 仅供 UI 与剧情事件读取。
func build_llm_profile(profile: Dictionary) -> Dictionary:
	return NpcDisclosureScript.build_runtime_profile(profile)


func get_disclosure_level(profile: Dictionary) -> int:
	return NpcDisclosureScript.get_disclosure_level(profile)


func is_following(npc_id: String) -> bool:
	return bool(_following.get(npc_id, false))


func following_npcs() -> Array[String]:
	var result: Array[String] = []
	for npc_id in _following:
		result.append(String(npc_id))
	return result


func has_temp_override(npc_id: String) -> bool:
	return _temp_overrides.has(npc_id)


# ─── 位置变更（唯一入口）────────────────────────────────────────────────────

func move_npc(_npc_id: String, _new_location_id: String, _reason: String, _source: String) -> void:
	# 人物移动功能已停用；NPC 始终使用 JSON 中的固定 current_location。
	return


# NPC 地点固定：不再存在按时段调度、临时位移或离场延迟逻辑。




# ─── 跟随（F10）────────────────────────────────────────────────────────────

func start_follow(npc_id: String) -> void:
	if not _npcs.has(npc_id) or _following.has(npc_id):
		return
	_following[npc_id] = true
	var player_loc := location_id_for_scene(GameState.current_scene_path)
	if player_loc != "":
		move_npc(npc_id, player_loc, "跟随玩家", "follow")
	MemoryStore.add_global_memory("%s开始跟着外来者一起走。" % get_short_name(npc_id), ["follow", npc_id])
	follow_changed.emit(npc_id, true)


func stop_follow(npc_id: String, drop_at_location_id: String = "") -> void:
	if not _following.erase(npc_id):
		return
	var drop := drop_at_location_id
	if drop == "" or not _locations.has(drop):
		drop = location_id_for_scene(GameState.current_scene_path)
	if drop == "":
		drop = String(_npcs.get(npc_id, {}).get("home_location", ""))
	if drop != "":
		move_npc(npc_id, drop, "结束跟随", "follow")
	MemoryStore.add_global_memory("%s不再跟着外来者了。" % get_short_name(npc_id), ["follow", npc_id])
	follow_changed.emit(npc_id, false)


## 玩家进入新地点时（GameState.change_scene 钩子）：跟随者一起挪
func on_player_enter_location(loc_id: String) -> void:
	if loc_id == "":
		return
	for npc_id in following_npcs():
		move_npc(npc_id, loc_id, "跟随玩家", "follow")


# ─── 事件规则（L2，F8）──────────────────────────────────────────────────────

func on_event(event_name: String, payload: Dictionary) -> void:
	for rule in _rules:
		if not _match_rule(rule, event_name, payload):
			continue
		var rule_id := String(rule.get("id", ""))
		if bool(rule.get("once", false)):
			if GameState.has_triggered_event(rule_id):
				continue
			GameState.trigger_event(rule_id)
		_apply_rule_action(rule)


func _match_rule(rule: Dictionary, event_name: String, payload: Dictionary) -> bool:
	var trigger: Variant = rule.get("trigger", {})
	if trigger is not Dictionary:
		return false
	var t: Dictionary = trigger
	if String(t.get("type", "")) != event_name:
		return false
	var npc_id := String(rule.get("_npc_id", ""))
	match event_name:
		"clue_triggered":
			if String(t.get("clue_id", "")) != String(payload.get("clue_id", "")):
				return false
		"event_triggered":
			if String(t.get("event_id", "")) != String(payload.get("event_id", "")):
				return false
		"quest_stage":
			var quest_id := String(t.get("quest_id", payload.get("quest_id", "")))
			if GameState.get_quest_stage(quest_id) < int(t.get("stage", 1)):
				return false
		"time_period":
			if String(t.get("period", "")) != String(payload.get("period", "")):
				return false
		"affinity_below":
			if GameState.get_affinity(npc_id) >= int(t.get("value", 0)):
				return false
	# 通用条件：affinity_lt
	var condition: Variant = rule.get("condition", {})
	if condition is Dictionary and (condition as Dictionary).has("affinity_lt"):
		if GameState.get_affinity(npc_id) >= int((condition as Dictionary).get("affinity_lt", 0)):
			return false
	return true


func _apply_rule_action(_rule: Dictionary) -> void:
	# 事件规则不再改变 NPC 地点或日程。
	return


# ─── LLM 说服裁决（F9，L3-A）───────────────────────────────────────────────

## 规则层过滤：处于临时位移（如逃跑）中的 NPC 无法被说服改变位置
func can_be_persuaded(npc_id: String) -> bool:
	if not _npcs.has(npc_id):
		return false
	if _dismissed_npcs.has(npc_id):
		return false
	if _killed_npcs.has(npc_id) or _hostile_npcs.has(npc_id):
		return false
	if String(_npcs[npc_id].get("importance", "normal")) == "ambient":
		return false
	if _temp_overrides.has(npc_id):
		return false
	return true


## NPC 地点固定，忽略模型请求的跟随、移动、离开等位置动作。
func apply_llm_action(_npc_id: String, _action: Dictionary) -> Dictionary:
	return {"applied": false, "description": ""}


# ─── Prompt 上下文注入（F12）──────────────────────────────────────────────

## 追加到 system_prompt 末尾的「当前场景状态」段
func build_scene_prompt_block(npc_id: String) -> String:
	var loc_id := get_location_of(npc_id)
	if loc_id == "":
		return ""
	var lines: PackedStringArray = []
	lines.append("## 当前场景状态")
	lines.append("- 当前精确游戏时间：%s（时段：%s）" % [TimeSystem.format_clock(), TimeSystem.current_period()])
	lines.append("- 你所在地点：%s" % get_location_name(loc_id))
	var others := get_npcs_at(loc_id)
	others.erase(npc_id)
	if others.is_empty():
		lines.append("- 此地除了玩家没有别的村民")
	else:
		var names: PackedStringArray = []
		for other_id in others:
			names.append(get_short_name(other_id))
		lines.append("- 同处此地的还有：%s" % "、".join(names))
	# NPC 地点固定，不向模型提供日程、离场或地点移动指令。
	# 该 NPC 可用的 mood 列表（供 LLM 输出 mood 字段时参考）
	var npc_moods: Array[String] = MoodPortrait.moods_for_npc(npc_id)
	if not npc_moods.is_empty():
		lines.append("- 你（%s）可输出的 mood 值：%s" % [get_short_name(npc_id), "、".join(npc_moods)])
	return "\n".join(lines)





# ─── 持久化 ────────────────────────────────────────────────────────────────

func to_dict() -> Dictionary:
	# 固定地点仍来自 NPC JSON；这里只保存玩家造成的缺席状态。
	return {"dismissed_npcs": _dismissed_npcs.duplicate(true), "killed_npcs": _killed_npcs.duplicate(true), "hostile_npcs": _hostile_npcs.duplicate(true)}


func load_from_dict(data: Variant) -> void:
	# 忽略旧存档中的人物位置，始终应用当前 JSON 的固定 current_location；恢复合法的缺席记录。
	_init_runtime_locations()
	if data is not Dictionary:
		return
	var raw_dismissed: Variant = (data as Dictionary).get("dismissed_npcs", {})
	if raw_dismissed is not Dictionary:
		return
	for raw_id in raw_dismissed:
		var npc_id := String(raw_id)
		var record: Variant = raw_dismissed[raw_id]
		if _npcs.has(npc_id) and record is Dictionary:
			_dismissed_npcs[npc_id] = (record as Dictionary).duplicate(true)
	var raw_killed: Variant = (data as Dictionary).get("killed_npcs", {})
	if raw_killed is Dictionary:
		for raw_id in raw_killed:
			var killed_id := String(raw_id)
			var record: Variant = raw_killed[raw_id]
			if _npcs.has(killed_id) and record is Dictionary:
				_killed_npcs[killed_id] = (record as Dictionary).duplicate(true)
	var raw_hostile: Variant = (data as Dictionary).get("hostile_npcs", {})
	if raw_hostile is Dictionary:
		for raw_id in raw_hostile:
			var hostile_id := String(raw_id)
			var record: Variant = raw_hostile[raw_id]
			if _npcs.has(hostile_id) and record is Dictionary:
				_hostile_npcs[hostile_id] = (record as Dictionary).duplicate(true)
