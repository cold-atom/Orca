extends SceneTree

const ProviderModelService = preload("res://addons/orca/scripts/provider_model_service.gd")
const TEST_BASE_URL := "http://127.0.0.1:18473/local-models"

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var service := ProviderModelService.new()
	get_root().add_child(service)
	var result: Dictionary = {}
	service.models_loaded.connect(func(provider_id: String, models: Array, from_cache: bool):
		result.merge({"kind": "loaded", "provider": provider_id, "models": models, "from_cache": from_cache}, true)
	)
	service.models_failed.connect(func(provider_id: String, message: String):
		result.merge({"kind": "failed", "provider": provider_id, "message": message}, true)
	)
	service.fetch_models("ollama", {"api_key": "", "base_url": TEST_BASE_URL})
	var deadline := Time.get_ticks_msec() + 10000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(result.get("kind") == "loaded", "keyless local model discovery should complete: " + str(result))
	_expect(result.get("provider") == "ollama" and result.get("from_cache") == false, "local discovery should retain provider identity and network provenance")
	var models: Array = result.get("models", [])
	_expect(models.size() == 2, "Ollama discovery should hide explicit embeddings and retain completion or neutral models")
	if models.size() == 2:
		_expect(models[0].get("id") == "neutral-local" and models[1].get("id") == "qwen-coder-local", "Ollama models should use deterministic normalized ordering")
		_expect(models[1].get("context_window") == 32768, "Ollama native context metadata should be retained")
	result.clear()
	service.fetch_models("lmstudio", {"api_key": "", "base_url": "http://127.0.0.1:18473/lmstudio-models/v1"})
	deadline = Time.get_ticks_msec() + 10000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(result.get("kind") == "loaded", "LM Studio native discovery should complete")
	models = result.get("models", [])
	_expect(models.size() == 1 and models[0].get("id") == "llama-local" and models[0].get("context_window") == 8192, "LM Studio discovery should exclude embeddings and prefer loaded context")
	result.clear()
	service.fetch_models("ollama", {"api_key": "redirect-secret", "base_url": "http://127.0.0.1:18473/redirect-models"})
	deadline = Time.get_ticks_msec() + 10000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(result.get("kind") == "failed", "model discovery redirects should be rejected rather than followed")
	var stale_request := HTTPRequest.new()
	var active_request := HTTPRequest.new()
	service.add_child(stale_request)
	service.add_child(active_request)
	service._request = active_request
	service._generation = 20
	service._on_request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), "{}".to_utf8_buffer(), stale_request, 19, "ollama", {})
	_expect(service._request == active_request and is_instance_valid(active_request), "a stale discovery callback must not clear or free the newer active request")
	service._request = null
	active_request.queue_free()
	var oversized_cache := []
	for index in range(250):
		oversized_cache.append({"id": "cached-%d" % index, "name": "n".repeat(300), "efforts": ["low", "high"]})
	oversized_cache.append({"id": "x".repeat(300)})
	oversized_cache[0]["context_window"] = {"invalid": true}
	oversized_cache[0]["input_per_million"] = ["invalid"]
	var sanitized_cache: Array[Dictionary] = service._sanitize_cached_models(oversized_cache)
	_expect(sanitized_cache.size() == 200 and str(sanitized_cache[0].get("name", "")).length() <= 256 and sanitized_cache[0].get("context_window") == 0, "cached discovery records should be bounded and sanitized before UI use")
	service.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("provider_model_service_integration_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("provider_model_service_integration_test: ", failure)
	quit(1)
