@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"


func definition() -> Dictionary:
	return {
		"id": "openrouter",
		"name": "OpenRouter",
		"base_url": "https://openrouter.ai/api/v1",
		"key_label": "OpenRouter API Key",
		"key_url": "https://openrouter.ai/settings/keys",
		"default_model": "openrouter/auto",
		"description": "Many providers through one API"
	}


func request_headers(api_key: String) -> PackedStringArray:
	var headers := super.request_headers(api_key)
	headers.append("HTTP-Referer: https://github.com/")
	headers.append("X-Title: Orca")
	return headers


func apply_chat_options(body: Dictionary, effort: String) -> void:
	if effort == "off":
		body["reasoning"] = {"enabled": false}
	elif not effort.is_empty() and effort != "default":
		body["reasoning"] = {"effort": effort}


func sanitize_messages(messages: Array) -> Array:
	return messages.duplicate(true)


func normalize_models(response) -> Array[Dictionary]:
	var models := super.normalize_models(response)
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("data")) != TYPE_ARRAY:
		return models
	var by_id := {}
	for model in models:
		by_id[model["id"]] = model
	for item in response["data"]:
		if typeof(item) != TYPE_DICTIONARY or not by_id.has(str(item.get("id", ""))):
			continue
		var model: Dictionary = by_id[str(item["id"])]
		var pricing = item.get("pricing", {})
		if typeof(pricing) == TYPE_DICTIONARY:
			model["input_per_million"] = _per_token_to_million(pricing.get("prompt"))
			model["output_per_million"] = _per_token_to_million(pricing.get("completion"))
		model["context_window"] = int(item.get("context_length", model["context_window"]))
		var reasoning = item.get("reasoning", {})
		if typeof(reasoning) == TYPE_DICTIONARY and typeof(reasoning.get("supported_efforts")) == TYPE_ARRAY:
			model["efforts"] = PackedStringArray(reasoning["supported_efforts"])
			if not bool(reasoning.get("mandatory", false)):
				model["efforts"].append("off")
			model["default_effort"] = str(reasoning.get("default_effort", ""))
	return models


func _per_token_to_million(value) -> float:
	var rendered := str(value)
	return rendered.to_float() * 1000000.0 if rendered.is_valid_float() else -1.0
