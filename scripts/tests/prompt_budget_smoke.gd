extends Node
## Regression coverage for the compact shared dialogue contract and sent context caps.

const OpenAILLMScript = preload("res://scripts/llm/OpenAILLM.gd")
const DialoguePromptScript = preload("res://scripts/llm/DialoguePrompt.gd")
const LEGACY_SHARED_PROMPT_CHARS := 12215
const SHARED_PROMPT_MAX_CHARS := 7500


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var contract := DialoguePromptScript.SHARED_CONTRACT
	if contract.length() > SHARED_PROMPT_MAX_CHARS:
		_fail("Shared prompt exceeds the 7500-character budget")
		return
	var reduction := 1.0 - float(contract.length()) / float(LEGACY_SHARED_PROMPT_CHARS)
	if reduction < 0.35:
		_fail("Shared prompt reduction is below thirty-five percent")
		return
	for marker in ["check_request", "item_used", "item_request", "offer_request", "mentions", "choices", "mood", "【出示线索】"]:
		if not contract.contains(marker):
			_fail("Shared prompt lost required rule: %s" % marker)
			return
	if MemoryStore.NPC_TURNS_TO_SEND_LLM != 10:
		_fail("Dialogue history send limit is not ten turns")
		return
	if MemoryStore.GLOBAL_MEMORY_PROMPT_LIMIT != 12 or MemoryStore.SUMMARY_PROMPT_MAX_CHARS != 1200:
		_fail("Memory prompt limits do not match the compact contract")
		return

	GameState.reset_for_new_game()
	MemoryStore.reset()
	for index in range(20):
		MemoryStore.add_global_memory("共享记忆 %02d" % index)
	var global_lines := MemoryStore.get_global_memory_text(MemoryStore.GLOBAL_MEMORY_PROMPT_LIMIT).split("\n", false)
	if global_lines.size() != 12 or not String(global_lines[0]).contains("08"):
		_fail("Global memory prompt did not keep the latest twelve entries")
		return
	MemoryStore.set_summary("prompt_test", "记".repeat(1600))
	var memory_block := MemoryStore.build_memory_prompt_block("prompt_test")
	var summary_marker := "## 你（该 NPC）与玩家的既往关键印象\n"
	var summary_start := memory_block.find(summary_marker) + summary_marker.length()
	var summary_end := memory_block.find("\n\n", summary_start)
	var transmitted_summary := memory_block.substr(summary_start, summary_end - summary_start)
	if transmitted_summary.length() != 1200:
		_fail("NPC summary was not capped to 1200 characters for transmission")
		return

	var fewshots: Array = []
	for index in range(5):
		fewshots.append({"role": "user", "content": "玩家样例 %d" % index})
		fewshots.append({"role": "assistant", "content": "角色样例 %d" % index})
	var provider := OpenAILLMScript.new()
	add_child(provider)
	var messages: Array = provider.call("_build_messages", {
		"id": "prompt_test",
		"display_name": "测试角色",
		"system_prompt": "你是测试角色。",
		"fewshots": fewshots,
	}, [], "你好")
	# system + 3 pairs + current user
	if messages.size() != 8:
		_fail("Few-shot transmission was not limited to three pairs")
		return
	var sent_system := String((messages[0] as Dictionary).get("content", ""))
	if not sent_system.contains("【玩家当前持有】") or not sent_system.contains("## 输出格式"):
		_fail("Built system prompt lost inventory or output contract")
		return
	provider.queue_free()
	print("PROMPT_BUDGET_SMOKE_OK chars=%d reduction=%.1f%%" % [contract.length(), reduction * 100.0])
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("PROMPT_BUDGET_SMOKE_FAILED: " + message)
	get_tree().quit(1)
