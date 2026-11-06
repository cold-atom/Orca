@tool
extends Node

const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const AgentCompatibilityProbe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const RequestTimeouts = preload("res://addons/orca/scripts/request_timeouts.gd")
const SETTING_API_KEY = "orca/api/api_key"
const SETTING_API_URL = "orca/api/base_url"
const SETTING_MODEL = "orca/api/model"
const SETTING_PROVIDER = "orca/providers/selected"
const SETTING_MODEL_METADATA_CACHE = "orca/cache/model_metadata"
const SETTING_PROVIDER_MODEL_CACHE = "orca/cache/provider_models_v3"
const MAX_CACHED_PROVIDER_MODELS := 200
const PROJECT_SCRIPT_EDITS_PREFIX := "orca/script_edits/projects/"
const SETTING_UI_LANGUAGE := "orca/interface/language"
const UI_LANGUAGES := ["en", "zh_CN", "es", "ja", "ko"]

static func _get_editor_settings() -> EditorSettings:
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_settings()
	return null


static func get_ui_language() -> String:
	var settings := _get_editor_settings()
	var value = settings.get_setting(SETTING_UI_LANGUAGE) if settings != null and settings.has_setting(SETTING_UI_LANGUAGE) else "en"
	return value if typeof(value) == TYPE_STRING and value in UI_LANGUAGES else "en"


static func set_ui_language(locale: String) -> bool:
	var settings := _get_editor_settings()
	if settings == null or locale not in UI_LANGUAGES:
		return false
	settings.set_setting(SETTING_UI_LANGUAGE, locale)
	return get_ui_language() == locale


static func project_script_edit_preference() -> Dictionary:
	var fallback := {"enabled": false, "revision": ""}
	var settings := _get_editor_settings()
	var root := ProjectSettings.globalize_path("res://").simplify_path()
	if settings == null or root.is_empty() or root.length() > 4096:
		return fallback
	var key := PROJECT_SCRIPT_EDITS_PREFIX + root.sha256_text()
	if not settings.has_setting(key):
		return fallback
	var record = settings.get_setting(key)
	if typeof(record) != TYPE_DICTIONARY or record.size() != 4 or typeof(record.get("version")) != TYPE_INT or record.get("version") != 1 or record.get("project_root") != root or typeof(record.get("enabled")) != TYPE_BOOL or typeof(record.get("revision")) != TYPE_STRING:
		return fallback
	var revision: String = record["revision"]
	if revision.length() != 32:
		return fallback
	for character in revision:
		if not "0123456789abcdef".contains(character):
			return fallback
	return {"enabled": record["enabled"], "revision": revision}


static func set_project_script_edit_default(enabled: bool) -> bool:
	# Only explicit Orca UI decisions call this setter. Storage is outside res://,
	# never in project metadata, provider profiles, sessions or recovery records.
	var settings := _get_editor_settings()
	var root := ProjectSettings.globalize_path("res://").simplify_path()
	if settings == null or root.is_empty() or root.length() > 4096:
		return false
	var bytes := Crypto.new().generate_random_bytes(16)
	if bytes.size() != 16:
		return false
	var revision := bytes.hex_encode()
	settings.set_setting(PROJECT_SCRIPT_EDITS_PREFIX + root.sha256_text(), {"version": 1, "project_root": root, "enabled": enabled, "revision": revision})
	return project_script_edit_preference() == {"enabled": enabled, "revision": revision}

