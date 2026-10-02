@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"

const THINKING_MAX_TOKENS := 8192
const NON_THINKING_MAX_TOKENS := 8192


func definition() -> Dictionary:
	return {
		"id": "deepseek",
		"name": "DeepSeek",
		"base_url": "https://api.deepseek.com",
		"key_label": "DeepSeek API Key",
		"key_url": "https://platform.deepseek.com/api_keys",
		"default_model": "deepseek-flash",
		"description": "DeepSeek chat and reasoning models"
	}


func apply_chat_options(body: Dictionary, effort: String) -> void:
	if effort == "off":
		body["thinking"] = {"type": "disabled"}
		body["max_tokens"] = NON_THINKING_MAX_TOKENS
	elif not effort.is_empty() and effort != "default":
		body["thinking"] = {"type": "enabled"}
		body["reasoning_effort"] = effort
		body["max_tokens"] = THINKING_MAX_TOKENS
	else:
		# DeepSeek defaults to high-effort thinking and a much larger output budget.
		body["max_tokens"] = THINKING_MAX_TOKENS


func sanitize_messages(messages: Array) -> Array:
	var sanitized := messages.duplicate(true)
	for message in sanitized:
		if typeof(message) == TYPE_DICTIONARY:
			message.erase("reasoning")
			message.erase("reasoning_details")
	return sanitized


func normalize_models(response) -> Array[Dictionary]:
	var models := super.normalize_models(response)
	for model in models:
		if not model["efforts"].is_empty():
			model["efforts"].insert(0, "off")
	return models
