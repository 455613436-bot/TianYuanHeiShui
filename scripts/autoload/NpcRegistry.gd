extends Node
## NpcRegistry
## NPC 数据仓库 + 位置调度 + 事件规则（autoload）。
##
## 核心原则：**所有 NPC 位置的改动都只通过 move_npc() 唯一入口**，
## schedule 层、事件规则层、LLM 说服层、跟随层最终都调它，
## 方便调试、记忆写入、存档一致性。
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
## LLM 说服动作的白名单类型
const LLM_ACTION_TYPES := ["follow_player", "move_to", "leave", "postpone_leave"]
const POSTPONE_LEAVE_MINUTES := 15

## loc_id -> 地点信息 dict（来自 locations.json）
var _locations: Dictionary = {}
## scene_path -> loc_id
var _scene_to_location: Dictionary = {}
## npc_id -> NPC 数据（json 原始字段：schedule/home_location/importance/...）
var _npcs: Dictionary = {}
## npc_id -> 对话用 profile（md 人设 + json 位置字段合并，缓存）
var _profile_cache: Dictionary = {}
## npc_id -> loc_id（运行时位置，存档写这里）
var _current_locations: Dictionary = {}
## npc_id -> true（跟随玩家中的 NPC，暂停 schedule）
var _following: Dictionary = {}
## npc_id -> {location, until_total_minutes, reason}（事件规则的临时位移）
var _temp_overrides: Dictionary = {}
## npc_id -> total_minutes（说服成功后推迟离场的截止时刻）
var _postpone_leave_until: Dictionary = {}
## 事件规则列表：[{...rule, "_npc_id": <来自文件名>}]
var _rules: Array = []


func _ready() -> void:
	load_all()
	TimeSystem.period_changed.connect(_on_period_changed)
	TimeSystem.minute_changed.connect(_on_minute_changed)
	GameState.clue_triggered.connect(func(clue_id: String): on_event("clue_triggered", {"clue_id": clue_id}))


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


## 启动时按当前时段 schedule 计算每个 NPC 的位置（读档时会被 load_from_dict 覆盖）
func _init_runtime_locations() -> void:
	_current_locations.clear()
	_following.clear()
	_temp_overrides.clear()
	_postpone_leave_until.clear()
	for npc_id in _npcs:
		_current_locations[npc_id] = _scheduled_location_for(npc_id, TimeSystem.current_period())


func reset_runtime() -> void:
	## 新游戏时调用：全部按 schedule 重算
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
	var result: Array[String] = []
	for npc_id in _current_locations:
		if String(_current_locations[npc_id]) == location_id:
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

func move_npc(npc_id: String, new_location_id: String, reason: String, source: String) -> void:
	## source in {"schedule","event","llm","follow","manual"}
	if not _npcs.has(npc_id) or not _locations.has(new_location_id):
		return
	var from_loc := String(_current_locations.get(npc_id, ""))
	if from_loc == new_location_id:
		return
	_current_locations[npc_id] = new_location_id
	var npc_name := get_short_name(npc_id)
	var loc_name := get_location_name(new_location_id)
	MemoryStore.add_global_memory(
		"%s在%s去了%s（%s）。" % [npc_name, TimeSystem.format_clock_short(), loc_name, reason],
		["npc_move", npc_id])
	npc_moved.emit(npc_id, from_loc, new_location_id, reason)


# ─── schedule ──────────────────────────────────────────────────────────────

func _scheduled_location_for(npc_id: String, period: String) -> String:
	var data: Dictionary = _npcs.get(npc_id, {})
	var home := String(data.get("home_location", ""))
	var found := ""
	var schedule: Variant = data.get("schedule", [])
	if schedule is Array:
		# 同一 period 出现多次时用最后一条
		for entry in schedule:
			if entry is Dictionary and String((entry as Dictionary).get("period", "")) == period:
				found = String((entry as Dictionary).get("location", ""))
	if found == "" or not _locations.has(found):
		found = home
	return found


