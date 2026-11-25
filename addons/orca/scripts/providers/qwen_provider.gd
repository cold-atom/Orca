@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"

# Region selection is endpoint assistance, never authorization or capability.
const REGIONS := {
	"ap-southeast-1": "Singapore",
	"us-east-1": "US (Virginia)",
	"cn-beijing": "China (Beijing)",
	"cn-hongkong": "China (Hong Kong)",
	"eu-central-1": "Germany (Frankfurt)",
	"ap-northeast-1": "Japan (Tokyo)"
}
const LEGACY_HOSTS := {
	"ap-southeast-1": "dashscope-intl.aliyuncs.com",
	"cn-beijing": "dashscope.aliyuncs.com",
	"cn-hongkong": "cn-hongkong.dashscope.aliyuncs.com"
}
const HYBRID_FAMILIES := ["qwen-plus", "qwen-flash", "qwen3.5-plus", "qwen3.5-flash", "qwen3.6-plus", "qwen3.6-flash", "qwen3.7-plus", "qwen3.7-flash", "qwen3.7-max", "qwen3.8-flash", "qwen3.8-max", "qwen4-max"]
# Documented client-function Chat contracts, independently of thinking support.
# Do not infer support for arbitrary snapshots, fine-tunes, media or future IDs.
const AGENT_MODELS := ["qwen3-coder-plus", "qwen3-coder-flash", "qwen-plus", "qwen-plus-latest", "qwen-flash", "qwen-flash-latest", "qwen3-max", "qwen3.5-plus", "qwen3.5-flash", "qwen3.6-plus", "qwen3.6-flash", "qwen3.7-plus", "qwen3.7-flash", "qwen3.7-max", "qwen3.8-flash", "qwen3.8-max", "qwen4-max"]


func definition() -> Dictionary:
	return {
		"id": "qwen", "name": "Qwen",
		"base_url": endpoint("ap-southeast-1", ""),
		"key_label": "Model Studio API Key",
		"key_url": "https://modelstudio.console.alibabacloud.com/ap-southeast-1/model/settings/api-key",
		"default_model": "qwen3-coder-plus",
		"description": "Qwen through Alibaba Cloud Model Studio",
		"custom_url": true, "model_discovery": true, "manual_model": true,
		"agent_tools": false # Nonofficial/unlisted fallback; fixed contracts are evaluated separately.
	}


func official_base_urls() -> PackedStringArray:
	var urls := PackedStringArray()
	for region in LEGACY_HOSTS: urls.append(endpoint(region, ""))
	return urls


func supports_official_agent(config: Dictionary) -> bool:
	return config.get("provider") == "qwen" and config.get("model") in AGENT_MODELS and validate_config(config).is_empty()


static func endpoint(region: String, workspace: String) -> String:
	if not REGIONS.has(region): return ""
	if workspace.is_empty():
		return "https://" + LEGACY_HOSTS[region] + "/compatible-mode/v1" if LEGACY_HOSTS.has(region) else ""
	var regex := RegEx.new()
	regex.compile("^[a-z0-9][a-z0-9-]{0,63}$")
	if regex.search(workspace) == null: return ""
	return "https://%s.%s.maas.aliyuncs.com/compatible-mode/v1" % [workspace, region]


static func endpoint_selection(url: String) -> Dictionary:
	for region in REGIONS:
		if url.trim_suffix("/") == endpoint(region, "") and not endpoint(region, "").is_empty():
			return {"region": region, "workspace": ""}
	var regex := RegEx.new()
	regex.compile("^https://([a-z0-9][a-z0-9-]{0,63})\\.([a-z0-9-]+)\\.maas\\.aliyuncs\\.com/compatible-mode/v1/?$")
	var found := regex.search(url)
	if found != null and REGIONS.has(found.get_string(2)):
		return {"region": found.get_string(2), "workspace": found.get_string(1)}
	return {}