func _init_settings() -> void:
	var settings = _get_editor_settings()
	if not settings:
		return
		
	if not settings.has_setting(SETTING_API_KEY):
		settings.set_setting(SETTING_API_KEY, "")
	if not settings.has_setting(SETTING_API_URL):
		settings.set_setting(SETTING_API_URL, "https://api.openai.com/v1")
	if not settings.has_setting(SETTING_MODEL):
		settings.set_setting(SETTING_MODEL, "gpt-4o")
	if not settings.has_setting(SETTING_PROVIDER):
		var legacy_url := str(settings.get_setting(SETTING_API_URL))
		var provider_id := ProviderRegistry.infer_provider(legacy_url)
		settings.set_setting(SETTING_PROVIDER, provider_id)
		settings.set_setting(_provider_setting(provider_id, "api_key"), str(settings.get_setting(SETTING_API_KEY)))
		settings.set_setting(_provider_setting(provider_id, "model"), str(settings.get_setting(SETTING_MODEL)))
		if bool(ProviderRegistry.get_provider(provider_id).definition().get("custom_url", false)):
			settings.set_setting(_provider_setting(provider_id, "base_url"), legacy_url)
	if not settings.has_setting(SETTING_MODEL_METADATA_CACHE):
		settings.set_setting(SETTING_MODEL_METADATA_CACHE, {})
	if not settings.has_setting(SETTING_PROVIDER_MODEL_CACHE):
		settings.set_setting(SETTING_PROVIDER_MODEL_CACHE, {})
	for provider_id in ProviderRegistry.PROVIDER_IDS:
		_ensure_provider_settings(settings, provider_id)

static func get_provider() -> String:
	var settings = _get_editor_settings()
	return str(settings.get_setting(SETTING_PROVIDER)) if settings and settings.has_setting(SETTING_PROVIDER) else "openai"


static func get_api_key(provider_id: String = "") -> String:
	provider_id = get_provider() if provider_id.is_empty() else provider_id
	return str(_get_provider_value(provider_id, "api_key", ""))

static func get_api_url() -> String:
	var provider_id := get_provider()
	var definition: Dictionary = ProviderRegistry.get_provider(provider_id).definition()
	if bool(definition.get("custom_url", false)):
		return str(_get_provider_value(provider_id, "base_url", definition.get("base_url", "")))
	return str(definition.get("base_url", ""))

static func get_model() -> String:
	var provider_id := get_provider()
	var default_model := str(ProviderRegistry.get_provider(provider_id).definition().get("default_model", ""))
	return str(_get_provider_value(provider_id, "model", default_model))


static func get_reasoning_effort() -> String:
	return str(_get_provider_value(get_provider(), "reasoning_effort", "default"))


static func get_active_provider_config() -> Dictionary:
	return {
		"provider": get_provider(),
		"api_key": get_api_key(),
		"base_url": get_api_url(),
		"model": get_model(),
		"reasoning_effort": get_reasoning_effort(),
		"api_mode": _get_provider_value(get_provider(), "api_mode", ProviderRegistry.get_provider(get_provider()).definition().get("default_api_mode", "chat_completions")),
		"continuation_style": _get_provider_value(get_provider(), "continuation_style", "standard"),
		"confirmed_origin": get_confirmed_origin(get_provider()),
		"agent_compatibility": get_agent_compatibility(get_provider()),
		"image_input_override": _get_provider_value(get_provider(), "image_input_override", {})
	}.merged(get_request_timeouts(get_provider()))


static func get_provider_config(provider_id: String) -> Dictionary:
	var definition: Dictionary = ProviderRegistry.get_provider(provider_id).definition()
	return {
		"provider": provider_id,
		"api_key": get_api_key(provider_id),
		# Managed origins are release-owned, including after a deployment cutover.
		"base_url": str(definition.get("base_url", "")) if bool(definition.get("managed_auth", false)) else str(_get_provider_value(provider_id, "base_url", definition.get("base_url", ""))),
		"model": str(_get_provider_value(provider_id, "model", definition.get("default_model", ""))),
		"reasoning_effort": str(_get_provider_value(provider_id, "reasoning_effort", "default")),
		"api_mode": _get_provider_value(provider_id, "api_mode", definition.get("default_api_mode", "chat_completions")),
		"continuation_style": _get_provider_value(provider_id, "continuation_style", "standard"),
		"confirmed_origin": get_confirmed_origin(provider_id),
		"agent_compatibility": get_agent_compatibility(provider_id),
		"image_input_override": _get_provider_value(provider_id, "image_input_override", {})
	}.merged(get_request_timeouts(provider_id))


