extends SceneTree

const SupportDiagnosticReport = preload("res://addons/orca/scripts/support_diagnostic_report.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var secret := "ORCA_PRIVATE_SENTINEL"
	var raw_profile := {
		"provider": "custom",
		"base_url": "https://private.example.test/v1",
		"api_key": secret,
		"model": secret,
		"confirmed_origin": secret,
		"nested": {"prompt": secret},
	}
	var profile := SupportDiagnosticReport.current_profile(raw_profile)
	_expect(profile == {"provider_type": "custom", "profile_kind": "custom", "endpoint_kind": "editable", "network_scope": "remote"}, "profile classification should retain only coarse allowlisted endpoint metadata")
	var request := {
		"provider_type": "custom",
		"outcome": "failed",
		"interaction_mode": "chat",
		"stage": "follow_up",
		"tools_offered": false,
		"failure_category": "http",
		"transport_phase": "receiving_response",
		"http_status": 429,
		"retryable": true,
		"response_started": true,
		"partial_response": false,
		"message": secret,
		"prompt": secret,
		"source": secret,
		"filepath": secret,
		"tool_calls": [{"arguments": secret, "result": secret}],
		"reasoning_content": secret,
		"stdout": secret,
		"stderr": secret,
		"old_content": secret,
		"new_content": secret,
		"old_hash": secret,
		"new_hash": secret,
		"session": {"content": secret},
	}
	var report := SupportDiagnosticReport.build("1.2.0", profile, request)
	var serialized := SupportDiagnosticReport.serialize(report)
	var parsed = JSON.parse_string(serialized)
	_expect(typeof(parsed) == TYPE_DICTIONARY, "the diagnostic report should serialize as valid JSON")
	_expect(not serialized.contains(secret) and not serialized.contains("private.example.test"), "unknown and sensitive values must never enter serialized diagnostics")
	_expect(_sorted_keys(report) == ["godot_version", "last_request", "orca_version", "provider", "schema_version"], "the top-level diagnostic schema should be an exact allowlist")
	_expect(_sorted_keys(report.get("provider", {})) == ["endpoint_kind", "network_scope", "profile_kind", "provider_type"], "provider diagnostics should use an exact key allowlist")
	_expect(_sorted_keys(report.get("last_request", {})) == ["failure_category", "http_status", "interaction_mode", "outcome", "partial_response", "present", "provider_type", "response_started", "retryable", "stage", "tools_offered", "transport_phase"], "request diagnostics should use an exact key allowlist")
	_expect(report.get("last_request", {}).get("http_status") == 429 and report.get("last_request", {}).get("failure_category") == "http", "allowlisted coarse failure metadata should remain available")

	var malformed := SupportDiagnosticReport.build("bad version / " + secret, {"provider_type": secret, "profile_kind": secret, "endpoint_kind": secret, "network_scope": secret}, {"outcome": secret, "interaction_mode": secret, "stage": secret, "failure_category": secret, "transport_phase": secret, "http_status": "429", "retryable": secret, "tools_offered": secret})
	var malformed_text := SupportDiagnosticReport.serialize(malformed)
	_expect(not malformed_text.contains(secret), "unrecognized enum and version text must not pass through the allowlist")
	_expect(malformed.get("orca_version") == "Unknown" and malformed.get("last_request", {}).get("http_status") == 0 and not malformed.get("last_request", {}).get("retryable") and not malformed.get("last_request", {}).get("tools_offered"), "invalid version, status, and boolean values should normalize safely")
	_finish()


func _sorted_keys(value: Dictionary) -> Array:
	var keys := value.keys()
	keys.sort()
	return keys


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("support_diagnostic_report_test: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("support_diagnostic_report_test: " + failure)
	quit(1)