func _schedule_reason_for(npc_id: String, period: String) -> String:
	var data: Dictionary = _npcs.get(npc_id, {})
	var reason := ""
	var schedule: Variant = data.get("schedule", [])
	if schedule is Array:
		for entry in schedule:
			if entry is Dictionary and String((entry as Dictionary).get("period", "")) == period:
				reason = String((entry as Dictionary).get("reason", ""))
	return reason


## 按当前时段把 NPC 挪到 schedule 对应位置（跟随中 / 临时覆盖中 / 被推迟中的跳过）
func apply_schedule_for(npc_id: String) -> void:
	if not _npcs.has(npc_id):
		return
	if _following.has(npc_id):
		return
	if _temp_overrides.has(npc_id):
		return
	if int(_postpone_leave_until.get(npc_id, 0)) > TimeSystem.total_minutes():
		return
	var target := _scheduled_location_for(npc_id, TimeSystem.current_period())
	if target == "":
		return
	var reason := _schedule_reason_for(npc_id, TimeSystem.current_period())
	move_npc(npc_id, target, "按日程：%s" % reason if reason != "" else "按日程移动", "schedule")


func apply_all_schedules() -> void:
	for npc_id in _npcs:
		apply_schedule_for(npc_id)


## F7 提示语用：下一个时段 NPC 按日程要去哪
func next_schedule_info(npc_id: String) -> Dictionary:
	var next_period := TimeSystem.next_period()
	var loc := _scheduled_location_for(npc_id, next_period)
	return {
		"period": next_period,
		"location": loc,
		"location_name": get_location_name(loc),
		"reason": _schedule_reason_for(npc_id, next_period),
		"minutes": TimeSystem.minutes_until_next_period(),
	}


## L2 事件规则用：临时改位置一段时间，到期后回落 schedule
func set_temp_override(npc_id: String, loc: String, minutes: int, reason: String) -> void:
	if not _npcs.has(npc_id) or not _locations.has(loc):
		return
	_temp_overrides[npc_id] = {
		"location": loc,
		"until_total_minutes": TimeSystem.total_minutes() + maxi(minutes, 1),
		"reason": reason,
	}
	move_npc(npc_id, loc, reason, "event")


func postpone_leave(npc_id: String, minutes: int = POSTPONE_LEAVE_MINUTES) -> void:
	_postpone_leave_until[npc_id] = TimeSystem.total_minutes() + maxi(minutes, 1)


func _on_period_changed(_new_period: String, _day: int) -> void:
	apply_all_schedules()
	on_event("time_period", {"period": _new_period, "day": _day})


func _on_minute_changed(_day: int, _minute: int) -> void:
	# 临时覆盖到期 → 清掉并回落 schedule
	var now := TimeSystem.total_minutes()
	for npc_id in _temp_overrides.keys().duplicate():
		var until := int((_temp_overrides[npc_id] as Dictionary).get("until_total_minutes", 0))
		if now >= until:
			_temp_overrides.erase(npc_id)
			apply_schedule_for(npc_id)


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


func _apply_rule_action(rule: Dictionary) -> void:
	var npc_id := String(rule.get("_npc_id", ""))
	var action: Variant = rule.get("action", {})
	if npc_id == "" or action is not Dictionary:
		return
	var a: Dictionary = action
	var action_type := String(a.get("type", ""))
	match action_type:
		"temp_move":
			set_temp_override(
				npc_id,
				String(a.get("location", "")),
				int(a.get("duration_minutes", 60)),
				String(a.get("reason", "临时离开")))
		"set_schedule":
			var new_schedule: Variant = a.get("schedule", [])
			if new_schedule is Array and _npcs.has(npc_id):
				_npcs[npc_id]["schedule"] = (new_schedule as Array).duplicate(true)
				_profile_cache.erase(npc_id)
				apply_schedule_for(npc_id)
		"set_home":
			var new_home := String(a.get("location", ""))
			if _locations.has(new_home) and _npcs.has(npc_id):
				_npcs[npc_id]["home_location"] = new_home
				_profile_cache.erase(npc_id)
				move_npc(npc_id, new_home, String(a.get("reason", "搬家")), "event")
		"follow_player":
			start_follow(npc_id)
		"stop_follow":
			stop_follow(npc_id, String(a.get("location", "")))
	var log_text := String(a.get("log_global_memory", ""))
	if log_text != "":
		MemoryStore.add_global_memory(log_text, ["npc_rule", String(rule.get("id", ""))])


