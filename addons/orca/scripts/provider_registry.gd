@tool
extends RefCounted

const PROVIDER_IDS := ["openai", "gemini", "xai", "deepseek", "openrouter", "custom"]


static func get_provider(provider_id: String):
	match provider_id:
		"openai":
			return preload("res://addons/orca/scripts/providers/openai_provider.gd").new()
		"gemini":
			return preload("res://addons/orca/scripts/providers/gemini_provider.gd").new()
		"xai":
			return preload("res://addons/orca/scripts/providers/xai_provider.gd").new()
		"deepseek":
			return preload("res://addons/orca/scripts/providers/deepseek_provider.gd").new()
		"openrouter":
			return preload("res://addons/orca/scripts/providers/openrouter_provider.gd").new()
		_:
			return preload("res://addons/orca/scripts/providers/custom_openai_provider.gd").new()


static func definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for provider_id in PROVIDER_IDS:
		result.append(get_provider(provider_id).definition())
	return result


static func infer_provider(api_url: String) -> String:
	var normalized := api_url.strip_edges().to_lower().trim_suffix("/")
	if normalized in ["https://api.openai.com", "https://api.openai.com/v1"]:
		return "openai"
	if normalized in ["https://generativelanguage.googleapis.com/v1beta/openai"]:
		return "gemini"
	if normalized in ["https://api.x.ai", "https://api.x.ai/v1"]:
		return "xai"
	if normalized in ["https://api.deepseek.com", "https://api.deepseek.com/v1"]:
		return "deepseek"
	if normalized in ["https://openrouter.ai", "https://openrouter.ai/api/v1"]:
		return "openrouter"
	return "custom"
