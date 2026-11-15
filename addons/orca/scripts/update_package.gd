@tool
extends RefCounted

# Stateless filesystem/package code also copied into the independent installer.
# Never load or execute code from the downloaded archive during validation.
const MANIFEST := "update_manifest.json"
const MAX_ARCHIVE := 32 * 1024 * 1024
const MAX_TOTAL := 128 * 1024 * 1024
const MAX_FILE := 8 * 1024 * 1024
const MAX_MANIFEST := 512 * 1024
const MAX_FILES := 2048
const WORKSPACE := ".orca-update"
const FORMAT := "orca-update-v1"


static func failure(message: String) -> Dictionary:
	return {"success": false, "error": message}


static func version_parts(value: String) -> Array:
	if value.length() > 32:
		return []
	var parts := value.split(".")
	if parts.size() != 3:
		return []
	var result := []
	for part in parts:
		if part.is_empty() or part.length() > 6 or (part.length() > 1 and part.begins_with("0")):
			return []
		for character in part:
			if character not in "0123456789":
				return []
		result.append(int(part))
	return result


static func compare_versions(left: String, right: String) -> int:
	var a := version_parts(left)
	var b := version_parts(right)
	if a.is_empty() or b.is_empty():
		return -2
	for index in 3:
		if a[index] != b[index]:
			return 1 if a[index] > b[index] else -1
	return 0


static func safe_path(path: String) -> bool:
	if path.is_empty() or path.length() > 240 or path.begins_with("/") or path.ends_with("/"):
		return false
	for part in path.split("/"):
		if part.is_empty() or part in [".", ".."] or part.begins_with(".") or part.ends_with(".") or part.ends_with(" "):
			return false
		var stem := part.get_slice(".", 0).to_upper()
		if stem in ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]:
			return false
	for character in path:
		if character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-. /":
			return false
	return not path.contains("\\")


static func no_links(path: String) -> bool:
	var current := path.simplify_path()
	while not current.is_empty():
		var directory := DirAccess.open(current.get_base_dir())
		if directory != null and directory.is_link(current):
			return false
		var parent := current.get_base_dir()
		if parent == current:
			break
		current = parent
	return true


static func process_alive(pid: int) -> bool:
	if pid <= 0 or pid > 2147483647:
		return false
	if OS.get_name() in ["Linux", "macOS"]:
		# Godot's Unix process API only accepts its own children. A fixed signal-0
		# probe checks the retained editor/worker PID without sending a signal.
		return OS.execute("/bin/kill", PackedStringArray(["-0", str(pid)]), [], false) == 0
	return OS.is_process_running(pid)


static func read_json(path: String, limit: int = MAX_MANIFEST) -> Dictionary:
	if not no_links(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > limit:
		return {}
	var bytes := file.get_buffer(file.get_length())
	var text := bytes.get_string_from_utf8()
	var value = JSON.parse_string(text) if text.to_utf8_buffer() == bytes else null
	return value if typeof(value) == TYPE_DICTIONARY else {}


static func write_json(path: String, value: Dictionary) -> bool:
	if not no_links(path) or not no_links(path + ".tmp"):
		return false
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value))
	file.flush()
	var error := file.get_error()
	file.close()
	return error == OK and DirAccess.rename_absolute(path + ".tmp", path) == OK


static func valid_manifest(value: Dictionary, expected_version: String = "") -> bool:
	if value.size() != 4 or value.get("format") != FORMAT or typeof(value.get("version")) != TYPE_STRING or typeof(value.get("min_godot")) != TYPE_STRING or version_parts(value["version"]).is_empty() or version_parts(value["min_godot"]).is_empty():
		return false
	if not expected_version.is_empty() and value["version"] != expected_version:
		return false
	var files = value.get("files")
	if typeof(files) != TYPE_ARRAY or files.is_empty() or files.size() > MAX_FILES:
		return false
	var seen := {}
	var total := 0
	for entry in files:
		if typeof(entry) != TYPE_DICTIONARY or entry.size() != 4 or typeof(entry.get("path")) != TYPE_STRING or not safe_path(entry["path"]) or entry["path"] == MANIFEST or seen.has(entry["path"].to_lower()):
			return false
		var size = entry.get("size")
		var hash = entry.get("sha256")
		if typeof(size) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(size)) or float(size) != floorf(float(size)) or size < 0 or size > MAX_FILE or typeof(hash) != TYPE_STRING or hash.length() != 64 or not hash.is_valid_hex_number(false) or hash != hash.to_lower() or typeof(entry.get("executable")) != TYPE_BOOL:
			return false
		if entry["executable"] and entry["path"] not in ["native/credential_helper_linux.x86_64", "native/credential_helper_linux.arm64", "native/credential_helper_macos.x86_64", "native/credential_helper_macos.arm64", "native/credential_helper_windows.x86_64.exe", "native/credential_helper_windows.arm64.exe"]:
			return false
		seen[entry["path"].to_lower()] = true
		total += int(size)
		if total > MAX_TOTAL:
			return false
	if seen.has("scripts/blender_workspace_service.gd") and (not seen.has("blender/workspace_connector.py") or not seen.has("blender/workspace_contract.py")):
		return false
	return seen.has("plugin.cfg") and seen.has("orca.gd")


