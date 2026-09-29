@tool
extends RefCounted

const MODELS := {
	"openai/gpt-4o": {"context_window": 128000, "input_per_million": 2.5, "output_per_million": 10.0, "cached_input_per_million": 1.25},
	"openai/gpt-4o-2024-05-13": {"context_window": 128000, "input_per_million": 5.0, "output_per_million": 15.0, "cached_input_per_million": 5.0},
	"openai/gpt-4o-2024-08-06": {"context_window": 128000, "input_per_million": 2.5, "output_per_million": 10.0, "cached_input_per_million": 1.25},
	"openai/gpt-4o-2024-11-20": {"context_window": 128000, "input_per_million": 2.5, "output_per_million": 10.0, "cached_input_per_million": 1.25},
	"openai/gpt-4o-mini": {"context_window": 128000, "input_per_million": 0.15, "output_per_million": 0.6, "cached_input_per_million": 0.075},
	"openai/gpt-4o-mini-2024-07-18": {"context_window": 128000, "input_per_million": 0.15, "output_per_million": 0.6, "cached_input_per_million": 0.075},
	"openai/gpt-4.1": {"context_window": 1047576, "input_per_million": 2.0, "output_per_million": 8.0, "cached_input_per_million": 0.5},
	"openai/gpt-4.1-mini": {"context_window": 1047576, "input_per_million": 0.4, "output_per_million": 1.6, "cached_input_per_million": 0.1},
	"openai/gpt-4.1-nano": {"context_window": 1047576, "input_per_million": 0.1, "output_per_million": 0.4, "cached_input_per_million": 0.025},
	"deepseek/deepseek-chat": {"context_window": 64000, "input_per_million": 0.27, "output_per_million": 1.1, "cached_input_per_million": 0.07}
}

static var _runtime_metadata: Dictionary = {}


static func resolve(model: String, api_url: String = "", fallback_model: String = "") -> Dictionary:
	var provider := infer_provider(api_url, model)
	if provider.is_empty():
		return {"model": model, "provider": provider, "source": "unavailable"}
	var candidates := _metadata_candidates(provider, model, fallback_model)
	var metadata: Dictionary = {}
	for key in candidates:
		if MODELS.has(key):
			metadata = MODELS[key].duplicate(true)
			metadata["source"] = "Orca fallback catalog"
			break
	for key in candidates:
		if _runtime_metadata.has(key):
			var runtime: Dictionary = _runtime_metadata[key]
			for field in runtime:
				metadata[field] = runtime[field]
			break
	if metadata.is_empty():
		metadata["source"] = "unavailable"
	return _with_identity(metadata, model, provider)


static func set_runtime_metadata(provider: String, model: String, metadata: Dictionary) -> void:
	if metadata.is_empty():
		return
	_runtime_metadata[_catalog_key(provider, model)] = metadata.duplicate(true)


static func remove_runtime_metadata(provider: String, model: String) -> void:
	_runtime_metadata.erase(_catalog_key(provider, model))


static func metadata_from_catalog(catalog, provider: String, model: String) -> Dictionary:
	if typeof(catalog) != TYPE_DICTIONARY:
		return {}
	var provider_data = catalog.get(provider, {})
	if typeof(provider_data) != TYPE_DICTIONARY:
		return {}
	var models = provider_data.get("models", {})
	if typeof(models) != TYPE_DICTIONARY:
		return {}
	var model_data = models.get(model, {})
	if (typeof(model_data) != TYPE_DICTIONARY or model_data.is_empty()) and model.contains("/"):
		model_data = models.get(model.get_slice("/", 1), {})
	if typeof(model_data) != TYPE_DICTIONARY or model_data.is_empty():
		return {}
	var metadata := {"source": "models.dev"}
	var limits = model_data.get("limit", {})
	if typeof(limits) == TYPE_DICTIONARY and int(limits.get("context", 0)) > 0:
		metadata["context_window"] = int(limits["context"])
	var cost = model_data.get("cost", {})
	if typeof(cost) == TYPE_DICTIONARY:
		if _is_number(cost.get("input")) and _is_number(cost.get("output")):
			metadata["input_per_million"] = float(cost["input"])
			metadata["output_per_million"] = float(cost["output"])
		if _is_number(cost.get("cache_read")):
			metadata["cached_input_per_million"] = float(cost["cache_read"])
		if _is_number(cost.get("cache_write")):
			metadata["cache_write_per_million"] = float(cost["cache_write"])
		var pricing_tiers: Array[Dictionary] = []
		var raw_tiers = cost.get("tiers", [])
		if typeof(raw_tiers) == TYPE_ARRAY:
			for raw_tier in raw_tiers:
				var normalized_tier := _normalize_tier(raw_tier)
				if not normalized_tier.is_empty():
					pricing_tiers.append(normalized_tier)
		if not pricing_tiers.is_empty():
			pricing_tiers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["context_threshold"]) < int(b["context_threshold"]))
			metadata["pricing_tiers"] = pricing_tiers
	return metadata if metadata.size() > 1 else {}


