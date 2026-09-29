@tool
extends RefCounted


func definition() -> Dictionary:
	return {}


func chat_url(config: Dictionary) -> String:
	var base_url := str(config.get("base_url", definition().get("base_url", ""))).trim_suffix("/")
	return base_url + "/chat/completions"


func models_url(config: Dictionary) -> String:
	var base_url := str(config.get("base_url", definition().get("base_url", ""))).trim_suffix("/")
	return base_url + "/models"


func request_headers(api_key: String) -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"Accept: text/event-stream",
		"Accept-Encoding: identity",
		"Authorization: Bearer " + api_key
	])


func model_headers(api_key: String) -> PackedStringArray:
	return PackedStringArray(["Authorization: Bearer " + api_key, "Accept: application/json"])


func apply_chat_options(body: Dictionary, effort: String) -> void:
	pass


func normalize_models(response) -> Array[Dictionary]:
	var models: Array[Dictionary] = []
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("data")) != TYPE_ARRAY:
		return models
	for item in response["data"]:
		if typeof(item) != TYPE_DICTIONARY or str(item.get("id", "")).is_empty():
			continue
		models.append({
			"id": str(item["id"]),
			"name": str(item.get("name", item["id"])),
			"context_window": int(item.get("context_window", 0)),
			"input_per_million": -1.0,
			"output_per_million": -1.0,
			"efforts": _normalize_efforts(item),
			"default_effort": _default_effort(item)
		})
	models.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return models


func sanitize_messages(messages: Array) -> Array:
	var sanitized := messages.duplicate(true)
	for message in sanitized:
		if typeof(message) == TYPE_DICTIONARY:
			message.erase("reasoning_content")
			message.erase("reasoning")
			message.erase("reasoning_details")
	return sanitized


func _normalize_efforts(item: Dictionary) -> PackedStringArray:
	var effort = item.get("effort", {})
	if typeof(effort) == TYPE_DICTIONARY and typeof(effort.get("supported_levels")) == TYPE_ARRAY:
		return PackedStringArray(effort["supported_levels"])
	return PackedStringArray()


func _default_effort(item: Dictionary) -> String:
	var effort = item.get("effort", {})
	return str(effort.get("default_level", "")) if typeof(effort) == TYPE_DICTIONARY else ""
