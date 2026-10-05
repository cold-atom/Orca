extends SceneTree

const Config = preload("res://addons/orca/scripts/config.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	var settings := EditorInterface.get_editor_settings()
	var keys := PackedStringArray([Config.SETTING_PROVIDER, Config.SETTING_PROVIDER_MODEL_CACHE])
	for provider_id in ["ollama", "lmstudio", "local_openai"]:
		for field in ["api_key", "model", "reasoning_effort", "base_url", "confirmed_origin", "agent_compatibility"]:
			keys.append(Config._provider_setting(provider_id, field))
	var original := {}
	for key in keys:
		original[key] = settings.get_setting(key) if settings.has_setting(key) else null

	Config.save_provider_profile("ollama", "", "qwen-fixture", "default", "http://127.0.0.1:11434/v1")
	Config.save_provider_profile("lmstudio", "lm-secret", "llama-fixture", "low", "http://127.0.0.1:1234/v1")
	Config.save_provider_profile("local_openai", "", "custom-fixture", "default", "http://127.0.0.1:18080/v1")
	var ollama := Config.get_provider_config("ollama")
	var lmstudio := Config.get_provider_config("lmstudio")
	var local := Config.get_provider_config("local_openai")
	_expect(ollama.get("api_key") == "" and ollama.get("model") == "qwen-fixture" and ollama.get("base_url") == "http://127.0.0.1:11434/v1", "Ollama should persist an isolated keyless profile")
	_expect(lmstudio.get("api_key") == "lm-secret" and lmstudio.get("model") == "llama-fixture" and lmstudio.get("base_url") == "http://127.0.0.1:1234/v1", "LM Studio should persist an isolated optionally authenticated profile")
	_expect(local.get("model") == "custom-fixture" and local.get("base_url") == "http://127.0.0.1:18080/v1", "generic local settings should persist an independent editable endpoint")
	Config.set_confirmed_origin("ollama", "http://192.168.1.20:11434")
	_expect(Config.get_confirmed_origin("ollama") == "http://192.168.1.20:11434" and Config.get_confirmed_origin("lmstudio") != "http://192.168.1.20:11434", "endpoint trust should persist per provider")
	_expect(EndpointPolicy.authorize_profile("ollama", {"base_url": "http://192.168.1.20:11434/v1", "confirmed_origin": Config.get_confirmed_origin("ollama")}).get("success", false), "persisted exact-origin trust should authorize that provider")
	_expect(not EndpointPolicy.authorize_profile("ollama", {"base_url": "http://192.168.1.20:11435/v1", "confirmed_origin": Config.get_confirmed_origin("ollama")}).get("success", true), "changing the trusted port should require confirmation again")
	var before_invalid := Config.get_provider_config("ollama")
	_expect(not Config.save_provider_profile("ollama", "replacement-secret", "replacement-model", "high", "not a URL"), "invalid endpoint drafts should fail atomically")
	_expect(Config.get_provider_config("ollama") == before_invalid, "invalid endpoint drafts must not pair new credentials with the previous endpoint")
	var binding_result := preload("res://addons/orca/scripts/agent_compatibility_probe.gd").create_binding(Config.get_provider_config("ollama"))
	_expect(binding_result.get("success", false) and Config.record_agent_probe_pass(binding_result.get("binding", {})), "a successful probe binding should persist")
	var disabled_status := Config.agent_compatibility_status("ollama", Config.get_provider_config("ollama"))
	_expect(disabled_status.get("passed", false) and not disabled_status.get("enabled", true), "a probe pass must remain disabled until separate opt-in")
	_expect(Config.set_agent_enabled("ollama", Config.get_provider_config("ollama"), true), "explicit opt-in should enable an exact passed binding")
	_expect(Config.agent_compatibility_status("ollama", Config.get_provider_config("ollama")).get("enabled", false), "matching enabled state should be returned to request snapshots")
	var changed_model := Config.get_provider_config("ollama")
	changed_model["model"] = "different-case-sensitive-model"
	_expect(not Config.agent_compatibility_status("ollama", changed_model).get("enabled", true), "model changes should invalidate persisted Agent compatibility")
	var cache_key := Config._provider_model_cache_key("ollama", "http://127.0.0.1:11434/api/tags", "empty")
	var oversized_models := []
	for index in range(Config.MAX_CACHED_PROVIDER_MODELS + 20):
		oversized_models.append({"id": "model-%d" % index})
	settings.set_setting(Config.SETTING_PROVIDER_MODEL_CACHE, {cache_key: {"fetched_at": "invalid", "models": oversized_models, "oversized_extra": "x".repeat(10000)}})
	var bounded_cache := Config.get_cached_provider_models("ollama", "http://127.0.0.1:11434/api/tags", "empty")
	_expect(bounded_cache.keys().size() == 2 and bounded_cache.get("fetched_at") == 0.0 and bounded_cache.get("models", []).size() == Config.MAX_CACHED_PROVIDER_MODELS, "provider cache envelopes should retain only bounded models and a type-checked timestamp")

	for key in keys:
		settings.set_setting(key, original[key])
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("provider_settings_editor_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("provider_settings_editor_test: ", failure)
	quit(1)