static func inspect_tree(root: String, expected_hash: String = "") -> Dictionary:
	if not no_links(root):
		return failure("Addon and update paths must not traverse symbolic links.")
	var manifest := read_json(root.path_join(MANIFEST))
	if not valid_manifest(manifest):
		return failure("This addon has no valid release manifest. Install an official updater-equipped release package first.")
	var hash := FileAccess.get_sha256(root.path_join(MANIFEST))
	if not expected_hash.is_empty() and hash != expected_hash:
		return failure("The addon release manifest changed. The update was stopped.")
	var listed := {MANIFEST: true}
	for entry in manifest["files"]:
		var path := root.path_join(entry["path"])
		var file := FileAccess.open(path, FileAccess.READ) if no_links(path) else null
		if file == null or file.get_length() != int(entry["size"]) or FileAccess.get_sha256(path) != entry["sha256"]:
			return failure("Addon files differ from their release manifest. Preserve local changes and install manually.")
		listed[entry["path"]] = true
	var pending := [""]
	var count := 0
	var import_bytes := 0
	while not pending.is_empty():
		var relative: String = pending.pop_back()
		var directory := DirAccess.open(root.path_join(relative))
		if directory == null:
			return failure("An addon directory could not be read.")
		directory.include_hidden = true
		for name in directory.get_files():
			count += 1
			var item := relative.path_join(name)
			if count > MAX_FILES * 2 or not no_links(root.path_join(item)) or (not listed.has(item) and not (item.ends_with(".import") and listed.has(item.trim_suffix(".import")))):
				return failure("The addon contains unrecognized or locally added files. Install manually to preserve them.")
			if not listed.has(item):
				var metadata := FileAccess.open(root.path_join(item), FileAccess.READ)
				if metadata == null or metadata.get_length() > 128 * 1024:
					return failure("Generated addon import metadata exceeds its limit.")
				import_bytes += metadata.get_length()
				if import_bytes > 8 * 1024 * 1024:
					return failure("Generated addon import metadata exceeds its aggregate limit.")
		for name in directory.get_directories():
			count += 1
			var item := relative.path_join(name)
			if count > MAX_FILES * 2 or not safe_path(item) or not no_links(root.path_join(item)):
				return failure("Unsupported addon directory or symbolic link.")
			var expected_directory := false
			for listed_path in listed:
				if str(listed_path).begins_with(item + "/"):
					expected_directory = true
					break
			if not expected_directory:
				return failure("The addon contains locally added directories. Install manually to preserve them.")
			pending.append(item)
	var config := ConfigFile.new()
	if config.load(root.path_join("plugin.cfg")) != OK or config.get_value("plugin", "version", "") != manifest["version"] or config.get_value("plugin", "script", "") != "orca.gd" or config.get_value("plugin", "name", "") != "Orca":
		return failure("Release plugin metadata does not match the manifest.")
	return {"success": true, "manifest": manifest, "hash": hash}


