@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"

const API_VERSION := "2026-10-21"
const ADAPTIVE_MODELS := ["claude-sonnet-4-6", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-5", "claude-opus-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
const MANUAL_MODELS := ["claude-sonnet-4-5", "claude-opus-4-5", "claude-haiku-4-5"]
# Exact native client-tool contracts; family()/discovery are not authorization.
const AGENT_MODELS := ["claude-sonnet-4-6", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-5", "claude-opus-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-sonnet-4-5", "claude-sonnet-4-5-20250929", "claude-opus-4-5", "claude-opus-4-5-20251101", "claude-haiku-4-5", "claude-haiku-4-5-20251001"]


func definition() -> Dictionary:
	return {"id": "anthropic", "name": "Anthropic (Claude)", "base_url": "https://api.anthropic.com/v1", "key_label": "Anthropic API Key", "key_url": "https://platform.claude.com/settings/keys", "default_model": "claude-sonnet-4-6", "description": "Claude through the native Anthropic Messages API", "default_api_mode": "anthropic_messages", "model_discovery": true, "manual_model": true, "agent_tools": false}


func api_mode(config: Dictionary) -> String:
	return "anthropic_messages"


func official_base_urls() -> PackedStringArray:
	return PackedStringArray([definition()["base_url"]])


func supports_official_agent(config: Dictionary) -> bool:
	return config.get("provider") == "anthropic" and config.get("model") in AGENT_MODELS and validate_config(config).is_empty()


func chat_url(config: Dictionary) -> String:
	return str(config.get("base_url", definition()["base_url"])).trim_suffix("/") + "/messages"


func request_headers(api_key: String) -> PackedStringArray:
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: text/event-stream", "Accept-Encoding: identity", "anthropic-version: " + API_VERSION])
	if not api_key.is_empty(): headers.append("x-api-key: " + api_key)
	return headers


func model_headers(api_key: String) -> PackedStringArray:
	var headers := PackedStringArray(["Accept: application/json", "anthropic-version: " + API_VERSION])
	if not api_key.is_empty(): headers.append("x-api-key: " + api_key)
	return headers


static func family(model: String) -> String:
	for candidate in ADAPTIVE_MODELS + MANUAL_MODELS:
		if model == candidate: return candidate
		if model.begins_with(candidate + "-") and model.trim_prefix(candidate + "-").length() == 8 and model.trim_prefix(candidate + "-").is_valid_int(): return candidate
	return ""


static func efforts_for_model(model: String) -> PackedStringArray:
	var model_family := family(model)
	if model_family in ADAPTIVE_MODELS:
		var efforts := PackedStringArray(["low", "medium", "high"])
		if model_family not in ["claude-sonnet-5-5", "claude-opus-5-5"]: efforts.insert(0, "off")
		return efforts
	if model_family in MANUAL_MODELS: return PackedStringArray(["off", "on"])
	return PackedStringArray()


func validate_config(config: Dictionary) -> String:
	if config.get("api_mode", "anthropic_messages") != "anthropic_messages" or config.get("continuation_style", "standard") != "standard": return "Anthropic requires the native Messages API and its own continuation format."
	var key := str(config.get("api_key", ""))
	if key.length() > 8192 or key.contains("\r") or key.contains("\n"): return "Invalid Anthropic API key."
	var effort := str(config.get("reasoning_effort", "default"))
	if effort != "default" and effort not in efforts_for_model(str(config.get("model", ""))): return "The selected Claude model does not have a supported thinking setting. Select Provider default."
	return ""


func apply_chat_options(body: Dictionary, effort: String) -> void:
	var model_family := family(str(body.get("model", "")))
	if effort == "off":
		body["thinking"] = {"type": "disabled"}
	elif effort in ["low", "medium", "high"] and model_family in ADAPTIVE_MODELS:
		body["thinking"] = {"type": "adaptive", "display": "omitted"}
		body["output_config"] = {"effort": effort}
	elif effort == "on" and model_family in MANUAL_MODELS:
		body["thinking"] = {"type": "enabled", "budget_tokens": 4096, "display": "omitted"}


func normalize_models(response) -> Array[Dictionary]:
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("data")) != TYPE_ARRAY: return []
	var source: Array = []
	var by_id := {}
	for item in response["data"].slice(0, MAX_DISCOVERY_ITEMS):
		if typeof(item) != TYPE_DICTIONARY or item.get("type") != "model" or typeof(item.get("id")) != TYPE_STRING or not item["id"].begins_with("claude-") or item.get("lifecycle") == "retired": continue
		var context = item.get("max_input_tokens", 0)
		if typeof(context) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(context)) or context < 0 or context > 64000000: context = 0
		source.append({"id": item["id"], "name": item.get("display_name", item["id"]), "context_window": context})
		by_id[item["id"]] = item
	var models := super.normalize_models({"data": source})
	for model in models:
		model["efforts"] = efforts_for_model(model["id"])
		var caps = by_id[model["id"]].get("capabilities", {})
		if typeof(caps) == TYPE_DICTIONARY and typeof(caps.get("image_input")) == TYPE_DICTIONARY and typeof(caps["image_input"].get("supported")) == TYPE_BOOL:
			model["image_input"] = caps["image_input"]["supported"]
	return models
