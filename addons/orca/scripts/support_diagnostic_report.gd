@tool
extends RefCounted

const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")

const SCHEMA_VERSION := 1
const PROVIDER_KINDS := ["hosted", "local", "custom", "unknown"]
const ENDPOINT_KINDS := ["canonical", "editable", "fixed_override", "invalid", "unknown"]
const NETWORK_SCOPES := ["fixed", "loopback", "lan", "remote", "unknown"]
const OUTCOMES := ["in_progress", "completed", "failed", "cancelled", "blocked_locally", "none"]
const INTERACTION_MODES := ["chat", "plan", "work", "unknown"]
const REQUEST_STAGES := ["initial", "follow_up", "safe_finalization", "unknown"]
const FAILURE_CATEGORIES := ["none", "state", "configuration", "connection", "timeout", "response_limit", "http", "malformed_response", "model_mismatch", "dns", "tls", "context_budget", "internal", "unknown"]
const TRANSPORT_PHASES := ["none", "idle", "connecting", "submitting", "waiting_for_response", "receiving_response", "local", "unknown"]
const GODOT_STATUSES := ["stable", "beta", "alpha", "rc", "dev", "unknown"]


static func current_profile(raw_config: Dictionary) -> Dictionary:
	var raw_provider := str(raw_config.get("provider", ""))
	var provider_id := raw_provider if raw_provider in ProviderRegistry.PROVIDER_IDS else "unknown"
	if provider_id == "unknown":
		return {"provider_type": "unknown", "profile_kind": "unknown", "endpoint_kind": "unknown", "network_scope": "unknown"}
	var definition: Dictionary = ProviderRegistry.get_provider(provider_id).definition()
	var profile_kind := "local" if bool(definition.get("local", false)) else "custom" if provider_id == "custom" else "hosted"
	var configured := EndpointPolicy.inspect_base_url(str(raw_config.get("base_url", "")))
	if not bool(configured.get("success", false)):
		return {"provider_type": provider_id, "profile_kind": profile_kind, "endpoint_kind": "invalid", "network_scope": "unknown"}
	if bool(definition.get("custom_url", false)):
		return {"provider_type": provider_id, "profile_kind": profile_kind, "endpoint_kind": "editable", "network_scope": _enum_value(configured.get("scope"), NETWORK_SCOPES)}
	var canonical := EndpointPolicy.inspect_base_url(str(definition.get("base_url", "")))
	if not bool(canonical.get("success", false)):
		return {"provider_type": provider_id, "profile_kind": profile_kind, "endpoint_kind": "unknown", "network_scope": "unknown"}
	if str(configured.get("origin", "")) != str(canonical.get("origin", "")):
		return {"provider_type": provider_id, "profile_kind": profile_kind, "endpoint_kind": "fixed_override", "network_scope": _enum_value(configured.get("scope"), NETWORK_SCOPES)}
	return {"provider_type": provider_id, "profile_kind": profile_kind, "endpoint_kind": "canonical", "network_scope": "fixed"}


static func build(plugin_version: String, raw_profile: Dictionary, raw_request: Dictionary) -> Dictionary:
	var version_info := Engine.get_version_info()
	var request_present := not raw_request.is_empty()
	var report := {
		"schema_version": SCHEMA_VERSION,
		"orca_version": _bounded_version(plugin_version),
		"godot_version": {
			"major": maxi(int(version_info.get("major", 0)), 0),
			"minor": maxi(int(version_info.get("minor", 0)), 0),
			"patch": maxi(int(version_info.get("patch", 0)), 0),
			"status": _enum_value(version_info.get("status"), GODOT_STATUSES),
		},
		"provider": {
			"provider_type": _provider_id(raw_profile.get("provider_type")),
			"profile_kind": _enum_value(raw_profile.get("profile_kind"), PROVIDER_KINDS),
			"endpoint_kind": _enum_value(raw_profile.get("endpoint_kind"), ENDPOINT_KINDS),
			"network_scope": _enum_value(raw_profile.get("network_scope"), NETWORK_SCOPES),
		},
		"last_request": {
			"present": request_present,
			"provider_type": _provider_id(raw_request.get("provider_type")) if request_present else "unknown",
			"outcome": _enum_value(raw_request.get("outcome"), OUTCOMES) if request_present else "none",
			"interaction_mode": _enum_value(raw_request.get("interaction_mode"), INTERACTION_MODES),
			"stage": _enum_value(raw_request.get("stage"), REQUEST_STAGES),
			"tools_offered": _safe_bool(raw_request.get("tools_offered", false)),
			"failure_category": _enum_value(raw_request.get("failure_category", "none"), FAILURE_CATEGORIES),
			"transport_phase": _enum_value(raw_request.get("transport_phase", "none"), TRANSPORT_PHASES),
			"http_status": _http_status(raw_request.get("http_status", 0)),
			"retryable": _safe_bool(raw_request.get("retryable", false)),
			"response_started": _safe_bool(raw_request.get("response_started", false)),
			"partial_response": _safe_bool(raw_request.get("partial_response", false)),
		},
	}
	return report


static func serialize(report: Dictionary) -> String:
	return JSON.stringify(report, "  ", true)


static func _provider_id(value) -> String:
	var provider_id := str(value)
	return provider_id if provider_id in ProviderRegistry.PROVIDER_IDS else "unknown"


static func _enum_value(value, allowed: Array) -> String:
	var normalized := str(value)
	return normalized if normalized in allowed else "unknown"


static func _http_status(value) -> int:
	if typeof(value) != TYPE_INT:
		return 0
	var status := int(value)
	return status if status >= 100 and status <= 599 else 0


static func _safe_bool(value) -> bool:
	return value if typeof(value) == TYPE_BOOL else false


static func _bounded_version(value: String) -> String:
	var normalized := value.strip_edges()
	if normalized.is_empty() or normalized.length() > 32:
		return "Unknown"
	for character in normalized:
		if character not in "0123456789.-+abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ":
			return "Unknown"
	return normalized
