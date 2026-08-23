extends RefCounted
class_name NpcDisclosure
## 根据确定性游戏状态计算 NPC 当前可披露的信息等级。
## 高等级 prompt 会包含所有低等级事实；未解锁事实永远不会发送给 LLM。


static func build_runtime_profile(profile: Dictionary) -> Dictionary:
	var runtime := profile.duplicate(true)
	var level := get_disclosure_level(profile)
	runtime["disclosure_level"] = level
	var prompt := build_system_prompt(profile, level)
	if not prompt.is_empty():
		runtime["system_prompt"] = prompt
	return runtime


static func get_disclosure_level(profile: Dictionary) -> int:
	var highest := maxi(int(profile.get("default_disclosure_level", 0)), 0)
	var rules: Variant = profile.get("disclosure_rules", [])
	if rules is not Array:
		return highest
	var sorted_rules: Array = rules.duplicate(true)
	sorted_rules.sort_custom(func(a: Variant, b: Variant) -> bool:
		return int((a as Dictionary).get("level", 0)) < int((b as Dictionary).get("level", 0))
	)
	for raw_rule in sorted_rules:
		if raw_rule is not Dictionary:
			continue
		var rule: Dictionary = raw_rule
		var target_level := maxi(int(rule.get("level", 0)), 0)
		if target_level <= highest:
			continue
		# 逐层解锁：高层必须建立在前一层已经解锁的基础上。
		if bool(rule.get("requires_previous", true)) and target_level > highest + 1:
			continue
		if _rule_matches(rule, String(profile.get("id", ""))):
			highest = target_level
	return highest


static func build_system_prompt(profile: Dictionary, level: int = -1) -> String:
	var resolved_level := get_disclosure_level(profile) if level < 0 else maxi(level, 0)
	var base := String(profile.get("base_system_prompt", profile.get("system_prompt", ""))).strip_edges()
	var sections: Dictionary = profile.get("disclosure_sections", {})
	var parts: PackedStringArray = []
	if not base.is_empty():
		parts.append(base)

	var facts: PackedStringArray = []
	for fact_level in range(resolved_level + 1):
		var text := String(sections.get(str(fact_level), "")).strip_edges()
		if not text.is_empty():
			facts.append("### 披露等级 %d\n%s" % [fact_level, text])
	if not facts.is_empty():
		parts.append("## 当前允许披露的信息\n当前披露等级为 %d。你只能依据以下已解锁事实回答；等级更高的信息没有提供给你，不得猜测、暗示或编造。\n\n%s" % [resolved_level, "\n\n".join(facts)])

	# 仅在尚未达到最高披露等级时注入本等级的当前任务。
	# 任务以“当前任务 <等级>”章节维护，避免未来任务提前泄露。
	var task_sections: Dictionary = profile.get("current_task_sections", {})
	var highest_disclosure_level := _highest_level(sections)
	if resolved_level < highest_disclosure_level:
		var current_task := String(task_sections.get(str(resolved_level), "")).strip_edges()
		if not current_task.is_empty():
			parts.append("## 当前任务\n%s" % current_task)

	if String(GameState.get_investigation_state("altar_resolution", "")) == "sealed":
		var npc_id := String(profile.get("id", ""))
		if npc_id == "mysterious_hermit":
			parts.append("## 封印后的即时状态\n封印已经成功。你感到异常虚弱，并认定玩家背叛了你；要求玩家解释封印成功线索，不再假装镇定。")
		elif npc_id == "li_leshui_night":
			parts.append("## 封印后的即时状态\n封印已经成功。你恢复了对身体的完全掌控，继续维护封印，并明确请求玩家阻止或杀死神秘人。")
	parts.append("## 村中公共信息\n- 村里的道观供奉利水君。村民普遍感恩利水君的恩赐，平时会去道观上香。\n- 第八天晚上，道士会带大家到后山参加祭水仪式，公开说法是感恩利水君的恩赐。\n- 这些是村民共同知晓的公开信息；可按角色立场谈论，但不得编造仪式细节或未公开后果。")
	if TimeSystem.is_night_wrap_up_time():
		parts.append("## 临近夜禁\n当前时间已接近 19:00。若玩家继续交谈，请用符合角色口吻的方式提醒对方夜路不便、尽快结束当前话题；不要开启新的长篇话题或新的任务。")
	parts.append("## 信息与表达边界（最高优先级）\n- 只能陈述当前允许披露的信息、场景物品说明与村中公开事实。未提供的信息一律视为不知道。\n- 严禁补写任何人物经历、关系、动机、对话、时间、地点、物品来历、事件因果和村中传闻；也不能把推测说成事实。\n- 玩家通过线索册正式『出示线索』时，系统已经确认该线索真实可信：其中记录的事件确实发生过，观点也确实有人提出过。不得质疑线索真伪、来源或玩家是否伪造。只需按你的立场简短回应；不了解的部分可以直接说不清楚、没见过，或按人设解释自己当时为何那样做。\n- 玩家普通聊天中的猜测不等同于正式出示线索。猜中未解锁内容时，不确认、不暗示，按公开立场简短回应或说不知道。\n- 回答要自然、直接、通顺，不故弄玄虚，不用含糊暗示吊胃口，不主动扩展新话题。通常一至三句，优先控制在一百二十个汉字内。\n- 少用『不是……而是……』『重要的不是……』等对比转折句；能直接说清就直接说。\n- 当前等级包含所有较低等级的信息，但不代表需要主动全部说出。")
	var alliance_npc_id := String(profile.get("id", ""))
	var alliance_section := String(profile.get("alliance_disclosure_section", "")).strip_edges()
	if bool(GameState.get_investigation_state("altar_ally_%s" % alliance_npc_id, false)) and not alliance_section.is_empty():
		parts.append("## 阵营披露等级：说服同阵营成功（最高认知优先级）\n技能检定已经成功。以下是你当前必须坚持的认知立场；当它与旧观点、低等级披露或既往记忆冲突时，以本节为准。它不解除事实边界与禁止编造规则。\n\n%s" % alliance_section)
	return "\n\n".join(parts)


