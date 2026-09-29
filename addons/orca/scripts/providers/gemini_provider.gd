@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"

const INCOMPATIBLE_MODEL_TERMS := ["embedding", "imagen", "image", "veo", "video", "audio", "live", "tts", "aqa"]


func definition() -> Dictionary:
	return {
		"id": "gemini",
		"name": "Google Gemini",
		"base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
		"key_label": "Gemini API Key",
		"key_url": "https://aistudio.google.com/apikey",
		"default_model": "gemini-2.5-flash",
		"description": "Gemini models through Google's OpenAI-compatible API"
	}


func models_url(_config: Dictionary) -> String:
	return "https://generativelanguage.googleapis.com/v1beta/models"


func model_headers(api_key: String) -> PackedStringArray:
	return PackedStringArray(["x-goog-api-key: " + api_key, "Accept: application/json"])


func apply_chat_options(body: Dictionary, effort: String) -> void:
	if not effort.is_empty() and effort != "default":
		body["reasoning_effort"] = effort


func normalize_models(response) -> Array[Dictionary]:
	var models: Array[Dictionary] = []
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("models")) != TYPE_ARRAY:
		return models
	for item in response["models"]:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var methods = item.get("supportedGenerationMethods", [])
		if typeof(methods) != TYPE_ARRAY or "generateContent" not in methods:
			continue
		var model_id := str(item.get("name", "")).trim_prefix("models/")
		var normalized_id := model_id.to_lower()
		if model_id.is_empty() or INCOMPATIBLE_MODEL_TERMS.any(func(term: String) -> bool: return term in normalized_id):
			continue
		var efforts := PackedStringArray()
		if normalized_id.begins_with("gemini-2.5-") or normalized_id.begins_with("gemini-3"):
			efforts = PackedStringArray(["minimal", "low", "medium", "high"])
		models.append({
			"id": model_id,
			"name": str(item.get("displayName", model_id)),
			"context_window": int(item.get("inputTokenLimit", 0)),
			"input_per_million": -1.0,
			"output_per_million": -1.0,
			"efforts": efforts,
			"default_effort": ""
		})
	models.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return models
