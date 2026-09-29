@tool
extends Node

const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const SETTING_API_KEY = "orca/api/api_key"
const SETTING_API_URL = "orca/api/base_url"
const SETTING_MODEL = "orca/api/model"
const SETTING_PROVIDER = "orca/providers/selected"
const SETTING_MODEL_METADATA_CACHE = "orca/cache/model_metadata"
const SETTING_PROVIDER_MODEL_CACHE = "orca/cache/provider_models"

static func _get_editor_settings() -> EditorSettings:
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_settings()
	return null

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
		if provider_id == "custom":
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
		"reasoning_effort": get_reasoning_effort()
	}


static func get_provider_config(provider_id: String) -> Dictionary:
	var definition: Dictionary = ProviderRegistry.get_provider(provider_id).definition()
	return {
		"provider": provider_id,
		"api_key": get_api_key(provider_id),
		"base_url": str(_get_provider_value(provider_id, "base_url", definition.get("base_url", ""))),
		"model": str(_get_provider_value(provider_id, "model", definition.get("default_model", ""))),
		"reasoning_effort": str(_get_provider_value(provider_id, "reasoning_effort", "default"))
	}


static func save_provider_config(provider_id: String, api_key: String, model: String, reasoning_effort: String, base_url: String = "") -> void:
	var settings = _get_editor_settings()
	if not settings:
		return
	settings.set_setting(SETTING_PROVIDER, provider_id)
	save_provider_profile(provider_id, api_key, model, reasoning_effort, base_url)


static func save_provider_profile(provider_id: String, api_key: String, model: String, reasoning_effort: String, base_url: String = "") -> void:
	var settings = _get_editor_settings()
	if not settings:
		return
	settings.set_setting(_provider_setting(provider_id, "api_key"), api_key)
	settings.set_setting(_provider_setting(provider_id, "model"), model)
	settings.set_setting(_provider_setting(provider_id, "reasoning_effort"), reasoning_effort)
	if provider_id == "custom":
		settings.set_setting(_provider_setting(provider_id, "base_url"), base_url)


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


static func get_cached_provider_models(provider_id: String, credential_fingerprint: String = "") -> Dictionary:
	var settings = _get_editor_settings()
	if not settings or not settings.has_setting(SETTING_PROVIDER_MODEL_CACHE):
		return {}
	var cache = settings.get_setting(SETTING_PROVIDER_MODEL_CACHE)
	var entry = cache.get(_provider_model_cache_key(provider_id, credential_fingerprint), {}) if typeof(cache) == TYPE_DICTIONARY else {}
	return entry.duplicate(true) if typeof(entry) == TYPE_DICTIONARY else {}


static func set_cached_provider_models(provider_id: String, models: Array, credential_fingerprint: String = "") -> void:
	var settings = _get_editor_settings()
	if not settings:
		return
	var cache = settings.get_setting(SETTING_PROVIDER_MODEL_CACHE) if settings.has_setting(SETTING_PROVIDER_MODEL_CACHE) else {}
	if typeof(cache) != TYPE_DICTIONARY:
		cache = {}
	var incoming_key := _provider_model_cache_key(provider_id, credential_fingerprint)
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
		["base_url", definition.get("base_url", "")]
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


static func _provider_model_cache_key(provider_id: String, credential_fingerprint: String) -> String:
	return provider_id + "/" + credential_fingerprint
