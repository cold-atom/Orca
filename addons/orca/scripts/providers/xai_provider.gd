@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"

const INCOMPATIBLE_MODEL_TERMS := ["image", "video", "voice", "audio", "tts", "transcribe", "embedding"]


func definition() -> Dictionary:
	return {
		"id": "xai",
		"name": "xAI",
		"base_url": "https://api.x.ai/v1",
		"key_label": "xAI API Key",
		"key_url": "https://console.x.ai/team/default/api-keys",
		"default_model": "grok-4",
		"description": "Grok chat and reasoning models"
	}


func apply_chat_options(body: Dictionary, effort: String) -> void:
	if not effort.is_empty() and effort != "default":
		body["reasoning_effort"] = effort


func sanitize_messages(messages: Array) -> Array:
	var sanitized := messages.duplicate(true)
	for message in sanitized:
		if typeof(message) == TYPE_DICTIONARY:
			message.erase("reasoning")
			message.erase("reasoning_details")
	return sanitized


func normalize_models(response) -> Array[Dictionary]:
	var models := super.normalize_models(response)
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("data")) != TYPE_ARRAY:
		return models
	var items_by_id := {}
	for item in response["data"]:
		if typeof(item) == TYPE_DICTIONARY:
			items_by_id[str(item.get("id", ""))] = item
	var compatible: Array[Dictionary] = []
	for model in models:
		var model_id := str(model["id"])
		var normalized_id := model_id.to_lower()
		var item: Dictionary = items_by_id.get(model_id, {})
		if INCOMPATIBLE_MODEL_TERMS.any(func(term: String) -> bool: return term in normalized_id):
			continue
		if item.has("image_price") and item.get("image_price") != null:
			continue
		model["context_window"] = int(item.get("context_length", model["context_window"]))
		model["input_per_million"] = _price_per_million(item.get("prompt_text_token_price"))
		model["output_per_million"] = _price_per_million(item.get("completion_text_token_price"))
		var capabilities = item.get("capabilities", {})
		if typeof(capabilities) == TYPE_DICTIONARY and typeof(capabilities.get("reasoning_effort")) == TYPE_ARRAY:
			model["efforts"] = PackedStringArray(capabilities["reasoning_effort"])
			model["default_effort"] = str(capabilities.get("default_reasoning_effort", ""))
		compatible.append(model)
	return compatible


func _price_per_million(value) -> float:
	return float(value) / 10000.0 if typeof(value) in [TYPE_INT, TYPE_FLOAT] else -1.0