static func infer_provider(api_url: String, model: String = "") -> String:
	var normalized_url := api_url.strip_edges().to_lower()
	var authority := normalized_url.get_slice("://", 1) if "://" in normalized_url else normalized_url
	var host := authority.get_slice("/", 0).get_slice(":", 0)
	if host == "openrouter.ai" or host.ends_with(".openrouter.ai"):
		return "openrouter"
	if host == "api.openai.com":
		return "openai"
	if host == "api.deepseek.com":
		return "deepseek"
	if host == "api.groq.com":
		return "groq"
	if host == "api.together.xyz":
		return "togetherai"
	if host == "api.mistral.ai":
		return "mistral"
	if host == "generativelanguage.googleapis.com":
		return "google"
	if host == "api.x.ai":
		return "xai"
	return ""


static func calculate_cost(usage: Dictionary, metadata: Dictionary) -> float:
	if not metadata.has("input_per_million") or not metadata.has("output_per_million"):
		return -1.0
	var input_tokens := maxi(0, int(usage.get("input_tokens", 0)))
	var output_tokens := maxi(0, int(usage.get("output_tokens", 0)))
	var cached_tokens := clampi(int(usage.get("cached_tokens", 0)), 0, input_tokens)
	var cache_write_tokens := clampi(int(usage.get("cache_write_tokens", 0)), 0, input_tokens - cached_tokens)
	var regular_input_tokens := maxi(0, int(usage.get("regular_input_tokens", input_tokens - cached_tokens - cache_write_tokens)))
	var rates := _rates_for_context(metadata, input_tokens)
	var cached_rate := float(rates.get("cached_input_per_million", rates["input_per_million"]))
	var cache_write_rate := float(rates.get("cache_write_per_million", rates["input_per_million"]))
	return (
		regular_input_tokens * float(rates["input_per_million"])
		+ cached_tokens * cached_rate
		+ cache_write_tokens * cache_write_rate
		+ output_tokens * float(rates["output_per_million"])
	) / 1000000.0


static func _rates_for_context(metadata: Dictionary, input_tokens: int) -> Dictionary:
	var rates := metadata.duplicate(true)
	var tiers = metadata.get("pricing_tiers", [])
	if typeof(tiers) == TYPE_ARRAY:
		for tier in tiers:
			if typeof(tier) == TYPE_DICTIONARY and input_tokens > int(tier.get("context_threshold", 0)):
				for key in ["input_per_million", "output_per_million", "cached_input_per_million", "cache_write_per_million"]:
					if tier.has(key):
						rates[key] = tier[key]
	return rates


static func _normalize_tier(raw_tier) -> Dictionary:
	if typeof(raw_tier) != TYPE_DICTIONARY:
		return {}
	var threshold = raw_tier.get("tier", {})
	if typeof(threshold) != TYPE_DICTIONARY or threshold.get("type") != "context" or int(threshold.get("size", 0)) <= 0:
		return {}
	if not _is_number(raw_tier.get("input")) or not _is_number(raw_tier.get("output")):
		return {}
	var tier := {
		"context_threshold": int(threshold["size"]),
		"input_per_million": float(raw_tier["input"]),
		"output_per_million": float(raw_tier["output"])
	}
	if _is_number(raw_tier.get("cache_read")):
		tier["cached_input_per_million"] = float(raw_tier["cache_read"])
	if _is_number(raw_tier.get("cache_write")):
		tier["cache_write_per_million"] = float(raw_tier["cache_write"])
	return tier


static func _metadata_candidates(provider: String, model: String, fallback_model: String) -> PackedStringArray:
	var candidates := PackedStringArray()
	for candidate_model in [model, fallback_model]:
		var normalized := str(candidate_model).strip_edges().to_lower()
		if normalized.is_empty():
			continue
		var key := _catalog_key(provider, normalized)
		if key not in candidates:
			candidates.append(key)
		if normalized.contains("/") and normalized not in candidates:
			candidates.append(normalized)
	return candidates


static func _catalog_key(provider: String, model: String) -> String:
	var normalized_model := model.strip_edges().to_lower()
	if not provider.is_empty() and normalized_model.begins_with(provider + "/"):
		return normalized_model
	return provider + "/" + normalized_model if not provider.is_empty() else normalized_model


static func _with_identity(source: Dictionary, model: String, provider: String) -> Dictionary:
	var metadata := source.duplicate(true)
	metadata["model"] = model
	metadata["provider"] = provider
	return metadata


static func _is_number(value) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT]