# ─── LLM 说服裁决（F9，L3-A）───────────────────────────────────────────────

## 规则层过滤：处于临时位移（如逃跑）中的 NPC 无法被说服改变位置
func can_be_persuaded(npc_id: String) -> bool:
	if not _npcs.has(npc_id):
		return false
	if String(_npcs[npc_id].get("importance", "normal")) == "ambient":
		return false
	if _temp_overrides.has(npc_id):
		return false
	return true


## 裁决通过后执行动作。返回 {applied: bool, description: String}；description 给 UI 做系统提示。
func apply_llm_action(npc_id: String, action: Dictionary) -> Dictionary:
	var action_type := String(action.get("type", ""))
	if action_type == "" or action_type == "none":
		return {"applied": false, "description": ""}
	if not LLM_ACTION_TYPES.has(action_type):
		return {"applied": false, "description": ""}
	if not can_be_persuaded(npc_id):
		return {"applied": false, "description": "%s此刻不打算改变行程。" % get_short_name(npc_id)}
	var npc_name := get_short_name(npc_id)
	match action_type:
		"follow_player":
			start_follow(npc_id)
			return {"applied": true, "description": "%s开始跟着你了。" % npc_name}
		"move_to":
			var target := resolve_location_id(String(action.get("target_location", "")))
			if target == "":
				return {"applied": false, "description": ""}
			var duration := clampi(int(action.get("duration_minutes", 60)), 5, 480)
			set_temp_override(npc_id, target, duration, "被玩家说服")
			return {"applied": true, "description": "%s动身去了%s。" % [npc_name, get_location_name(target)]}
		"leave":
			# 离开当前谈话/场所：回 home 或去 target
			var leave_target := resolve_location_id(String(action.get("target_location", "")))
			if leave_target == "":
				leave_target = String(_npcs.get(npc_id, {}).get("home_location", ""))
			if leave_target != "":
				move_npc(npc_id, leave_target, "告辞离开", "llm")
				return {"applied": true, "description": "%s告辞离开了。" % npc_name}
			return {"applied": false, "description": ""}
		"postpone_leave":
			postpone_leave(npc_id, clampi(int(action.get("duration_minutes", POSTPONE_LEAVE_MINUTES)), 5, 120))
			return {"applied": true, "description": "%s决定再多留一会儿。" % npc_name}
	return {"applied": false, "description": ""}


# ─── Prompt 上下文注入（F12）──────────────────────────────────────────────

## 追加到 system_prompt 末尾的「当前场景状态」段
func build_scene_prompt_block(npc_id: String) -> String:
	var loc_id := get_location_of(npc_id)
	if loc_id == "":
		return ""
	var lines: PackedStringArray = []
	lines.append("## 当前场景状态")
	lines.append("- 现在是：%s（%s）" % [TimeSystem.format_clock(), TimeSystem.current_period()])
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
	var next_info := next_schedule_info(npc_id)
	if String(next_info.get("location", "")) != "" and String(next_info.get("location", "")) != loc_id:
		var reason := String(next_info.get("reason", ""))
		var suffix := "（%s）" % reason if reason != "" else ""
		lines.append("- 你按日程将在约 %d 分钟后前往%s%s" % [
			int(next_info.get("minutes", 0)),
			String(next_info.get("location_name", "")),
			suffix,
		])
	# 合法地点白名单给 LLM 的 action.target_location 用
	var loc_pairs: PackedStringArray = []
	for loc in _locations:
		loc_pairs.append("%s（%s）" % [String(loc), get_location_name(String(loc))])
	lines.append("- 本村合法地点 id 列表：%s" % "、".join(loc_pairs))
	# 该 NPC 可用的 mood 列表（供 LLM 输出 mood 字段时参考）
	var npc_moods: Array[String] = MoodPortrait.moods_for_npc(npc_id)
	if not npc_moods.is_empty():
		lines.append("- 你（%s）可输出的 mood 值：%s" % [get_short_name(npc_id), "、".join(npc_moods)])
	return "\n".join(lines)


