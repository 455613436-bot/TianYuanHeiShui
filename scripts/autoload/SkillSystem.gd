extends Node
## 场景技能目录与确定性裁决。UI 只负责选择目标和输入理由。

const DATA_PATH := "res://data/skills.json"

var _skills: Array[Dictionary] = []
var _medical_results: Dictionary = {}
var _water_result: Dictionary = {}


func _ready() -> void:
	_reload()


func _reload() -> void:
	_skills.clear()
	_medical_results.clear()
	_water_result.clear()
	if not FileAccess.file_exists(DATA_PATH):
		push_warning("[SkillSystem] Missing skill data: %s" % DATA_PATH)
		return
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		push_warning("[SkillSystem] Invalid skill data")
		return
	for raw_skill in (parsed as Dictionary).get("skills", []):
		if raw_skill is Dictionary and not String(raw_skill.get("id", "")).is_empty():
			_skills.append((raw_skill as Dictionary).duplicate(true))
	var results: Variant = (parsed as Dictionary).get("medical_results", {})
	if results is Dictionary:
		_medical_results = (results as Dictionary).duplicate(true)
	var water: Variant = (parsed as Dictionary).get("water_result", {})
	if water is Dictionary:
		_water_result = (water as Dictionary).duplicate(true)


func skills_for_target(has_npc: bool, location_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for skill in _skills:
		if String(skill.get("id", "")) == "medical_exam" and not is_medical_exam_unlocked():
			continue
		var contexts: Variant = skill.get("contexts", [])
		if contexts is not Array:
			continue
		if has_npc and contexts.has("npc"):
			result.append(skill.duplicate(true))
		elif location_id == "temporary_dorm" and contexts.has("temporary_dorm"):
			result.append(skill.duplicate(true))
	return result


func is_skill_available_for_npc(skill_id: String, npc_id: String) -> bool:
	if skill_id == "attack":
		return (
			NpcRegistry.is_npc_present_at(npc_id, NpcRegistry.get_location_of(npc_id))
			and NpcRegistry.can_interact_with_npc(npc_id)
			and (not is_repeatable_attack_target(npc_id) or not has_attempted_attack_today(npc_id))
			and (not NpcRegistry.is_npc_hostile(npc_id) or can_retry_hostile_attack(npc_id))
		)
	if skill_id == "medical_exam":
		# 医学检验只对宿舍淋浴水开放，不再以人物为目标。
		return false
	if skill_id == "dismiss":
		return bool(GameState.get_investigation_state("skill_unlocked_dismiss", false))
	if skill_id == "persuade_ally":
		return (
			(
				GameState.get_quest_stage("hermit_pollution_investigation") >= 2
				or GameState.get_quest_stage("chief_pollution_truth") >= 2
			)
			and npc_id not in ["mysterious_hermit", "li_leshui_day", "li_leshui_night"]
		)
	return true


func can_retry_hostile_attack(npc_id: String) -> bool:
	return (
		is_repeatable_attack_target(npc_id)
		and NpcRegistry.is_npc_hostile(npc_id)
		and not NpcRegistry.is_npc_killed(npc_id)
		and not has_attempted_attack_today(npc_id)
	)


func is_repeatable_attack_target(npc_id: String) -> bool:
	return npc_id in ["li_leshui_day", "li_leshui_night", "mysterious_hermit"]


func has_attempted_attack_today(npc_id: String) -> bool:
	if not is_repeatable_attack_target(npc_id):
		return false
	return int(GameState.get_investigation_state(_daily_attack_state_key(npc_id), -1)) == TimeSystem.current_day


func record_attack_attempt(npc_id: String) -> void:
	if not is_repeatable_attack_target(npc_id):
		return
	GameState.set_investigation_state(_daily_attack_state_key(npc_id), TimeSystem.current_day)


func _daily_attack_state_key(npc_id: String) -> String:
	# 昼夜李乐水是不同人格、敌对状态互不共享，但攻击次数按同一个肉身计算。
	var target_key := "li_leshui" if npc_id in ["li_leshui_day", "li_leshui_night"] else npc_id
	return "daily_attack_attempt:%s" % target_key


func is_medical_exam_unlocked() -> bool:
	return bool(GameState.get_investigation_state("skill_unlocked_medical_exam", false))


func get_medical_result(npc_id: String) -> Dictionary:
	if _medical_results.has(npc_id) and _medical_results[npc_id] is Dictionary:
		return (_medical_results[npc_id] as Dictionary).duplicate(true)
	var display_name := NpcRegistry.get_display_name(npc_id)
	return {
		"clue_id": "medical_exam_%s" % npc_id,
		"title": "%s医学检验结果" % display_name,
		"summary": "%s存在值得继续观察的慢性环境暴露迹象。" % display_name,
		"pages": ["简易医学检查发现，%s的身体状态存在无法完全用年龄和劳累解释的异常。现有条件不足以确定具体毒物，但应继续排查当地水源与长期环境暴露。" % display_name],
	}


func get_water_result() -> Dictionary:
	return _water_result.duplicate(true)


func perform_social_check(profile: Dictionary, skill_id: String, reason: String) -> Dictionary:
	var npc_id := String(profile.get("id", ""))
	var base_difficulty := 18
	var affinity := clampi(GameState.get_affinity(npc_id), -4, 5)
	var disclosure := clampi(NpcRegistry.get_disclosure_level(profile), 0, 4)
	var rationality := _reason_modifier(reason)
	var social_modifier := clampi(affinity + disclosure * 2 + rationality, -8, 10)
	var label := "劝说%s离开当前场景" if skill_id == "dismiss" else "拉拢%s加入共同摧毁祭坛的阵营"
	var result := CheckSystem.perform_check(
		"charisma",
		base_difficulty,
		social_modifier,
		label % String(profile.get("short_name", profile.get("display_name", npc_id))) + "；理由：" + reason
	)
	result["skill_id"] = skill_id
	result["affinity"] = affinity
	result["disclosure_level"] = disclosure
	result["reason_modifier"] = rationality
	result["social_modifier"] = social_modifier
	return result


func perform_trust_check(reason: String) -> Dictionary:
	# 夜间道士的信任门槛比阵营拉拢低；理由具体、带证据时降低最终难度。
	var rationality := _reason_modifier(reason)
	return perform_trust_check_with_modifier(reason, rationality)


func perform_trust_check_with_modifier(reason: String, rationality_modifier: int) -> Dictionary:
	var rationality := clampi(rationality_modifier, -5, 5)
	var result := CheckSystem.perform_check(
		"charisma",
		14,
		rationality,
		"说服夜间道士允许进入后室：" + reason
	)
	result["reason_modifier"] = rationality
	return result


func get_attack_preview(npc_id: String, weapon_id: String = "") -> Dictionary:
	var base_difficulty := CheckSystem.RAW_DIFFICULTY_MAX if npc_id in ["li_leshui_day", "li_leshui_night", "mysterious_hermit"] else 18
	var offering_penalty := GameState.get_ritual_offering_penalty() if npc_id in ["li_leshui_day", "li_leshui_night"] else 0
	base_difficulty += offering_penalty
	var story_reduction := 0
	var story_reduction_reasons: Array[String] = []
	if npc_id == "mysterious_hermit" and String(GameState.get_investigation_state("altar_resolution", "")) == "sealed":
		story_reduction += 5
		story_reduction_reasons.append("封印成功")
	if npc_id == "mysterious_hermit" and GameState.has_item("li_leshui_talisman"):
		story_reduction += 5
		story_reduction_reasons.append("持有李乐水的护符")
	if npc_id in ["li_leshui_day", "li_leshui_night"] and String(GameState.get_investigation_state("altar_resolution", "")) == "destroyed":
		story_reduction += 10
		story_reduction_reasons.append("祭坛已被摧毁")
	base_difficulty = maxi(CheckSystem.RAW_DIFFICULTY_MIN, base_difficulty - story_reduction)
	var reduction := _attack_weapon_reduction(weapon_id)
	var breakdown := CheckSystem.get_check_breakdown("strength", base_difficulty, reduction)
	return {
		"base_difficulty": int(breakdown.get("raw_difficulty", base_difficulty)),
		"offering_penalty": offering_penalty,
		"seal_reduction": story_reduction,
		"story_reduction_reason": "、".join(story_reduction_reasons),
		"weapon_reduction": int(breakdown.get("item_modifier", reduction)),
		"weapon_id": weapon_id,
		"weapon_name": "徒手" if weapon_id.is_empty() else ItemDB.get_display_name(weapon_id),
		"strength": int(breakdown.get("attribute_value", 0)),
		"final_difficulty": int(breakdown.get("final_difficulty", CheckSystem.MIN_DIFFICULTY)),
	}


func perform_attack_check(npc_id: String, weapon_id: String = "") -> Dictionary:
	var preview := get_attack_preview(npc_id, weapon_id)
	var reason := "攻击%s；武器：%s" % [NpcRegistry.get_short_name(npc_id), String(preview.get("weapon_name", "徒手"))]
	var result := CheckSystem.perform_check(
		"strength",
		int(preview.get("base_difficulty", 18)),
		int(preview.get("weapon_reduction", 0)),
		reason
	)
	result["weapon_id"] = weapon_id
	result["weapon_name"] = String(preview.get("weapon_name", "徒手"))
	result["weapon_reduction"] = int(preview.get("weapon_reduction", 0))
	return result


func get_altar_attack_preview(weapon_id: String = "") -> Dictionary:
	var base_difficulty := 20
	var reduction := _attack_weapon_reduction(weapon_id)
	var breakdown := CheckSystem.get_check_breakdown("strength", base_difficulty, reduction)
	return {
		"base_difficulty": int(breakdown.get("raw_difficulty", base_difficulty)),
		"weapon_reduction": int(breakdown.get("item_modifier", reduction)),
		"weapon_id": weapon_id,
		"weapon_name": "徒手" if weapon_id.is_empty() else ItemDB.get_display_name(weapon_id),
		"strength": int(breakdown.get("attribute_value", 0)),
		"final_difficulty": int(breakdown.get("final_difficulty", CheckSystem.MIN_DIFFICULTY)),
	}


func perform_altar_attack_check(weapon_id: String = "") -> Dictionary:
	var preview := get_altar_attack_preview(weapon_id)
	var result := CheckSystem.perform_check(
		"strength",
		int(preview.get("base_difficulty", 20)),
		int(preview.get("weapon_reduction", 0)),
		"攻击并摧毁洞内祭坛；武器：%s" % String(preview.get("weapon_name", "徒手"))
	)
	result["weapon_id"] = weapon_id
	result["weapon_name"] = String(preview.get("weapon_name", "徒手"))
	result["weapon_reduction"] = int(preview.get("weapon_reduction", 0))
	return result


func _attack_weapon_reduction(weapon_id: String) -> int:
	if weapon_id.is_empty():
		return 0
	var item := ItemDB.get_item(weapon_id)
	var explicit_reduction := int(item.get("attack_difficulty_reduction", 0))
	if explicit_reduction > 0:
		return clampi(explicit_reduction, 0, 15)
	var tags: Variant = item.get("tags", [])
	if tags is Array:
		for raw_tag in tags:
			var tag := String(raw_tag)
			if tag.contains("猎枪") or tag.contains("枪械"):
				return 15
			if tag.contains("工具"):
				return 3
	var name := ItemDB.get_display_name(weapon_id)
	if name.contains("猎枪"):
		return 15
	return 0


func social_breakdown(result: Dictionary) -> String:
	return "关系修正：好感 %+d，披露等级 %d（×2），理由合理度 %+d；合计 %+d。" % [
		int(result.get("affinity", 0)),
		int(result.get("disclosure_level", 0)),
		int(result.get("reason_modifier", 0)),
		int(result.get("social_modifier", 0)),
	]


func _reason_modifier(reason: String) -> int:
	var text := reason.strip_edges()
	if text.is_empty():
		return -5
	var score := 0
	if text.length() < 8:
		score -= 3
	elif text.length() < 16:
		score -= 1
	elif text.length() >= 28:
		score += 1
	if text.length() >= 55:
		score += 1
	for marker in ["因为", "所以", "证据", "线索", "报告", "检测", "危险", "保护", "答应", "交换", "亲眼"]:
		if text.contains(marker):
			score += 1
			break
	for entry in GameState.get_clue_book_entries():
		var title := String(entry.get("title", "")).strip_edges()
		if title.length() >= 3 and text.contains(title):
			score += 2
			break
	for vague in ["听我的", "别问", "必须照办", "没有理由", "就这样"]:
		if text.contains(vague):
			score -= 2
			break
	return clampi(score, -5, 5)
