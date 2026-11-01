@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"

const ORIGIN := "https://cloud.aiorca.dev"
const BASE_URL := ORIGIN + "/v1"


func definition() -> Dictionary:
	return {"id": "orca_cloud", "name": "Orca Cloud", "base_url": BASE_URL, "default_model": "", "managed_auth": true, "agent_tools": false, "description": "Models provided by your Orca account", "model_discovery": true}


func apply_chat_options(body: Dictionary, effort: String) -> void:
	if not effort.is_empty() and effort != "default":
		body["reasoning_effort"] = effort


func prepare_messages(messages: Array, config: Dictionary) -> Array:
	var result := super.prepare_messages(messages, config)
	if config.get("continuation_style") == "reasoning_content":
		for index in result.size():
			if typeof(messages[index]) == TYPE_DICTIONARY and messages[index].get("role") == "assistant" and typeof(messages[index].get("reasoning_content")) == TYPE_STRING:
				result[index]["reasoning_content"] = messages[index]["reasoning_content"]
	return result


func normalize_models(response) -> Array[Dictionary]:
	return normalize_catalog(response)


static func normalize_catalog(response) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("data")) != TYPE_ARRAY or response["data"].size() > 10:
		return result
	var seen := {}
	for raw in response["data"]:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("orca")) != TYPE_DICTIONARY or typeof(raw.get("effort")) != TYPE_DICTIONARY:
			return []
		var id = raw.get("id")
		var cloud: Dictionary = raw["orca"]
		var access = cloud.get("access", {})
		var agent = cloud.get("agent", {})
		var budget = cloud.get("context_budget", {})
		var budget_valid: bool = typeof(budget) == TYPE_DICTIONARY and budget.get("version") == "utf8-conservative-v2" and budget.get("text_bytes_per_token") == 3 and budget.get("message_overhead") == 32 and budget.get("tool_overhead") == 64 and typeof(budget.get("opaque_reasoning_bytes")) == TYPE_BOOL and typeof(budget.get("image_tokens")) in [TYPE_INT, TYPE_FLOAT] and int(budget.get("image_tokens", 0)) >= 4096 and int(budget.get("image_tokens", 0)) <= 2000000
		var agent_ready: bool = budget_valid and typeof(agent) == TYPE_DICTIONARY and agent.get("status") == "operator_verified" and agent.get("capability_version") == cloud.get("capability_version") and agent.get("tool_contract") == "orca-tools-v1" and cloud.get("tools") == true
		if typeof(id) != TYPE_STRING or id.is_empty() or id.length() > 64 or id != id.strip_edges() or seen.has(id) or cloud.get("protocol") != "chat_completions" or cloud.get("continuation_style") not in ["standard", "reasoning_content"] or typeof(access) != TYPE_DICTIONARY:
			return []
		var context = raw.get("context_window", 0)
		var output = raw.get("max_output_tokens", 0)
		if typeof(context) not in [TYPE_INT, TYPE_FLOAT] or typeof(output) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(context)) or not is_finite(float(output)) or float(context) != floorf(float(context)) or float(output) != floorf(float(output)) or int(context) <= 0 or int(context) > 1048576 or int(output) <= 0 or int(output) > 32768 or typeof(cloud.get("tools")) != TYPE_BOOL or str(cloud.get("capability_version", "")).is_empty():
			return []
		seen[id] = true
		var efforts: Array[String] = []
		var raw_efforts = raw["effort"].get("supported_levels", [])
		if typeof(raw_efforts) != TYPE_ARRAY or raw_efforts.size() > 16:
			return []
		for effort in raw_efforts:
			if typeof(effort) == TYPE_STRING and effort in ["default", "none", "minimal", "low", "medium", "high", "xhigh", "max"]:
				efforts.append(effort)
		var pricing = raw.get("pricing", {})
		var rates := {}
		if typeof(pricing) == TYPE_DICTIONARY and pricing.get("currency") == "USD" and int(pricing.get("units_per_currency", 0)) == 1000000:
			for field in ["input_units_per_million", "output_units_per_million", "cached_units_per_million", "cache_write_units_per_million"]:
				var rate = pricing.get(field)
				if typeof(rate) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(rate)) and float(rate) == floorf(float(rate)) and float(rate) >= 0 and float(rate) <= 9007199254740991:
					rates[field] = int(rate)
		result.append({"id": id, "name": str(raw.get("name", id)).left(128), "context_window": int(context), "max_output_tokens": int(output), "efforts": efforts, "default_effort": str(raw["effort"].get("default_level", "default")), "tools": cloud.get("tools") == true, "project_code_navigation": typeof(cloud.get("project_code_navigation")) == TYPE_BOOL and cloud.get("project_code_navigation") == true, "agent_ready": agent_ready, "verified_capability": str(agent.get("capability_version", "")) if agent_ready else "", "context_budget": budget.duplicate(true) if budget_valid else {}, "recommendation": str(cloud.get("recommendation", "")), "image_input": typeof(raw.get("input_modalities")) == TYPE_ARRAY and "image" in raw["input_modalities"], "continuation_style": cloud["continuation_style"], "capability_version": str(cloud.get("capability_version", "")).left(64), "availability": str(cloud.get("availability", "")).left(32), "allowed": access.get("allowed") == true, "pricing": rates, "input_per_million": float(rates.get("input_units_per_million", -1000000)) / 1000000.0, "output_per_million": float(rates.get("output_units_per_million", -1000000)) / 1000000.0})
	return result