static func get_request_timeouts(provider_id: String) -> Dictionary:
	var values := RequestTimeouts.defaults(provider_id)
	if provider_id != "orca_cloud":
		for field in [RequestTimeouts.RESPONSE_START_FIELD, RequestTimeouts.INACTIVITY_FIELD]:
			var stored = _get_provider_value(provider_id, field, values[field])
			if RequestTimeouts.valid_seconds(stored):
				values[field] = int(stored)
		if not RequestTimeouts.is_local(provider_id):
			var enabled = _get_provider_value(provider_id, RequestTimeouts.CUSTOM_ENABLED_FIELD, null)
			if enabled == null:
				# Only pre-toggle, non-default saved values imply an existing override.
				var previous := RequestTimeouts.defaults(provider_id)
				values[RequestTimeouts.CUSTOM_ENABLED_FIELD] = values[RequestTimeouts.RESPONSE_START_FIELD] != previous[RequestTimeouts.RESPONSE_START_FIELD] or values[RequestTimeouts.INACTIVITY_FIELD] != previous[RequestTimeouts.INACTIVITY_FIELD]
			else:
				values[RequestTimeouts.CUSTOM_ENABLED_FIELD] = typeof(enabled) == TYPE_BOOL and enabled
	return values


static func save_provider_config(provider_id: String, api_key: String, model: String, reasoning_effort: String, base_url: String = "", api_mode: String = "", continuation_style: String = "standard", request_timeouts: Dictionary = {}) -> bool:
	var settings = _get_editor_settings()
	if not settings:
		return false
	if not save_provider_profile(provider_id, api_key, model, reasoning_effort, base_url, api_mode, continuation_style, request_timeouts):
		return false
	settings.set_setting(SETTING_PROVIDER, provider_id)
	return true


static func save_provider_profile(provider_id: String, api_key: String, model: String, reasoning_effort: String, base_url: String = "", api_mode: String = "", continuation_style: String = "standard", request_timeouts: Dictionary = {}) -> bool:
	var settings = _get_editor_settings()
	if not settings:
		return false
	var definition: Dictionary = ProviderRegistry.get_provider(provider_id).definition()
	if bool(definition.get("managed_auth", false)):
		api_key = "" # Account credentials are exclusively owned by the OS-vault service.
		base_url = str(definition.get("base_url", ""))
		continuation_style = "standard" # Effective continuation comes from the live catalog.
	api_mode = str(definition.get("default_api_mode", "chat_completions")) if api_mode.is_empty() else api_mode
	if api_mode not in ["chat_completions", "responses"] or continuation_style not in ["standard", "deepseek"] or (provider_id != "azure" and (api_mode != "chat_completions" or continuation_style != "standard")):
		return false
	var resolved := RequestTimeouts.resolve(get_request_timeouts(provider_id).merged(request_timeouts, true).merged({"provider": provider_id}, true))
	if not resolved.get("success", false):
		return false
	var normalized_base := base_url
	if bool(definition.get("custom_url", false)):
		var inspected := EndpointPolicy.inspect_base_url(base_url)
		if not inspected.get("success", false):
			return false
		normalized_base = str(inspected["base_url"])
	settings.set_setting(_provider_setting(provider_id, "api_key"), api_key)
	settings.set_setting(_provider_setting(provider_id, "model"), model)
	settings.set_setting(_provider_setting(provider_id, "reasoning_effort"), reasoning_effort)
	settings.set_setting(_provider_setting(provider_id, "api_mode"), api_mode)
	settings.set_setting(_provider_setting(provider_id, "continuation_style"), continuation_style)
	if bool(definition.get("custom_url", false)):
		settings.set_setting(_provider_setting(provider_id, "base_url"), normalized_base)
	if not request_timeouts.is_empty() and not bool(definition.get("managed_auth", false)):
		for field in resolved["values"]:
			settings.set_setting(_provider_setting(provider_id, field), resolved["values"][field])
	return true


static func get_confirmed_origin(provider_id: String) -> String:
	return str(_get_provider_value(provider_id, "confirmed_origin", ""))


static func set_image_input_override(provider_id: String, binding: String, enabled: bool) -> void:
	var settings := _get_editor_settings()
	if settings:
		settings.set_setting(_provider_setting(provider_id, "image_input_override"), {"binding": binding, "enabled": enabled})


