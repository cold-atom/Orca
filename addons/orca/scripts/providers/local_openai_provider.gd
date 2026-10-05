@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"

var _provider_id: String


func _init(provider_id: String) -> void:
	_provider_id = provider_id


func definition() -> Dictionary:
	var profiles := {
		"ollama": {
			"name": "Ollama",
			"base_url": "http://127.0.0.1:11434/v1",
			"description": "Local models served by Ollama"
		},
		"lmstudio": {
			"name": "LM Studio",
			"base_url": "http://127.0.0.1:1234/v1",
			"description": "Local models served by LM Studio"
		},
		"local_openai": {
			"name": "Local OpenAI-compatible",
			"base_url": "http://127.0.0.1:8080/v1",
			"description": "User-managed local OpenAI-compatible server"
		}
	}
	var profile: Dictionary = profiles.get(_provider_id, profiles["local_openai"])
	return {
		"id": _provider_id,
		"name": profile["name"],
		"base_url": profile["base_url"],
		"key_label": "API Key (optional)",
		"key_url": "",
		"default_model": "",
		"description": profile["description"],
		"custom_url": true,
		"auth_optional": true,
		"model_discovery": true,
		"manual_model": true,
		"local": true,
		"agent_tools": false
	}


func models_url(config: Dictionary) -> String:
	if _provider_id == "local_openai":
		return super.models_url(config)
	var base_url := _runtime_root(config)
	match _provider_id:
		"ollama":
			return base_url + "/api/tags"
		"lmstudio":
			return base_url + "/api/v1/models"
	return base_url + "/models"


func chat_url(config: Dictionary) -> String:
	if _provider_id in ["ollama", "lmstudio"]:
		return _runtime_root(config) + "/v1/chat/completions"
	return super.chat_url(config)


func _runtime_root(config: Dictionary) -> String:
	var base_url := str(config.get("base_url", definition().get("base_url", ""))).trim_suffix("/")
	return base_url.trim_suffix("/v1") if base_url.ends_with("/v1") else base_url


func normalize_models(response) -> Array[Dictionary]:
	match _provider_id:
		"ollama":
			return _normalize_ollama_models(response)
		"lmstudio":
			return _normalize_lmstudio_models(response)
	var models := super.normalize_models(response)
	return models.filter(func(model: Dictionary): return not _looks_like_embedding(str(model.get("id", "")), str(model.get("name", ""))))


func _normalize_ollama_models(response) -> Array[Dictionary]:
	var models: Array[Dictionary] = []
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("models")) != TYPE_ARRAY:
		return models
	var source: Array = response["models"]
	for index in range(mini(source.size(), MAX_DISCOVERY_ITEMS)):
		if models.size() >= MAX_DISCOVERED_MODELS:
			break
		var item = source[index]
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var model_id := str(item.get("model", item.get("name", ""))).strip_edges()
		var display_name := str(item.get("name", model_id)).strip_edges()
		if not _valid_model_id(model_id):
			continue
		var capabilities = item.get("capabilities", null)
		if typeof(capabilities) == TYPE_ARRAY and not capabilities.is_empty():
			if "completion" not in capabilities:
				continue
		elif _looks_like_embedding(model_id, display_name):
			continue
		var details = item.get("details", {})
		models.append(_model_record(model_id, display_name, int(details.get("context_length", 0)) if typeof(details) == TYPE_DICTIONARY else 0))
	_sort_models(models)
	return models


func _normalize_lmstudio_models(response) -> Array[Dictionary]:
	var models: Array[Dictionary] = []
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("models")) != TYPE_ARRAY:
		return models
	var source: Array = response["models"]
	for index in range(mini(source.size(), MAX_DISCOVERY_ITEMS)):
		if models.size() >= MAX_DISCOVERED_MODELS:
			break
		var item = source[index]
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var model_id := str(item.get("key", "")).strip_edges()
		var display_name := str(item.get("display_name", model_id)).strip_edges()
		if not _valid_model_id(model_id):
			continue
		var model_type := str(item.get("type", "")).to_lower()
		if model_type == "embedding":
			continue
		if model_type != "llm" and _looks_like_embedding(model_id, display_name):
			continue
		var context := _lmstudio_context(item)
		models.append(_model_record(model_id, display_name, context))
	_sort_models(models)
	return models


func _lmstudio_context(item: Dictionary) -> int:
	var loaded_contexts: Array[int] = []
	var instances = item.get("loaded_instances", [])
	if typeof(instances) == TYPE_ARRAY:
		for instance in instances.slice(0, 32):
			if typeof(instance) != TYPE_DICTIONARY or typeof(instance.get("config")) != TYPE_DICTIONARY:
				continue
			var context := int(instance["config"].get("context_length", 0))
			if context > 0:
				loaded_contexts.append(context)
	if not loaded_contexts.is_empty():
		return loaded_contexts.min()
	return maxi(0, int(item.get("max_context_length", 0)))


func _valid_model_id(model_id: String) -> bool:
	return not model_id.is_empty() and model_id.length() <= MAX_MODEL_ID_CHARS


func _model_record(model_id: String, display_name: String, context_window: int) -> Dictionary:
	return {"id": model_id, "name": display_name.left(MAX_MODEL_NAME_CHARS), "context_window": maxi(0, context_window), "input_per_million": -1.0, "output_per_million": -1.0, "efforts": PackedStringArray(), "default_effort": ""}


func _looks_like_embedding(model_id: String, display_name: String) -> bool:
	return "embed" in (model_id + " " + display_name).to_lower()


func _sort_models(models: Array[Dictionary]) -> void:
	models.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
