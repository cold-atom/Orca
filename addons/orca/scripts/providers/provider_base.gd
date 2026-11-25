@tool
extends RefCounted

const MAX_DISCOVERED_MODELS := 200
const MAX_DISCOVERY_ITEMS := 1000
const MAX_MODEL_ID_CHARS := 256
const MAX_MODEL_NAME_CHARS := 256
const MAX_MODEL_EFFORTS := 8
const MAX_MODEL_EFFORT_ITEMS := 64
const MAX_MODEL_EFFORT_CHARS := 32

func definition() -> Dictionary:
	return {}


func chat_url(config: Dictionary) -> String:
	var base_url := str(config.get("base_url", definition().get("base_url", ""))).trim_suffix("/")
	return base_url + "/chat/completions"


func models_url(config: Dictionary) -> String:
	var base_url := str(config.get("base_url", definition().get("base_url", ""))).trim_suffix("/")
	return base_url + "/models"


func request_headers(api_key: String) -> PackedStringArray:
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: text/event-stream",
		"Accept-Encoding: identity"
	])
	if not api_key.strip_edges().is_empty():
		headers.append("Authorization: Bearer " + api_key)
	return headers


func model_headers(api_key: String) -> PackedStringArray:
	var headers := PackedStringArray(["Accept: application/json"])
	if not api_key.strip_edges().is_empty():
		headers.append("Authorization: Bearer " + api_key)
	return headers


func apply_chat_options(body: Dictionary, effort: String) -> void:
	pass


func validate_config(config: Dictionary) -> String:
	return ""


func official_base_urls() -> PackedStringArray:
	# Opt-in release-owned fixed routes. Empty retains the existing endpoint policy.
	return PackedStringArray()


func supports_official_agent(config: Dictionary) -> bool:
	# Parameter support/discovery metadata alone never establishes Agent readiness.
	return false


func apply_serial_tool_options(body: Dictionary, config: Dictionary) -> void:
	# Optional provider-specific generation control, never tool authorization.
	# Unknown/custom/managed contracts do not inherit OpenAI-only wire fields.
	pass


func api_mode(config: Dictionary) -> String:
	return "chat_completions"


func prepare_messages(messages: Array, config: Dictionary) -> Array:
	return sanitize_messages(messages)


func allows_stop_finish_with_tool_calls() -> bool:
	return false


func normalize_models(response) -> Array[Dictionary]:
	var models: Array[Dictionary] = []
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("data")) != TYPE_ARRAY:
		return models
	var source_models: Array = response["data"]
	for item_index in range(mini(source_models.size(), MAX_DISCOVERY_ITEMS)):
		if models.size() >= MAX_DISCOVERED_MODELS:
			break
		var item = source_models[item_index]
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var model_id := str(item.get("id", "")).strip_edges()
		if model_id.is_empty() or model_id.length() > MAX_MODEL_ID_CHARS:
			continue
		models.append({
			"id": model_id,
			"name": str(item.get("name", model_id)).strip_edges().left(MAX_MODEL_NAME_CHARS),
			"context_window": int(item.get("context_window", 0)),
			"input_per_million": -1.0,
			"output_per_million": -1.0,
			"efforts": _normalize_efforts(item),
			"default_effort": _default_effort(item)
		})
		var modalities = item.get("input_modalities", item.get("architecture", {}).get("input_modalities", null) if typeof(item.get("architecture")) == TYPE_DICTIONARY else null)
		if typeof(modalities) == TYPE_ARRAY and not modalities.is_empty():
			models.back()["image_input"] = "image" in modalities
	models.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return models


func sanitize_messages(messages: Array) -> Array:
	var sanitized := messages.duplicate(true)
	for message in sanitized:
		if typeof(message) == TYPE_DICTIONARY:
			message.erase("_orca_responses")
			message.erase("_orca_anthropic")
			message.erase("reasoning_content")
			message.erase("reasoning")
			message.erase("reasoning_details")
	return sanitized


func _normalize_efforts(item: Dictionary) -> PackedStringArray:
	var normalized := PackedStringArray()
	var effort = item.get("effort", {})
	if typeof(effort) == TYPE_DICTIONARY and typeof(effort.get("supported_levels")) == TYPE_ARRAY:
		var levels: Array = effort["supported_levels"]
		for level_index in range(mini(levels.size(), MAX_MODEL_EFFORT_ITEMS)):
			if normalized.size() >= MAX_MODEL_EFFORTS:
				break
			var level = levels[level_index]
			var value := str(level).strip_edges()
			if not value.is_empty() and value.length() <= MAX_MODEL_EFFORT_CHARS and value not in normalized:
				normalized.append(value)
	return normalized


func _default_effort(item: Dictionary) -> String:
	var effort = item.get("effort", {})
	if typeof(effort) != TYPE_DICTIONARY:
		return ""
	var value := str(effort.get("default_level", "")).strip_edges()
	return value if value.length() <= MAX_MODEL_EFFORT_CHARS else ""