## F7 软指令：距离日程转场很近时，让 NPC 自然地预告离场
func build_soft_leave_instruction(npc_id: String) -> String:
	var info := next_schedule_info(npc_id)
	var loc_name := String(info.get("location_name", ""))
	if loc_name == "" or String(info.get("location", "")) == get_location_of(npc_id):
		return ""
	var reason := String(info.get("reason", ""))
	var minutes := int(info.get("minutes", 0))
	return ("\n\n**行程提醒**：距离你按日程要去「%s」（%s）还有约 %d 分钟。"
		+ "请在这次回答中自然地提醒玩家你要走了；如果玩家没有强留，"
		+ "请在回答末尾用 [END_DIALOGUE] 标签表示你就此告辞离开。") % [loc_name, reason, minutes]


# ─── 持久化 ────────────────────────────────────────────────────────────────

func to_dict() -> Dictionary:
	var overrides := {}
	for npc_id in _temp_overrides:
		var o: Dictionary = _temp_overrides[npc_id]
		overrides[npc_id] = {
			"location": String(o.get("location", "")),
			"remaining_minutes": maxi(1, int(o.get("until_total_minutes", 0)) - TimeSystem.total_minutes()),
			"reason": String(o.get("reason", "")),
		}
	var postpones := {}
	for npc_id in _postpone_leave_until:
		var remain := int(_postpone_leave_until[npc_id]) - TimeSystem.total_minutes()
		if remain > 0:
			postpones[npc_id] = remain
	return {
		"current_locations": _current_locations.duplicate(true),
		"following": _following.keys(),
		"temp_overrides": overrides,
		"postpone_leave_until": postpones,
	}


func load_from_dict(data: Variant) -> void:
	if data is not Dictionary:
		return
	var d: Dictionary = data
	var locs: Variant = d.get("current_locations", {})
	if locs is Dictionary:
		for npc_id in locs:
			var loc := String(locs[npc_id])
			if _npcs.has(npc_id) and _locations.has(loc):
				_current_locations[npc_id] = loc
	var following_raw: Variant = d.get("following", [])
	_following.clear()
	if following_raw is Array:
		for npc_id in following_raw:
			var id_str := String(npc_id)
			if _npcs.has(id_str):
				_following[id_str] = true
	var overrides_raw: Variant = d.get("temp_overrides", {})
	_temp_overrides.clear()
	if overrides_raw is Dictionary:
		for npc_id in overrides_raw:
			var entry: Variant = overrides_raw[npc_id]
			if entry is not Dictionary or not _npcs.has(npc_id):
				continue
			var loc := String((entry as Dictionary).get("location", ""))
			if not _locations.has(loc):
				continue
			_temp_overrides[npc_id] = {
				"location": loc,
				"until_total_minutes": TimeSystem.total_minutes() + int((entry as Dictionary).get("remaining_minutes", 60)),
				"reason": String((entry as Dictionary).get("reason", "")),
			}
	var postpones_raw: Variant = d.get("postpone_leave_until", {})
	_postpone_leave_until.clear()
	if postpones_raw is Dictionary:
		for npc_id in postpones_raw:
			if _npcs.has(npc_id):
				_postpone_leave_until[npc_id] = TimeSystem.total_minutes() + int(postpones_raw[npc_id])
