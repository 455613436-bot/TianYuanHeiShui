extends Node
## Headless regression smoke test for local OpenAI reply typewriter fast-forward.

const OpenAILLMScript := preload("res://scripts/llm/OpenAILLM.gd")

var _active_requests := {41: true, 42: true}
var _started_count := 0
var _chunks: Array[String] = []
var _reply_count := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var provider := OpenAILLMScript.new()
	add_child(provider)
	provider.call("_emit_typewriter_stable", 41, "test_npc", {
		"text": "甲乙丙丁",
		"mood": "thinking",
		"choices": ["继续"],
	}, self)
	if _started_count != 1:
		_fail("Typewriter did not announce a complete reply context")
		return
	if provider.fast_forward_request(999):
		_fail("Unknown or network-pending request was fast-forwarded")
		return
	if not provider.fast_forward_request(41):
		_fail("Available local typewriter rejected fast-forward")
		return
	if _chunks != ["甲乙丙丁"] or _reply_count != 1:
		_fail("Fast-forward did not reveal and finalize the complete reply once")
		return
	if provider.fast_forward_request(41):
		_fail("Completed typewriter accepted a repeated fast-forward")
		return
	await get_tree().create_timer(0.12).timeout
	if _reply_count != 1:
		_fail("Suspended typewriter coroutine finalized the reply twice")
		return

	provider.call("_emit_typewriter_stable", 42, "test_npc", {"text": "旧回复"}, self)
	provider.cancel_request(42)
	_active_requests.erase(42)
	await get_tree().create_timer(0.12).timeout
	if provider.fast_forward_request(42) or _reply_count != 1:
		_fail("Cancelled local typewriter delivered stale content")
		return

	var original_provider: Node = LLMService.get("_provider") as Node
	var inflight: Dictionary = LLMService.get("_inflight") as Dictionary
	inflight[43] = {
		"session_id": 7,
		"npc_id": "service_test_npc",
		"profile": {"id": "service_test_npc"},
		"user_text": "测试",
		"purpose": "dialogue",
	}
	LLMService.set("_provider", provider)
	provider.call("_emit_typewriter_stable", 43, "service_test_npc", {"text": "服务转发"}, LLMService)
	if not LLMService.fast_forward_request(43) or LLMService.is_request_active(43):
		LLMService.set("_provider", original_provider)
		_fail("LLMService did not forward fast-forward to the active provider")
		return
	LLMService.set("_provider", original_provider)

	print("LLM_FAST_FORWARD_SMOKE_OK")
	get_tree().quit(0)


func is_request_active(request_id: int) -> bool:
	return bool(_active_requests.get(request_id, false))


func deliver_reply_started(_request_id: int, _npc_id: String, _mood: String, _full_text: String) -> void:
	_started_count += 1


func deliver_chunk(_request_id: int, _npc_id: String, accumulated_text: String) -> void:
	_chunks.append(accumulated_text)


func deliver_reply(request_id: int, _npc_id: String, _reply: Dictionary) -> void:
	_reply_count += 1
	_active_requests.erase(request_id)


func _fail(message: String) -> void:
	push_error("LLM_FAST_FORWARD_SMOKE_FAILED: " + message)
	get_tree().quit(1)