static func archive_index(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ) if no_links(path) else null
	if file == null or file.get_length() < 22 or file.get_length() > MAX_ARCHIVE:
		return failure("The release archive is missing or exceeds its size limit.")
	file.seek(file.get_length() - 22)
	if file.get_32() != 0x06054b50 or file.get_16() != 0 or file.get_16() != 0:
		return failure("Only single-volume, comment-free release ZIPs are supported.")
	var disk_entries := file.get_16()
	var entries := file.get_16()
	var directory_size := file.get_32()
	var directory_offset := file.get_32()
	if file.get_16() != 0 or entries != disk_entries or entries < 1 or entries > MAX_FILES + 1 or directory_offset + directory_size != file.get_length() - 22:
		return failure("Invalid or oversized ZIP directory.")
	file.seek(directory_offset)
	var index := {}
	var lower_names := {}
	var total := 0
	var spans := []
	for item in entries:
		if file.get_position() + 46 > directory_offset + directory_size or file.get_32() != 0x02014b50:
			return failure("Malformed ZIP entry.")
		file.get_16() # creator
		var needed := file.get_16()
		var flags := file.get_16()
		var method := file.get_16()
		file.get_32() # date/time
		var crc := file.get_32()
		var compressed := file.get_32()
		var expanded := file.get_32()
		var name_size := file.get_16()
		var extra_size := file.get_16()
		var comment_size := file.get_16()
		var disk := file.get_16()
		file.get_16()
		var attributes := file.get_32()
		var offset := file.get_32()
		if needed > 20 or flags & ~0x800 != 0 or method not in [0, 8] or disk != 0 or extra_size != 0 or comment_size != 0 or name_size == 0 or name_size > 260 or expanded > MAX_FILE or compressed > MAX_ARCHIVE or ((attributes >> 16) & 0xf000) not in [0, 0x8000]:
			return failure("ZIP64, encrypted, linked, directory, or unsupported ZIP entries are rejected.")
		var name_bytes := file.get_buffer(name_size)
		var name := name_bytes.get_string_from_utf8()
		if name.to_utf8_buffer() != name_bytes or not name.begins_with("addons/orca/") or not safe_path(name.trim_prefix("addons/orca/")) or lower_names.has(name.to_lower()):
			return failure("Archive paths must be unique regular files inside addons/orca.")
		var position := file.get_position()
		if position > directory_offset + directory_size or offset + 30 + name_size + compressed > directory_offset:
			return failure("ZIP entry is outside its data region.")
		file.seek(offset)
		if file.get_32() != 0x04034b50 or file.get_16() != needed or file.get_16() != flags or file.get_16() != method:
			return failure("ZIP local headers do not match the directory.")
		file.get_32()
		if file.get_32() != crc or file.get_32() != compressed or file.get_32() != expanded or file.get_16() != name_size or file.get_16() != 0 or file.get_buffer(name_size) != name_bytes:
			return failure("ZIP size/header mismatch.")
		spans.append([offset, file.get_position() + compressed])
		file.seek(position)
		total += expanded
		if total > MAX_TOTAL + MAX_MANIFEST:
			return failure("Expanded archive exceeds the release limit.")
		index[name] = expanded
		lower_names[name.to_lower()] = true
	if file.get_position() != directory_offset + directory_size:
		return failure("Unexpected ZIP directory data.")
	spans.sort_custom(func(a, b): return a[0] < b[0])
	var end := 0
	for span in spans:
		if span[0] != end:
			return failure("Overlapping or unindexed ZIP data.")
		end = span[1]
	if end != directory_offset:
		return failure("Unindexed ZIP payload.")
	return {"success": true, "files": index}


