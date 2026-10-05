extends SceneTree

const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_parsing()
	_test_classification_and_confirmation()
	_finish()


func _test_parsing() -> void:
	var normalized := EndpointPolicy.inspect_base_url("HTTPS://Example.COM:443/v1/")
	_expect(normalized.get("success", false) and normalized.get("base_url") == "https://example.com/v1" and normalized.get("origin") == "https://example.com:443", "scheme, host, default port, and trailing slash should normalize")
	var ipv6 := EndpointPolicy.inspect_base_url("http://[::1]:11434/v1")
	_expect(ipv6.get("success", false) and ipv6.get("scope") == "loopback" and ipv6.get("origin") == "http://[::1]:11434", "bracketed IPv6 loopback should normalize")
	for invalid in ["localhost:11434/v1", "ftp://localhost/v1", " http://localhost/v1", "http://user@localhost/v1", "http://localhost/v1?x=1", "http://localhost/v1#x", "http://localhost:0/v1", "http://localhost:70000/v1", "http://localhost/v1/models", "http://localhost/v1/chat/completions", "http://localhost/v1/../x", "http://localhost/%2fmodels"]:
		_expect(not EndpointPolicy.inspect_base_url(invalid).get("success", true), "invalid base URL should be rejected: " + invalid)


func _test_classification_and_confirmation() -> void:
	for url in ["http://localhost:11434/v1", "http://127.5.4.3:11434/v1", "http://[::1]:11434/v1", "http://[0:0:0:0:0:0:0:1]:11434/v1"]:
		var inspected := EndpointPolicy.inspect_base_url(url)
		_expect(inspected.get("scope") == "loopback" and not inspected.get("requires_confirmation", true), "loopback should not require confirmation: " + url)
	for pair in [["http://192.168.1.2:11434/v1", "lan"], ["http://10.0.0.2/v1", "lan"], ["https://models.example.com/v1", "remote"]]:
		var inspected := EndpointPolicy.inspect_base_url(pair[0])
		_expect(inspected.get("scope") == pair[1] and inspected.get("requires_confirmation", false), "non-loopback scope should require confirmation: " + pair[0])
	var deceptive := EndpointPolicy.inspect_base_url("http://127.attacker.example/v1")
	_expect(deceptive.get("scope") == "remote" and deceptive.get("requires_confirmation", false), "DNS names beginning with 127 must not receive the IP loopback exemption")
	var config := {"base_url": "http://192.168.1.2:11434/v1", "confirmed_origin": ""}
	_expect(not EndpointPolicy.authorize_profile("ollama", config).get("success", true), "unconfirmed LAN endpoint should be denied")
	config["confirmed_origin"] = "http://192.168.1.2:11434"
	_expect(EndpointPolicy.authorize_profile("ollama", config).get("success", false), "exact LAN origin confirmation should authorize")
	config["base_url"] = "http://192.168.1.2:11435/v1"
	_expect(not EndpointPolicy.authorize_profile("ollama", config).get("success", true), "port changes should invalidate confirmation")
	_expect(not EndpointPolicy.authorize_profile("openai", {"base_url": "http://attacker.example/v1", "confirmed_origin": ""}).get("success", true), "fixed provider overrides should fail without explicit exact-origin confirmation")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("endpoint_policy_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("endpoint_policy_test: ", failure)
	quit(1)