static func set_confirmed_origin(provider_id: String, origin: String) -> void:
	var settings = _get_editor_settings()
	if settings:
		settings.set_setting(_provider_setting(provider_id, "confirmed_origin"), origin)


static func get_agent_compatibility(provider_id: String) -> Dictionary:
	var value = _get_provider_value(provider_id, "agent_compatibility", {})
	return value.duplicate(true) if typeof(value) == TYPE_DICTIONARY else {}


static func record_agent_probe_pass(binding: Dictionary) -> bool:
	var settings = _get_editor_settings()
	if not settings or str(binding.get("provider", "")).is_empty():
		return false
	var record := binding.duplicate(true)
	record["passed_at"] = Time.get_unix_time_from_system()
	record["enabled"] = false
	settings.set_setting(_provider_setting(str(binding["provider"]), "agent_compatibility"), record)
	return true


static func clear_agent_compatibility(provider_id: String) -> void:
	var settings = _get_editor_settings()
	if settings:
		settings.set_setting(_provider_setting(provider_id, "agent_compatibility"), {})


static func set_agent_enabled(provider_id: String, config: Dictionary, enabled: bool) -> bool:
	var binding_result := AgentCompatibilityProbe.create_binding(config)
	if not binding_result.get("success", false):
		return false
	var record := get_agent_compatibility(provider_id)
	if not AgentCompatibilityProbe.record_matches_binding(record, binding_result["binding"]):
		return false
	record["enabled"] = enabled
	var settings = _get_editor_settings()
	if not settings:
		return false
	settings.set_setting(_provider_setting(provider_id, "agent_compatibility"), record)
	return true


static func agent_compatibility_status(provider_id: String, config: Dictionary) -> Dictionary:
	var binding_result := AgentCompatibilityProbe.create_binding(config)
	if not binding_result.get("success", false):
		return {"passed": false, "enabled": false, "reason": str(binding_result.get("error", "Compatibility binding is invalid."))}
	var record := config.get("agent_compatibility", get_agent_compatibility(provider_id))
	var passed := typeof(record) == TYPE_DICTIONARY and AgentCompatibilityProbe.record_matches_binding(record, binding_result["binding"])
	return {"passed": passed, "enabled": passed and bool(record.get("enabled", false)), "binding": binding_result["binding"], "reason": "" if passed else "Run the compatibility probe for this exact endpoint and model."}


static func get_cached_model_metadata(provider: String, model: String) -> Dictionary:
	var settings = _get_editor_settings()
	if not settings or not settings.has_setting(SETTING_MODEL_METADATA_CACHE):
		return {}
	var cache = settings.get_setting(SETTING_MODEL_METADATA_CACHE)
	if typeof(cache) != TYPE_DICTIONARY:
		return {}
	var value = cache.get(_model_cache_key(provider, model), {})
	return value.duplicate(true) if typeof(value) == TYPE_DICTIONARY else {}


static func set_cached_model_metadata(provider: String, model: String, metadata: Dictionary) -> void:
	var settings = _get_editor_settings()
	if not settings:
		return
	var cache = settings.get_setting(SETTING_MODEL_METADATA_CACHE) if settings.has_setting(SETTING_MODEL_METADATA_CACHE) else {}
	if typeof(cache) != TYPE_DICTIONARY:
		cache = {}
	var incoming_key := _model_cache_key(provider, model)
	if cache.size() >= 64 and not cache.has(incoming_key):
		var oldest_key := ""
		var oldest_time := INF
		for cache_key in cache:
			var entry = cache[cache_key]
			var fetched_at := float(entry.get("fetched_at", 0.0)) if typeof(entry) == TYPE_DICTIONARY else 0.0
			if fetched_at < oldest_time:
				oldest_time = fetched_at
				oldest_key = str(cache_key)
		if not oldest_key.is_empty():
			cache.erase(oldest_key)
	cache[incoming_key] = {
		"fetched_at": Time.get_unix_time_from_system(),
		"metadata": metadata.duplicate(true)
	}
	settings.set_setting(SETTING_MODEL_METADATA_CACHE, cache)


