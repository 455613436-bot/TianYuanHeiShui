extends Node
## Web LLM configuration must use the public CloudBase proxy without client credentials.


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	LLMConfig.apply_web_proxy()
	var provider := LLMService.get("_provider") as Node
	if provider == null:
		_fail("Web proxy provider was not installed")
		return
	if String(provider.get("base_url")) != LLMConfig.WEB_PROXY_BASE_URL:
		_fail("Web proxy base URL is incorrect")
		return
	if String(provider.get("model_name")) != LLMConfig.WEB_PROXY_MODEL:
		_fail("Web proxy model is incorrect")
		return
	if bool(provider.get("send_authorization")) or not String(provider.get("api_key")).is_empty():
		_fail("Web proxy provider still contains client credentials")
		return
	var headers: PackedStringArray = provider.call("_build_request_headers") as PackedStringArray
	for header in headers:
		if String(header).to_lower().begins_with("authorization:"):
			_fail("Web proxy request still emits an Authorization header")
			return

	print("WEB_PROXY_CONFIG_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("WEB_PROXY_CONFIG_SMOKE_FAILED: " + message)
	get_tree().quit(1)
