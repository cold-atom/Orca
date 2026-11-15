@tool
extends RefCounted

## Computer-local descriptions only. No enabled state, process or approval is saved.
const MAX_CONNECTIONS := 4 # Maximum live bridges per editor.
const MAX_ARGUMENTS := 24
const PROFILES := ["resources", "blender", "blender_lab"]
const PROJECT_PREFIX := "orca/extensions/mcp/"
const LIBRARY_SETTING := "orca/extensions/mcp_library"
const MAX_REUSABLE := 16
const MAX_SETTINGS_PROPERTIES := 4096
const MAX_LEGACY_PROJECTS := 32
const MAX_RECORD_BYTES := 128 * 1024
const MAX_SEEN := 512
const VERSION := 2


static func project_root() -> String:
	return ProjectSettings.globalize_path("res://").simplify_path()


static func validate(raw) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY or raw.size() != 5:
		return {}
	for field in ["id", "name", "command", "profile"]:
		if typeof(raw.get(field)) != TYPE_STRING or not clean_text(raw[field], 1024):
			return {}
	var id: String = raw["id"]
	if id.length() > 48 or not id.is_valid_identifier() or id != id.to_lower():
		return {}
	if raw["name"].length() > 80 or not raw["command"].is_absolute_path() or raw["command"].begins_with("res://") or raw["command"].begins_with("user://") or raw["profile"] not in PROFILES:
		return {}
	if typeof(raw.get("arguments")) != TYPE_ARRAY or raw["arguments"].size() > MAX_ARGUMENTS:
		return {}
	for argument in raw["arguments"]:
		if typeof(argument) != TYPE_STRING or (not argument.is_empty() and not clean_text(argument, 1024)):
			return {}
	if JSON.stringify(raw).to_utf8_buffer().size() > 8192:
		return {}
	return raw.duplicate(true)


static func clean_text(text: String, limit: int) -> bool:
	if text.is_empty() or text.length() > limit:
		return false
	for character in text:
		if character.unicode_at(0) < 32 or character.unicode_at(0) == 127:
			return false
	return true