static func remove_cached_model_metadata(provider: String, model: String) -> void:
	var settings = _get_editor_settings()
	if not settings or not settings.has_setting(SETTING_MODEL_METADATA_CACHE):
		return
	var cache = settings.get_setting(SETTING_MODEL_METADATA_CACHE)
	if typeof(cache) != TYPE_DICTIONARY:
		return
	cache.erase(_model_cache_key(provider, model))
	settings.set_setting(SETTING_MODEL_METADATA_CACHE, cache)


static func _model_cache_key(provider: String, model: String) -> String:
	return provider.strip_edges().to_lower() + "/" + model.strip_edges().to_lower()


static func get_cached_provider_models(provider_id: String, endpoint: String, credential_fingerprint: String = "") -> Dictionary:
	var settings = _get_editor_settings()
	if not settings or not settings.has_setting(SETTING_PROVIDER_MODEL_CACHE):
		return {}
	var cache = settings.get_setting(SETTING_PROVIDER_MODEL_CACHE)
	var entry = cache.get(_provider_model_cache_key(provider_id, endpoint, credential_fingerprint), {}) if typeof(cache) == TYPE_DICTIONARY else {}
	if typeof(entry) != TYPE_DICTIONARY:
		return {}
	var models = entry.get("models", [])
	var fetched_at = entry.get("fetched_at", 0.0)
	return {
		"fetched_at": float(fetched_at) if typeof(fetched_at) in [TYPE_INT, TYPE_FLOAT] else 0.0,
		"models": (models.slice(0, MAX_CACHED_PROVIDER_MODELS) if typeof(models) == TYPE_ARRAY else []).duplicate(true)
	}


static func set_cached_provider_models(provider_id: String, endpoint: String, models: Array, credential_fingerprint: String = "") -> void:
	var settings = _get_editor_settings()
	if not settings:
		return
	var cache = settings.get_setting(SETTING_PROVIDER_MODEL_CACHE) if settings.has_setting(SETTING_PROVIDER_MODEL_CACHE) else {}
	if typeof(cache) != TYPE_DICTIONARY:
		cache = {}
	var incoming_key := _provider_model_cache_key(provider_id, endpoint, credential_fingerprint)
	if cache.size() >= 16 and not cache.has(incoming_key):
		var oldest_key := ""
		var oldest_time := INF
		for cache_key in cache:
			var entry = cache[cache_key]
			var fetched_at := float(entry.get("fetched_at", 0.0)) if typeof(entry) == TYPE_DICTIONARY else 0.0
			if fetched_at < oldest_time:
				oldest_time = fetched_at
				oldest_key = str(cache_key)
		if not oldest_key.is_empty():
			cache.erase(oldest_key)
	cache[incoming_key] = {"fetched_at": Time.get_unix_time_from_system(), "models": models.duplicate(true)}
	settings.set_setting(SETTING_PROVIDER_MODEL_CACHE, cache)


static func _ensure_provider_settings(settings: EditorSettings, provider_id: String) -> void:
	var definition: Dictionary = ProviderRegistry.get_provider(provider_id).definition()
	for pair in [
		["api_key", ""],
		["model", definition.get("default_model", "")],
		["reasoning_effort", "default"],
		["api_mode", definition.get("default_api_mode", "chat_completions")],
		["continuation_style", "standard"],
		["base_url", definition.get("base_url", "")],
		["confirmed_origin", ""],
		["agent_compatibility", {}]
	]:
		var setting := _provider_setting(provider_id, pair[0])
		if not settings.has_setting(setting):
			settings.set_setting(setting, pair[1])


static func _get_provider_value(provider_id: String, field: String, fallback):
	var settings = _get_editor_settings()
	var setting := _provider_setting(provider_id, field)
	return settings.get_setting(setting) if settings and settings.has_setting(setting) else fallback


static func _provider_setting(provider_id: String, field: String) -> String:
	return "orca/providers/%s/%s" % [provider_id, field]


static func _provider_model_cache_key(provider_id: String, endpoint: String, credential_fingerprint: String) -> String:
	var normalized_endpoint := endpoint.strip_edges().trim_suffix("/")
	return provider_id + "/" + normalized_endpoint.sha256_text() + "/" + credential_fingerprint
