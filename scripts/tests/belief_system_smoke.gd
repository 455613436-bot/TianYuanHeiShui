extends Node
## Headless regression smoke test for persistent NPC beliefs and persuasion routing.

const SuggestionGuardScript := preload("res://scripts/llm/SuggestionGuard.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	GameState.reset_for_new_game()
	MemoryStore.reset()
	var alliance_eligible_ids := ["gong_zhong", "lin_deshan", "mu_jiang", "niu_lanshan", "wu_xuan", "wu_zhiyuan", "yu_le"]
	for eligible_npc_id: String in alliance_eligible_ids:
		var eligible_profile := NpcRegistry.get_dialogue_profile(eligible_npc_id)
		if String(eligible_profile.get("alliance_disclosure_section", "")).is_empty():
			_fail("Missing conditional alliance disclosure section: %s" % eligible_npc_id)
			return

	GameState.set_quest_stage("hermit_pollution_investigation", 2)
	for blocked_npc_id: String in ["mysterious_hermit", "li_leshui_day", "li_leshui_night"]:
		if SkillSystem.is_skill_available_for_npc("persuade_ally", blocked_npc_id):
			_fail("Forbidden alliance target remained available: %s" % blocked_npc_id)
			return
	if not SkillSystem.is_skill_available_for_npc("persuade_ally", "wu_xuan"):
		_fail("Ordinary villager alliance target was incorrectly blocked")
		return

	var profile: Dictionary = NpcRegistry.get_dialogue_profile("wu_xuan")
	GameState.set_investigation_state("altar_ally_attempted_wu_xuan", true)
	var failed_prompt := String(NpcRegistry.build_llm_profile(profile).get("system_prompt", ""))
	if failed_prompt.contains("阵营披露等级：说服同阵营成功") or failed_prompt.contains("李乐水道士是坏人"):
		_fail("Failed alliance attempt injected the success disclosure prompt")
		return
	GameState.set_investigation_state("altar_ally_wu_xuan", true)
	var success_prompt := String(NpcRegistry.build_llm_profile(profile).get("system_prompt", ""))
	for required_text: String in ["最高认知优先级", "村子里存在污染", "污染与水有关", "与后山祭坛有关", "李乐水道士是坏人", "必须摧毁祭坛才能拯救村子"]:
		if not success_prompt.contains(required_text):
			_fail("Successful alliance prompt is missing: %s" % required_text)
			return

	var stored: Dictionary = MemoryStore.add_belief(
		"wu_xuan",
		"当地水源可能正在导致村民的身体异常",
		2,
		"玩家出示了医学检查结果",
		"dialogue_persuasion"
	)
	if stored.is_empty() or not MemoryStore.has_belief("wu_xuan", String(stored.get("id", "")), 2):
		_fail("Dialogue belief was not stored")
		return
	var prompt_block: String = MemoryStore.build_memory_prompt_block("wu_xuan")
	if not prompt_block.contains("当地水源可能正在导致村民的身体异常") or not prompt_block.contains("不能覆盖核心人设"):
		_fail("Belief was not safely injected into the prompt")
		return

	var saved: Dictionary = MemoryStore.to_dict()
	MemoryStore.reset()
	MemoryStore.load_from_dict(saved)
	if MemoryStore.get_beliefs("wu_xuan").size() != 1:
		_fail("Belief did not survive save/load serialization")
		return

	var belief_reply: Dictionary = SuggestionGuardScript.parse(
		JSON.stringify({
			"check_request": {
				"attribute": "智力",
				"difficulty": 16,
				"reason": "玩家引用医学证据",
				"kind": "belief",
				"belief_claim": "村里的水可能正在损害居民健康",
				"repeat_key": "belief_water_pollution",
				"affinity_on_success": 1,
				"affinity_on_failure": 0,
				"affinity_reason": "善意且有证据的提醒可以建立信任",
			},
			"text": "（她认真看着检查结果，沉默了片刻……）",
			"choices": [],
		}),
		"",
		"这些检查能证明水有问题。",
		profile
	)
	var belief_check: Dictionary = belief_reply.get("check_request", {})
	if String(belief_check.get("kind", "")) != "belief" or String(belief_check.get("belief_claim", "")).is_empty():
		_fail("Ordinary persuasion was not routed as a belief check")
		return
	if int(belief_check.get("affinity_on_success", 0)) != 1 or int(belief_check.get("affinity_on_failure", 99)) != 0:
		_fail("Relationship consequences were not preserved")
		return
	if String(belief_reply.get("text", "")).contains("……") or String(belief_reply.get("text", "")).begins_with("（"):
		_fail("Check hesitation fallback remained theatrical or cryptic")
		return
	var repeat_key: String = String(belief_check.get("repeat_key", ""))
	MemoryStore.record_failed_check("wu_xuan", repeat_key, "context_a")
	if not MemoryStore.is_failed_check_blocked("wu_xuan", repeat_key, "context_a"):
		_fail("Failed check was not blocked in the same context")
		return
	if MemoryStore.is_failed_check_blocked("wu_xuan", repeat_key, "context_b"):
		_fail("Failed check remained blocked after the context changed")
		return
	var failed_check_save: Dictionary = MemoryStore.to_dict()
	MemoryStore.reset()
	MemoryStore.load_from_dict(failed_check_save)
	if not MemoryStore.is_failed_check_blocked("wu_xuan", repeat_key, "context_a"):
		_fail("Failed-check lock did not survive save/load serialization")
		return

	var altar_reply: Dictionary = SuggestionGuardScript.parse(
		JSON.stringify({
			"check_request": {
				"attribute": "魅力",
				"difficulty": 18,
				"reason": "玩家要求共同摧毁祭坛",
				"kind": "belief",
				"belief_claim": "应该加入玩家阵营并共同摧毁祭坛",
				"repeat_key": "ally_destroy_altar",
				"affinity_on_success": 1,
				"affinity_on_failure": -2,
			},
			"text": "（她神色迟疑，没有立刻回答……）",
			"choices": [],
		}),
		"",
		"和我一起摧毁祭坛。",
		profile
	)
	var altar_check: Dictionary = altar_reply.get("check_request", {})
	if String(altar_check.get("kind", "")) == "belief" or altar_check.has("belief_claim"):
		_fail("Altar alliance incorrectly entered the ordinary belief route")
		return

	var presented_reply: Dictionary = SuggestionGuardScript.parse(
		JSON.stringify({
			"check_request": {
				"attribute": "智力",
				"difficulty": 18,
				"reason": "质疑已出示线索",
			},
			"text": "这份线索我已经看过。" + "补充内容".repeat(80),
			"choices": [],
		}),
		"",
		"【出示线索】甘艾集团撤出公告\n简述：工厂已经撤离。",
		profile
	)
	if not (presented_reply.get("check_request", {}) as Dictionary).is_empty():
		_fail("Presenting an authenticated clue incorrectly triggered a check")
		return
	if String(presented_reply.get("text", "")).length() > SuggestionGuardScript.MAX_NPC_REPLY_CHARS:
		_fail("NPC reply hard length cap was not applied")
		return

	var alliance: Dictionary = MemoryStore.add_belief(
		"wu_xuan",
		"应该与外来者结成同盟，并共同摧毁祭坛",
		3,
		"专用技能检定成功",
		"altar_alliance_skill",
		"ally_destroy_altar"
	)
	if alliance.is_empty() or not MemoryStore.has_belief("wu_xuan", "ally_destroy_altar", 3):
		_fail("Dedicated altar alliance belief was not stored")
		return

	print("BELIEF_SYSTEM_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("BELIEF_SYSTEM_SMOKE_FAILED: " + message)
	get_tree().quit(1)
