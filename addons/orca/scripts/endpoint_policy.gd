@tool
extends RefCounted

const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")


static func inspect_base_url(raw_url: String) -> Dictionary:
	return _inspect_url(raw_url, true)


static func inspect_endpoint(raw_url: String) -> Dictionary:
	return _inspect_url(raw_url, false)


static func authorize_profile(provider_id: String, config: Dictionary) -> Dictionary:
	var provider = ProviderRegistry.get_provider(provider_id)
	var definition: Dictionary = provider.definition()
	if not bool(definition.get("custom_url", false)):
		var canonical := inspect_base_url(str(definition.get("base_url", "")))
		if not canonical.get("success", false):
			return canonical
		var configured_url := str(config.get("base_url", definition.get("base_url", "")))
		var configured := inspect_base_url(configured_url)
		if not configured.get("success", false):
			return configured
		if str(configured.get("origin", "")) != str(canonical.get("origin", "")):
			if str(config.get("confirmed_origin", "")) != str(configured.get("origin", "")):
				return {"success": false, "error": "A fixed provider endpoint override requires exact-origin confirmation.", "endpoint": configured}
			var override_config := config.duplicate(true)
			override_config["base_url"] = configured["base_url"]
			return {"success": true, "config": override_config, "origin": configured["origin"], "scope": configured["scope"], "requires_confirmation": true, "endpoint": configured}
		var fixed_config := config.duplicate(true)
		fixed_config["base_url"] = canonical["base_url"]
		return {"success": true, "config": fixed_config, "origin": canonical["origin"], "scope": "fixed", "requires_confirmation": false, "endpoint": canonical}
	var inspected := inspect_base_url(str(config.get("base_url", definition.get("base_url", ""))))
	if not inspected.get("success", false):
		return inspected
	if inspected.get("requires_confirmation", false) and str(config.get("confirmed_origin", "")) != str(inspected.get("origin", "")):
		return {"success": false, "error": "This endpoint must be explicitly trusted for its exact scheme, host, and port before Orca can send credentials or project context.", "endpoint": inspected}
	var normalized_config := config.duplicate(true)
	normalized_config["base_url"] = inspected["base_url"]
	return {"success": true, "config": normalized_config, "origin": inspected["origin"], "scope": inspected["scope"], "requires_confirmation": inspected["requires_confirmation"], "endpoint": inspected}


static func validate_generated_endpoint(raw_url: String, expected_origin: String) -> Dictionary:
	var inspected := inspect_endpoint(raw_url)
	if not inspected.get("success", false):
		return inspected
	if not expected_origin.is_empty() and str(inspected.get("origin", "")) != expected_origin:
		return {"success": false, "error": "The generated endpoint changed origin after authorization."}
	return inspected