static func extract_archive(archive: String, stage: String, version: String, digest: String, godot_version: String) -> Dictionary:
	if not no_links(stage) or DirAccess.dir_exists_absolute(stage) or FileAccess.get_sha256(archive) != digest:
		return failure("The release checksum changed or the staging directory is occupied.")
	var checked := archive_index(archive)
	if not checked.get("success", false):
		return checked
	var reader := ZIPReader.new()
	if reader.open(archive) != OK:
		return failure("The release ZIP could not be opened.")
	var manifest_path := "addons/orca/" + MANIFEST
	if not checked["files"].has(manifest_path) or int(checked["files"][manifest_path]) > MAX_MANIFEST:
		return failure("This release does not support automatic installation. Download it from GitHub.")
	var bytes := reader.read_file(manifest_path)
	var text := bytes.get_string_from_utf8()
	var manifest = JSON.parse_string(text) if bytes.size() == checked["files"][manifest_path] and text.to_utf8_buffer() == bytes else null
	if typeof(manifest) != TYPE_DICTIONARY or not valid_manifest(manifest, version) or compare_versions(godot_version, manifest["min_godot"]) not in [0, 1] or version_parts(manifest["min_godot"])[0] != version_parts(godot_version)[0] or manifest["files"].size() + 1 != checked["files"].size():
		return failure("Release manifest/version or Godot compatibility check failed.")
	for entry in manifest["files"]:
		var name: String = "addons/orca/" + entry["path"]
		if not checked["files"].has(name) or int(checked["files"][name]) != int(entry["size"]):
			return failure("ZIP files do not match the release manifest.")
	if DirAccess.make_dir_recursive_absolute(stage) != OK:
		return failure("Could not create update staging directory.")
	for entry in manifest["files"]:
		var name: String = entry["path"]
		var data := reader.read_file("addons/orca/" + name)
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(data)
		if data.size() != int(entry["size"]) or hash.finish().hex_encode() != entry["sha256"]:
			return failure("A release file failed its size/checksum check.")
		var target := stage.path_join(name)
		if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
			return failure("Could not create a staged release directory.")
		var file := FileAccess.open(target, FileAccess.WRITE)
		if file == null:
			return failure("Could not write a staged release file.")
		file.store_buffer(data)
		file.close()
		if entry["executable"] and OS.get_name() != "Windows" and FileAccess.set_unix_permissions(target, 493) != OK:
			return failure("Could not set credential helper executable permissions.")
	var file := FileAccess.open(stage.path_join(MANIFEST), FileAccess.WRITE)
	if file == null:
		return failure("Could not write release manifest.")
	file.store_buffer(bytes)
	file.close()
	reader.close()
	return inspect_tree(stage)


static func owned_workspace(project: String, create: bool = false) -> Dictionary:
	var root := project.path_join(WORKSPACE)
	if not project.is_absolute_path() or not no_links(project) or not no_links(root) or not no_links(project.path_join("addons/orca")):
		return failure("Update paths must be absolute and free of symbolic links.")
	if not DirAccess.dir_exists_absolute(root):
		if not create or DirAccess.make_dir_absolute(root) != OK:
			return failure("Update workspace is unavailable.")
		var ignore := FileAccess.open(root.path_join(".gdignore"), FileAccess.WRITE)
		if ignore == null:
			return failure("Could not isolate the update workspace from editor imports.")
		ignore.close()
		if not write_json(root.path_join("owner.json"), {"format": FORMAT, "project": project}):
			return failure("Could not mark the update workspace.")
	if read_json(root.path_join("owner.json"), 4096) != {"format": FORMAT, "project": project}:
		return failure("An unrelated update workspace exists. Its contents were preserved.")
	var ignore_path := root.path_join(".gdignore")
	var ignore_file := FileAccess.open(ignore_path, FileAccess.READ) if no_links(ignore_path) else null
	if ignore_file == null or ignore_file.get_length() != 0:
		return failure("The update workspace is not isolated from Godot imports. Its contents were preserved.")
	return {"success": true, "root": root}


static func acquire_lock(project: String, pid: int) -> Dictionary:
	var workspace := owned_workspace(project, true)
	if not workspace.get("success", false):
		return workspace
	var root: String = workspace["root"]
	var lock := root.path_join("lock")
	if not no_links(lock):
		return failure("Update lock path is a symbolic link.")
	if DirAccess.dir_exists_absolute(lock):
		var owner := read_json(lock.path_join("owner.json"), 4096)
		var directory := DirAccess.open(lock)
		if directory != null:
			directory.include_hidden = true
		if owner.size() != 1 or typeof(owner.get("pid")) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(owner["pid"])) or owner["pid"] <= 0 or owner["pid"] != floorf(owner["pid"]) or directory == null or directory.get_files() != PackedStringArray(["owner.json"]) or not directory.get_directories().is_empty():
			return failure("Unrecognized update lock contents were preserved.")
		if process_alive(int(owner["pid"])):
			return failure("Another editor or installer is already updating this project.")
		if DirAccess.remove_absolute(lock.path_join("owner.json")) != OK or DirAccess.remove_absolute(lock) != OK:
			return failure("Could not clear an abandoned update lock.")
	if DirAccess.make_dir_absolute(lock) != OK:
		return failure("Another editor is preparing an update for this project.")
	if not write_json(lock.path_join("owner.json"), {"pid": pid}):
		return failure("Could not record update lock ownership.")
	return workspace


static func release_lock(root: String, pid: int) -> void:
	var lock := root.path_join("lock")
	if no_links(lock) and read_json(lock.path_join("owner.json"), 4096) == {"pid": pid}:
		DirAccess.remove_absolute(lock.path_join("owner.json"))
		DirAccess.remove_absolute(lock)


