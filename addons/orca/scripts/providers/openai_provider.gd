@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"

const REASONING_EFFORTS := {
	"o1": ["low", "medium", "high"],
	"o3": ["low", "medium", "high"],
	"o3-mini": ["low", "medium", "high"],
	"o4-mini": ["low", "medium", "high"],
	"gpt-5": ["minimal", "low", "medium", "high"],
	"gpt-5-mini": ["minimal", "low", "medium", "high"],
	"gpt-5-nano": ["minimal", "low", "medium", "high"]
}
const CHAT_MODEL_PREFIXES := ["gpt-3.5-turbo", "gpt-4", "gpt-4o", "gpt-4.1", "gpt-5", "o1", "o3", "o4"]
const INCOMPATIBLE_MODEL_TERMS := ["audio", "embedding", "tts", "image", "moderation", "realtime", "transcribe", "search", "instruct", "computer-use", "codex"]


func definition() -> Dictionary:
	return {
		"id": "openai",
		"name": "OpenAI",
		"base_url": "https://api.openai.com/v1",
		"key_label": "OpenAI API Key",
		"key_url": "https://platform.openai.com/api-keys",
		"default_model": "gpt-4.1-mini",
		"description": "OpenAI GPT models"
	}


func apply_chat_options(body: Dictionary, effort: String) -> void:
	if not effort.is_empty() and effort != "default":
		body["reasoning_effort"] = effort


func normalize_models(response) -> Array[Dictionary]:
	var models := super.normalize_models(response)
	var chat_models: Array[Dictionary] = []
	for model in models:
		var model_id := str(model["id"]).to_lower()
		if not CHAT_MODEL_PREFIXES.any(func(prefix: String) -> bool: return model_id == prefix or model_id.begins_with(prefix + "-")):
			continue
		if INCOMPATIBLE_MODEL_TERMS.any(func(term: String) -> bool: return term in model_id):
			continue
		var reasoning_family := _reasoning_family(model_id)
		if not reasoning_family.is_empty():
			model["efforts"] = PackedStringArray(REASONING_EFFORTS[reasoning_family])
		chat_models.append(model)
	return chat_models


func _reasoning_family(model_id: String) -> String:
	var families := REASONING_EFFORTS.keys()
	families.sort_custom(func(a, b) -> bool: return str(a).length() > str(b).length())
	for family in families:
		if model_id == family or model_id.begins_with(str(family) + "-"):
			return str(family)
	return ""
