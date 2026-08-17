extends Node
## Headless regression smoke test for persistent NPC beliefs and persuasion routing.

const SuggestionGuardScript := preload("res://scripts/llm/SuggestionGuard.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	MemoryStore.reset()
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

	var profile: Dictionary = NpcRegistry.get_dialogue_profile("wu_xuan")
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