static func remove_tree(root: String) -> bool:
	# Only callers with an owned workspace may use this bounded scratch cleanup.
	if not no_links(root):
		return false
	if not DirAccess.dir_exists_absolute(root):
		return true
	var pending := [root]
	var visited := []
	var count := 0
	var total := 0
	while not pending.is_empty():
		var path: String = pending.pop_back()
		var directory := DirAccess.open(path)
		if directory == null:
			return false
		directory.include_hidden = true
		visited.append(path)
		for name in directory.get_files():
			var item := path.path_join(name)
			if not no_links(item):
				return false
			var file := FileAccess.open(item, FileAccess.READ)
			if file == null:
				return false
			total += file.get_length()
			count += 1
			if count > MAX_FILES * 2 or total > MAX_TOTAL + MAX_MANIFEST:
				return false
		for name in directory.get_directories():
			count += 1
			var item := path.path_join(name)
			if count > MAX_FILES * 2 or not no_links(item):
				return false
			pending.append(item)
	visited.reverse()
	for path in visited:
		var directory := DirAccess.open(path)
		for name in directory.get_files():
			if DirAccess.remove_absolute(path.path_join(name)) != OK:
				return false
		if DirAccess.remove_absolute(path) != OK:
			return false
	return true


static func install(project: String, old_hash: String, new_hash: String) -> Dictionary:
	var workspace := owned_workspace(project)
	if not workspace.get("success", false):
		return workspace
	var root: String = workspace["root"]
	var target := project.path_join("addons/orca")
	var stage := root.path_join("staged")
	var backup := root.path_join("backup")
	if not inspect_tree(target, old_hash).get("success", false) or not inspect_tree(stage, new_hash).get("success", false) or DirAccess.dir_exists_absolute(backup):
		return failure("Installed/staged files changed or the rollback directory is occupied.")
	var transaction := {"format": FORMAT, "old_hash": old_hash, "new_hash": new_hash, "state": "prepared"}
	if not write_json(root.path_join("transaction.json"), transaction):
		return failure("Could not record update recovery information.")
	if DirAccess.rename_absolute(target, backup) != OK:
		return failure("The addon could not be moved to rollback storage.")
	# Check the moved bytes too: never knowingly replace an intervening edit.
	if not inspect_tree(backup, old_hash).get("success", false) or DirAccess.rename_absolute(stage, target) != OK:
		if DirAccess.rename_absolute(backup, target) != OK:
			return failure("Update stopped; restore the retained backup with the recovery launcher.")
		return failure("Update stopped; the original addon was restored.")
	transaction["state"] = "installed"
	if not inspect_tree(target, new_hash).get("success", false) or not write_json(root.path_join("transaction.json"), transaction):
		return recover(project)
	return {"success": true}


static func recover(project: String) -> Dictionary:
	var workspace := owned_workspace(project)
	if not workspace.get("success", false):
		return workspace
	var root: String = workspace["root"]
	var record := read_json(root.path_join("transaction.json"), 4096)
	if record.size() != 4 or record.get("format") != FORMAT or typeof(record.get("old_hash")) != TYPE_STRING or typeof(record.get("new_hash")) != TYPE_STRING or record["old_hash"].length() != 64 or record["new_hash"].length() != 64 or record.get("state") not in ["prepared", "installed", "rolled_back"]:
		return failure("No valid update recovery record is available.")
	var target := project.path_join("addons/orca")
	var backup := root.path_join("backup")
	if inspect_tree(target, record["old_hash"]).get("success", false):
		return {"success": true, "rolled_back": true}
	if not inspect_tree(backup, record["old_hash"]).get("success", false):
		return failure("The retained rollback copy changed; recovery preserved all files.")
	if DirAccess.dir_exists_absolute(target):
		if not inspect_tree(target, record["new_hash"]).get("success", false) or DirAccess.dir_exists_absolute(root.path_join("staged")) or DirAccess.rename_absolute(target, root.path_join("staged")) != OK:
			return failure("The current addon changed; recovery preserved it for manual review.")
	if DirAccess.rename_absolute(backup, target) != OK:
		return failure("Could not restore the retained rollback copy.")
	record["state"] = "rolled_back"
	if not write_json(root.path_join("transaction.json"), record):
		return failure("Addon restored, but its recovery record could not be updated.")
	return {"success": true, "rolled_back": true}