static func _entries(raw, limit: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY or raw.size() > limit:
		return result
	var ids := {}
	for value in raw:
		var entry := validate(value)
		if entry.is_empty() or ids.has(entry["id"]):
			return []
		ids[entry["id"]] = true
		result.append(entry)
	return result


static func _project_entries(record, root: String) -> Array[Dictionary]:
	if typeof(record) != TYPE_DICTIONARY or record.size() != 3 or typeof(record.get("version")) != TYPE_INT or record["version"] != 1 or record.get("root") != root:
		return []
	return _entries(record.get("connections"), MAX_CONNECTIONS)


static func empty_registry() -> Dictionary:
	return {"version": VERSION, "revision": 1, "connections": [], "legacy_seen": []}


static func validate_registry(raw) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY or raw.size() != 4 or raw.get("version") != VERSION or typeof(raw.get("version")) != TYPE_INT or typeof(raw.get("revision")) != TYPE_INT or raw["revision"] < 1 or raw["revision"] > 2147483647 or typeof(raw.get("connections")) != TYPE_ARRAY or typeof(raw.get("legacy_seen")) != TYPE_ARRAY or raw["legacy_seen"].size() > MAX_SEEN:
		return {}
	var entries := _entries(raw["connections"], MAX_REUSABLE)
	if entries.size() != raw["connections"].size() or JSON.stringify(entries).to_utf8_buffer().size() > MAX_RECORD_BYTES:
		return {}
	var seen := {}
	for hash in raw["legacy_seen"]:
		if typeof(hash) != TYPE_STRING or hash.length() != 64 or not hash.is_valid_hex_number(false) or hash != hash.to_lower() or seen.has(hash):
			return {}
		seen[hash] = true
	return raw.duplicate(true)


static func read_registry() -> Dictionary:
	if not Engine.is_editor_hint():
		return empty_registry()
	var settings := EditorInterface.get_editor_settings()
	return validate_registry(settings.get_setting(LIBRARY_SETTING)) if settings.has_setting(LIBRARY_SETTING) else {}


static func description_key(config: Dictionary) -> String:
	return JSON.stringify([config["name"], config["command"], config["arguments"], config["profile"]]).sha256_text()


static func deletion_key(config: Dictionary) -> String:
	return ("removed:" + description_key(config)).sha256_text()


static func legacy_key(config: Dictionary) -> String:
	return ("legacy:" + description_key(config)).sha256_text()


static func migrate(record: Dictionary, legacy: Array) -> Dictionary:
	# Pure bounded projection. Old records are preserved; seen fingerprints keep
	# removed connectors from resurrecting and never pick a winner for different configs.
	var next := record.duplicate(true)
	if validate_registry(next).is_empty(): return {}
	var identities := {}
	var ids := {}
	for config in next["connections"]:
		identities[description_key(config)] = true
		ids[config["id"]] = true
	for index in mini(legacy.size(), MAX_LEGACY_PROJECTS * MAX_CONNECTIONS):
		var source = legacy[index]
		if typeof(source) != TYPE_DICTIONARY: continue
		var config := validate(source.get("config"))
		if config.is_empty() or typeof(source.get("source")) != TYPE_STRING:
			continue
		var fingerprint: String = (source["source"] + JSON.stringify(config)).sha256_text()
		var origin := legacy_key(config)
		if origin not in next["legacy_seen"] and next["legacy_seen"].size() < MAX_SEEN:
			next["legacy_seen"].append(origin)
		if fingerprint in next["legacy_seen"]:
			continue
		if next["legacy_seen"].size() >= MAX_SEEN:
			break
		var identity := description_key(config)
		if deletion_key(config) in next["legacy_seen"]:
			next["legacy_seen"].append(fingerprint)
			continue
		if not identities.has(identity):
			if next["connections"].size() >= MAX_REUSABLE:
				continue
			if ids.has(config["id"]):
				config["id"] = "mcp_" + identity.left(24)
			if ids.has(config["id"]):
				continue
			var candidate: Array = next["connections"].duplicate(true)
			candidate.append(config)
			if JSON.stringify(candidate).to_utf8_buffer().size() > MAX_RECORD_BYTES:
				continue
			next["connections"] = candidate
			identities[identity] = true
			ids[config["id"]] = true
		next["legacy_seen"].append(fingerprint)
	return next


static func _legacy_descriptions(settings: EditorSettings) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var properties := settings.get_property_list()
	var projects := 0
	var bytes := 0
	for index in mini(properties.size(), MAX_SETTINGS_PROPERTIES):
		var key := str(properties[index].get("name", ""))
		if not key.begins_with(PROJECT_PREFIX):
			continue
		projects += 1
		if projects > MAX_LEGACY_PROJECTS:
			break
		var record = settings.get_setting(key)
		if typeof(record) != TYPE_DICTIONARY or typeof(record.get("root")) != TYPE_STRING:
			continue
		var root: String = record["root"]
		if not clean_text(root, 4096) or not root.is_absolute_path() or root != root.simplify_path() or key != PROJECT_PREFIX + root.sha256_text():
			continue
		var entries := _project_entries(record, root)
		bytes += JSON.stringify(entries).to_utf8_buffer().size()
		if bytes > MAX_RECORD_BYTES:
			break
		for config in entries:
			result.append({"source": key, "config": config})
	return result


static func load_registry() -> Dictionary:
	if not Engine.is_editor_hint():
		return empty_registry()
	var settings := EditorInterface.get_editor_settings()
	var raw = settings.get_setting(LIBRARY_SETTING) if settings.has_setting(LIBRARY_SETTING) else null
	var record := empty_registry()
	if raw != null:
		if typeof(raw) == TYPE_DICTIONARY and raw.size() == 2 and typeof(raw.get("version")) == TYPE_INT and raw["version"] == 1 and typeof(raw.get("connections")) == TYPE_ARRAY:
			var entries := _entries(raw["connections"], MAX_REUSABLE)
			if entries.size() != raw["connections"].size() or JSON.stringify(entries).to_utf8_buffer().size() > MAX_RECORD_BYTES:
				return {}
			var identities := {}
			for config in entries:
				var identity := description_key(config)
				if not identities.has(identity):
					record["connections"].append(config)
					record["legacy_seen"].append(legacy_key(config))
					identities[identity] = true
		else:
			record = validate_registry(raw)
			if record.is_empty():
				return {}
	var next := migrate(record, _legacy_descriptions(settings))
	if raw != next:
		if raw != null and raw.get("version") == VERSION:
			if record["revision"] == 2147483647:
				return {}
			next["revision"] += 1
		var current = settings.get_setting(LIBRARY_SETTING) if settings.has_setting(LIBRARY_SETTING) else null
		if current != raw or validate_registry(next).is_empty():
			return {}
		settings.set_setting(LIBRARY_SETTING, next)
	return read_registry()


static func save_registry(connections: Array, expected: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint() or validate_registry(expected).is_empty() or read_registry() != expected or expected["revision"] >= 2147483647:
		return {}
	var next := expected.duplicate(true)
	var entries := _entries(connections, MAX_REUSABLE)
	if entries.size() != connections.size(): return {}
	next["connections"] = entries
	for old in expected["connections"]:
		if legacy_key(old) in expected["legacy_seen"] and not entries.any(func(entry): return entry["id"] == old["id"] and description_key(entry) == description_key(old)):
			var key := deletion_key(old)
			if key not in next["legacy_seen"]: next["legacy_seen"].append(key)
	for config in entries:
		next["legacy_seen"].erase(deletion_key(config))
	next["revision"] += 1
	if validate_registry(next).is_empty():
		return {}
	EditorInterface.get_editor_settings().set_setting(LIBRARY_SETTING, next)
	return next if read_registry() == next else {}


static func find_blender_server() -> String:
	# Candidate discovery only: selecting the explicit profile remains user-owned.
	# A matching filename is never an official-server identity or tool authorization.
	var name := "blender-mcp.exe" if OS.get_name() == "Windows" else "blender-mcp"
	var home := OS.get_environment("USERPROFILE" if OS.get_name() == "Windows" else "HOME")
	var candidates: Array[String] = [home.path_join(".local/bin").path_join(name), "/usr/local/bin/" + name, "/usr/bin/" + name]
	var path := OS.get_environment("PATH")
	if path.length() <= 8192:
		var folders := path.split(";" if OS.get_name() == "Windows" else ":")
		for index in mini(folders.size(), 16):
			if folders[index].is_absolute_path() and clean_text(folders[index], 1024):
				candidates.append(folders[index].path_join(name))
	for candidate in candidates:
		if candidate.is_absolute_path() and FileAccess.file_exists(candidate) and (OS.get_name() == "Windows" or FileAccess.get_unix_permissions(candidate) & 64 != 0):
			return candidate
	return ""
