@tool
extends RefCounted

const RESPONSE_START_FIELD := "response_start_timeout_seconds"
const INACTIVITY_FIELD := "stream_inactivity_timeout_seconds"
const CUSTOM_ENABLED_FIELD := "custom_timeouts_enabled"
const MIN_SECONDS := 10
const MAX_SECONDS := 600
const CONNECT_SECONDS := 30
const TOTAL_GENERATION_MS := 10 * 60 * 1000
const SETTINGS_LOCATION := "Settings → Provider → Request Timeouts"


static func defaults(provider_id: String) -> Dictionary:
	return {
		RESPONSE_START_FIELD: 300 if is_local(provider_id) else 30,
		INACTIVITY_FIELD: 60,
		CUSTOM_ENABLED_FIELD: is_local(provider_id)
	}


static func is_local(provider_id: String) -> bool:
	return provider_id in ["ollama", "lmstudio", "local_openai"]


static func valid_seconds(value) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and float(value) == floor(float(value)) and value >= MIN_SECONDS and value <= MAX_SECONDS


static func resolve(config: Dictionary) -> Dictionary:
	var provider_id := str(config.get("provider", "custom"))
	var values := defaults(provider_id)
	# Managed transport timing remains release-owned, even with edited settings.
	if provider_id != "orca_cloud":
		for field in [RESPONSE_START_FIELD, INACTIVITY_FIELD]:
			var value = config.get(field, values[field])
			if not valid_seconds(value):
				return {"success": false, "error": "Invalid request timeout. Choose whole seconds from %d to %d in %s." % [MIN_SECONDS, MAX_SECONDS, SETTINGS_LOCATION]}
			values[field] = int(value)
		if config.has(CUSTOM_ENABLED_FIELD) and typeof(config[CUSTOM_ENABLED_FIELD]) != TYPE_BOOL:
			return {"success": false, "error": "Invalid custom-timeout preference. Use the toggle in %s." % SETTINGS_LOCATION}
		# Preserve non-default values saved by the earlier unreleased candidate.
		# An explicit off flag always wins over this missing-flag migration.
		var previous := defaults(provider_id)
		var changed: bool = values[RESPONSE_START_FIELD] != previous[RESPONSE_START_FIELD] or values[INACTIVITY_FIELD] != previous[INACTIVITY_FIELD]
		values[CUSTOM_ENABLED_FIELD] = is_local(provider_id) or bool(config.get(CUSTOM_ENABLED_FIELD, changed))
	var legacy_defaults: bool = not values[CUSTOM_ENABLED_FIELD]
	var effective := defaults(provider_id) if legacy_defaults else values
	return {"success": true, "values": values, "legacy_defaults": legacy_defaults, "response_start_ms": effective[RESPONSE_START_FIELD] * 1000, "inactivity_ms": effective[INACTIVITY_FIELD] * 1000}


static func probe_timeout_seconds(config: Dictionary) -> float:
	var resolved := resolve(config)
	if not resolved.get("success", false) or resolved.get("legacy_defaults", false):
		return 45.0
	var values: Dictionary = resolved["values"]
	# Two small synthetic requests share one absolute deadline; neither request
	# nor progress can restart it. Each API request also retains its 10-minute cap.
	return minf(1200.0, 2.0 * (CONNECT_SECONDS + values[RESPONSE_START_FIELD] + values[INACTIVITY_FIELD]))