static func _inspect_url(raw_url: String, base_mode: bool) -> Dictionary:
	if raw_url.is_empty() or raw_url != raw_url.strip_edges():
		return _failure("URL must not be empty or contain surrounding whitespace.")
	for forbidden in ["\\", "\n", "\r", "\t", "?", "#"]:
		if raw_url.contains(forbidden):
			return _failure("URL contains an unsupported query, fragment, whitespace, or separator.")
	var lowered := raw_url.to_lower()
	if lowered.contains("%2f") or lowered.contains("%5c"):
		return _failure("URL contains an ambiguous encoded separator.")
	var separator := raw_url.find("://")
	if separator <= 0:
		return _failure("URL must use http:// or https://.")
	var scheme := raw_url.substr(0, separator).to_lower()
	if scheme not in ["http", "https"]:
		return _failure("URL must use http:// or https://.")
	var remainder := raw_url.substr(separator + 3)
	var path_start := remainder.find("/")
	var authority := remainder if path_start == -1 else remainder.substr(0, path_start)
	var path := "" if path_start == -1 else remainder.substr(path_start)
	if authority.is_empty() or authority.contains("@"):
		return _failure("URL host is missing or contains user information.")
	var host := ""
	var host_for_url := ""
	var port := 443 if scheme == "https" else 80
	if authority.begins_with("["):
		var bracket_end := authority.find("]")
		if bracket_end <= 1:
			return _failure("Bracketed IPv6 host is invalid.")
		host = authority.substr(1, bracket_end - 1).to_lower()
		if not host.is_valid_ip_address():
			return _failure("Bracketed IPv6 host is invalid.")
		host_for_url = "[" + host + "]"
		var suffix := authority.substr(bracket_end + 1)
		if not suffix.is_empty():
			if not suffix.begins_with(":") or not _valid_port(suffix.substr(1)):
				return _failure("URL port is invalid.")
			port = int(suffix.substr(1))
	else:
		if authority.count(":") > 1:
			return _failure("IPv6 hosts must use brackets.")
		var port_separator := authority.rfind(":")
		host = authority if port_separator == -1 else authority.substr(0, port_separator)
		if port_separator != -1:
			var raw_port := authority.substr(port_separator + 1)
			if not _valid_port(raw_port):
				return _failure("URL port is invalid.")
			port = int(raw_port)
		host = host.to_lower()
		if not _valid_host(host):
			return _failure("URL host is invalid.")
		host_for_url = host
	while path.ends_with("/"):
		path = path.trim_suffix("/")
	if path.contains("/../") or path.ends_with("/..") or path.contains("/./") or path.ends_with("/."):
		return _failure("URL path must not contain dot segments.")
	if base_mode:
		var lower_path := path.to_lower()
		if lower_path.ends_with("/models") or lower_path.ends_with("/chat/completions"):
			return _failure("Enter a base URL, not a complete models or chat/completions endpoint.")
	var default_port := (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
	var normalized_authority := host_for_url + ("" if default_port else ":" + str(port))
	var origin := "%s://%s:%d" % [scheme, host_for_url, port]
	var scope := _classify_host(host)
	return {
		"success": true,
		"base_url": scheme + "://" + normalized_authority + path,
		"origin": origin,
		"scheme": scheme,
		"host": host,
		"port": port,
		"target": path if not path.is_empty() else "/",
		"path": path,
		"scope": scope,
		"is_loopback": scope == "loopback",
		"requires_confirmation": scope != "loopback",
		"uses_plaintext": scheme == "http"
	}


static func _valid_port(value: String) -> bool:
	return not value.is_empty() and value.is_valid_int() and int(value) > 0 and int(value) <= 65535 and not value.begins_with("+") and not value.begins_with("-")


static func _valid_host(host: String) -> bool:
	if host.is_empty() or host.begins_with(".") or host.ends_with(".") or host.contains(".."):
		return false
	if host.is_valid_ip_address():
		return host != "0.0.0.0" and not host.begins_with("224.") and host != "255.255.255.255"
	var regex := RegEx.new()
	return regex.compile("^[a-z0-9.-]+$") == OK and regex.search(host) != null


static func _classify_host(host: String) -> String:
	if host == "localhost" or host in ["::1", "0:0:0:0:0:0:0:1"] or host.begins_with("::ffff:127.") or (host.is_valid_ip_address() and host.begins_with("127.")):
		return "loopback"
	if host.ends_with(".local"):
		return "lan"
	if host.contains(":"):
		var lowered := host.to_lower()
		if lowered.begins_with("fc") or lowered.begins_with("fd") or lowered.begins_with("fe8") or lowered.begins_with("fe9") or lowered.begins_with("fea") or lowered.begins_with("feb"):
			return "lan"
		return "remote"
	var parts := host.split(".")
	if parts.size() == 4 and host.is_valid_ip_address():
		var first := int(parts[0])
		var second := int(parts[1])
		if first == 10 or (first == 172 and second >= 16 and second <= 31) or (first == 192 and second == 168) or (first == 169 and second == 254):
			return "lan"
	return "remote"


static func _failure(message: String) -> Dictionary:
	return {"success": false, "error": message}