static func efforts_for_model(model: String) -> PackedStringArray:
	# Preview/thinking-only and unknown models cannot inherit an Off switch.
	if "preview" in model or model == "qwen3.7-max-2026-05-17": return PackedStringArray()
	for family in HYBRID_FAMILIES:
		if model == family or model == family + "-latest":
			return PackedStringArray(["off", "on"])
	# Dated snapshots have hyphen-separated dates.
	for family in HYBRID_FAMILIES:
		var suffix := model.trim_prefix(family + "-")
		if model.begins_with(family + "-") and suffix.length() == 10 and suffix[4] == "-" and suffix[7] == "-" and suffix.replace("-", "").length() == 8 and suffix.replace("-", "").is_valid_int():
			if family == "qwen-plus" and suffix < "2025-04-28": return PackedStringArray()
			if family == "qwen-flash" and suffix < "2025-07-28": return PackedStringArray()
			return PackedStringArray(["off", "on"])
	return PackedStringArray()


func validate_config(config: Dictionary) -> String:
	if config.get("api_mode", "chat_completions") != "chat_completions" or config.get("continuation_style", "standard") != "standard": return "Qwen requires Chat Completions with standard continuation."
	var key := str(config.get("api_key", ""))
	if key.length() > 8192 or key.contains("\r") or key.contains("\n"): return "Invalid Model Studio API key."
	var effort := str(config.get("reasoning_effort", "default"))
	if effort != "default" and effort not in efforts_for_model(str(config.get("model", ""))):
		return "The selected Qwen model does not have a supported thinking setting. Select Provider default."
	return ""


func apply_chat_options(body: Dictionary, effort: String) -> void:
	body["max_tokens"] = 8192
	if not efforts_for_model(str(body.get("model", ""))).is_empty():
		if effort in ["on", "off"]: body["enable_thinking"] = effort == "on"
		# Bound reasoning under both explicit and model-default thinking.
		if effort != "off": body["thinking_budget"] = 4096


func apply_serial_tool_options(body: Dictionary, config: Dictionary) -> void:
	if body.has("tools"): body["parallel_tool_calls"] = false


func sanitize_messages(messages: Array) -> Array:
	# Model Studio accepts a single leading system message. Keep the canonical
	# controller history and exact tool-call/result order intact.
	var sanitized := super.sanitize_messages(messages)
	var parts := PackedStringArray()
	var conversation: Array = []
	for message in sanitized:
		if typeof(message) == TYPE_DICTIONARY and message.get("role") == "system" and typeof(message.get("content")) == TYPE_STRING:
			parts.append(message["content"])
		else:
			conversation.append(message)
	if not parts.is_empty(): conversation.push_front({"role": "system", "content": "\n\n".join(parts)})
	return conversation


func normalize_models(response) -> Array[Dictionary]:
	if typeof(response) != TYPE_DICTIONARY or typeof(response.get("data")) != TYPE_ARRAY: return []
	var source: Array = []
	for item in response["data"].slice(0, MAX_DISCOVERY_ITEMS):
		if typeof(item) != TYPE_DICTIONARY or typeof(item.get("id")) != TYPE_STRING or item["id"].length() > MAX_MODEL_ID_CHARS: continue
		var context = item.get("context_window", 0)
		if typeof(context) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(context)) or context < 0 or context > 64000000: context = 0
		var normalized := {"id": item["id"], "name": item.get("name", item["id"]) if typeof(item.get("name", item["id"])) == TYPE_STRING else item["id"], "context_window": context}
		if typeof(item.get("input_modalities")) == TYPE_ARRAY and item["input_modalities"].size() <= 16: normalized["input_modalities"] = item["input_modalities"]
		source.append(normalized)
	var models: Array[Dictionary] = []
	for model in super.normalize_models({"data": source}):
		var id: String = model["id"]
		if not id.begins_with("qwen") or ["embed", "audio", "omni", "realtime", "tts", "image", "rerank"].any(func(term): return term in id): continue
		model["efforts"] = efforts_for_model(id)
		models.append(model)
	return models
