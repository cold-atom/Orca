@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"


func definition() -> Dictionary:
	return {
		"id": "azure", "name": "Microsoft Foundry / Azure",
		"base_url": "https://YOUR-RESOURCE.openai.azure.com/openai/v1",
		"key_label": "Azure API Key", "key_url": "https://ai.azure.com/",
		"default_model": "", "description": "Azure deployment names with Responses or Chat Completions",
		"custom_url": true, "manual_model": true, "model_discovery": false,
		"default_api_mode": "responses"
	}


func api_mode(config: Dictionary) -> String:
	return str(config.get("api_mode", "responses"))


func chat_url(config: Dictionary) -> String:
	return str(config.get("base_url", "")).trim_suffix("/") + ("/responses" if api_mode(config) == "responses" else "/chat/completions")


func apply_chat_options(body: Dictionary, effort: String) -> void:
	if not effort.is_empty() and effort != "default":
		body["reasoning_effort"] = effort


func apply_serial_tool_options(body: Dictionary, config: Dictionary) -> void:
	if body.has("tools") and config.get("continuation_style", "standard") == "standard":
		body["parallel_tool_calls"] = false


func prepare_messages(messages: Array, config: Dictionary) -> Array:
	var prepared := super.prepare_messages(messages, config)
	if config.get("continuation_style", "standard") == "deepseek":
		for index in range(prepared.size()):
			if typeof(prepared[index]) == TYPE_DICTIONARY and typeof(messages[index]) == TYPE_DICTIONARY and messages[index].get("role") == "assistant" and typeof(messages[index].get("reasoning_content")) == TYPE_STRING:
				prepared[index]["reasoning_content"] = messages[index]["reasoning_content"]
	return prepared