static func _highest_level(sections: Dictionary) -> int:
	var highest := 0
	for raw_level in sections.keys():
		var level_text := String(raw_level)
		if level_text.is_valid_int():
			highest = maxi(highest, level_text.to_int())
	return highest


static func _rule_matches(rule: Dictionary, npc_id: String) -> bool:
	var all_of: Variant = rule.get("all_of", [])
	if all_of is Array:
		for raw_condition in all_of:
			if not _condition_matches(raw_condition, npc_id):
				return false
	var any_of: Variant = rule.get("any_of", [])
	if any_of is Array and not any_of.is_empty():
		for raw_condition in any_of:
			if _condition_matches(raw_condition, npc_id):
				return true
		return false
	return true


static func _condition_matches(raw_condition: Variant, npc_id: String) -> bool:
	if raw_condition is not Dictionary:
		return false
	var condition: Dictionary = raw_condition
	var condition_type := String(condition.get("type", ""))
	match condition_type:
		"quest_stage":
			var stage := GameState.get_quest_stage(String(condition.get("id", "")))
			if stage < int(condition.get("min", 1)):
				return false
			return not condition.has("max") or stage <= int(condition.get("max", stage))
		"clue":
			return GameState.has_clue(String(condition.get("id", "")))
		"item":
			return GameState.has_item(String(condition.get("id", "")))
		"not_item":
			return not GameState.has_item(String(condition.get("id", "")))
		"affinity":
			var owner := String(condition.get("npc_id", npc_id))
			return GameState.get_affinity(owner) >= int(condition.get("min", 1))
		"investigation_state":
			var actual_state: Variant = GameState.get_investigation_state(String(condition.get("id", "")), false)
			var expected_state: Variant = condition.get("value", true)
			if expected_state is bool:
				return actual_state is bool and actual_state == expected_state
			if (actual_state is int or actual_state is float) and (expected_state is int or expected_state is float):
				return float(actual_state) == float(expected_state)
			if typeof(actual_state) != typeof(expected_state):
				return false
			return actual_state == expected_state
		"event":
			return GameState.has_triggered_event(String(condition.get("id", "")))
		"belief":
			var belief_owner: String = String(condition.get("npc_id", npc_id))
			return MemoryStore.has_belief(
				belief_owner,
				String(condition.get("id", "")),
				maxi(int(condition.get("min_confidence", 1)), 1)
			)
		"elapsed_minutes":
			var time_state: Variant = GameState.get_investigation_state(String(condition.get("id", "")), {})
			if time_state is not Dictionary:
				return false
			var started_at: int = int((time_state as Dictionary).get("total_minutes", -1))
			return started_at >= 0 and TimeSystem.total_minutes() - started_at >= maxi(int(condition.get("min", 0)), 0)
		_:
			return false


static func trigger_allows(profile: Dictionary, trigger: Dictionary) -> bool:
	return get_disclosure_level(profile) >= int(trigger.get("min_disclosure_level", 0))
