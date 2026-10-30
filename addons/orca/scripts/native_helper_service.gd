@tool
extends Node

signal changed
signal preparation_finished(success: bool)
signal _network_reply(reply: Array)

const Package = preload("res://addons/orca/scripts/update_package.gd")
const FORMAT := "orca-native-helpers-v1"
const CATALOG := "res://addons/orca/native_helpers.json"
const DOWNLOAD_ROOT := "https://github.com/cold-atom/Orca/releases/download/"
const MAX_FILE := 8 * 1024 * 1024
const PREPARATION_TIMEOUT_MS := 150000
const MAX_DOWNLOAD_ATTEMPTS := 3
const PLATFORMS := {"linux": ["x86_64"], "windows": ["x86_64"], "macos": ["arm64", "x86_64"]}

var state := "missing"
var status := "Cloud sign-in needs the secure credential helper."
var downloaded_bytes := 0
var entry := {}
var version := ""
var _request: HTTPRequest
var _generation := 0
var _closed := false
var _lock := ""
var _owner := {}
var _preparing := false
var _preparation_generation := 0
var _preparation_deadline := 0
var _retryable_failure := false
var _waiting_for_install := false


func _ready() -> void:
	set_process(false)
	var config := ConfigFile.new()
	if config.load("res://addons/orca/plugin.cfg") == OK:
		version = str(config.get_value("plugin", "version", ""))
	var catalog := Package.read_json(CATALOG, 8192)
	var normalized := normalize_catalog(catalog, version)
	if not normalized.get("success", false):
		_set_state("unsupported", "This installation has no valid native-helper catalog. Install an official Orca release, or prepare helpers for this source checkout.")
		return
	var platform: String = {"Linux": "linux", "Windows": "windows", "macOS": "macos"}.get(OS.get_name(), "")
	for candidate in normalized["helpers"]:
		if candidate["platform"] == platform and candidate["architecture"] == Engine.get_architecture_name():
			entry = candidate.duplicate(true)
			break
	if entry.is_empty():
		_set_state("unsupported", "Secure Cloud credential storage is not supported on %s %s. BYOK and local providers remain available." % [OS.get_name(), Engine.get_architecture_name()])
	elif not executable().is_empty():
		_set_state("ready", "Secure credential helper is installed.")
	elif automatic_downloads_enabled():
		call_deferred("_automatic_startup")


func automatic_downloads_enabled() -> bool:
	return Engine.is_editor_hint() and OS.get_environment("ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS") != "1"


func _automatic_startup() -> void:
	if not _closed and automatic_downloads_enabled():
		await prepare()


static func normalize_catalog(value: Dictionary, expected_version: String) -> Dictionary:
	if value.size() != 3 or value.get("format") != FORMAT or value.get("version") != expected_version or Package.version_parts(expected_version).is_empty() or typeof(value.get("helpers")) != TYPE_ARRAY or value["helpers"].is_empty() or value["helpers"].size() > 4:
		return {"success": false}
	var seen := {}
	for item in value["helpers"]:
		if typeof(item) != TYPE_DICTIONARY or item.size() != 5 or typeof(item.get("platform")) != TYPE_STRING or typeof(item.get("architecture")) != TYPE_STRING or not PLATFORMS.has(item["platform"]) or item["architecture"] not in PLATFORMS[item["platform"]]:
			return {"success": false}
		var name := "credential_helper_%s.%s%s" % [item["platform"], item["architecture"], ".exe" if item["platform"] == "windows" else ""]
		var size = item.get("size")
		var digest = item.get("sha256")
		if item.get("asset") != name or seen.has(name) or typeof(size) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(size)) or size != floorf(size) or size < 64 or size > MAX_FILE or typeof(digest) != TYPE_STRING or digest.length() != 64 or not digest.is_valid_hex_number(false) or digest != digest.to_lower():
			return {"success": false}
		seen[name] = true
	return {"success": true, "helpers": value["helpers"].duplicate(true)}


func cache_root() -> String:
	# Per OS user, shared across projects; never part of the addon/update manifest.
	return OS.get_data_dir().path_join("Orca/native")


func _target() -> String:
	return cache_root().path_join(entry["sha256"]).path_join(entry["asset"]) if not entry.is_empty() else ""


func executable() -> String:
	var target := _target()
	if target.is_empty() or not verify_file(target, entry):
		return ""
	return target if OS.get_name() == "Windows" or FileAccess.get_unix_permissions(target) & 64 != 0 else ""


static func verify_file(path: String, item: Dictionary) -> bool:
	if not Package.no_links(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() != int(item.get("size", -1)) or file.get_length() > MAX_FILE:
		return false
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode() == item.get("sha256") and valid_native_header(bytes, item)


static func valid_native_header(bytes: PackedByteArray, item: Dictionary) -> bool:
	if bytes.size() < 64:
		return false
	match item.get("platform", ""):
		"linux":
			return bytes.slice(0, 6) == PackedByteArray([127, 69, 76, 70, 2, 1]) and bytes.decode_u16(18) == 62 and bytes.decode_u16(16) in [2, 3]
		"windows":
			var offset := bytes.decode_u32(60)
			return bytes.slice(0, 2) == PackedByteArray([77, 90]) and offset >= 64 and offset <= bytes.size() - 24 and bytes.slice(offset, offset + 4) == PackedByteArray([80, 69, 0, 0]) and bytes.decode_u16(offset + 4) == 0x8664
		"macos":
			var cpu := 0x100000c if item.get("architecture") == "arm64" else 0x1000007
			return bytes.slice(0, 4) == PackedByteArray([207, 250, 237, 254]) and bytes.decode_u32(4) == cpu and bytes.decode_u32(12) == 2
	return false


func busy() -> bool:
	return _preparing or state in ["downloading", "verifying"] or not _lock.is_empty() or _request != null


func prepare() -> bool:
	# One background operation shared by startup restoration and explicit sign-in.
	# This never opens a browser or initiates account/model requests by itself.
	if _closed or entry.is_empty():
		return false
	if _preparing:
		var prepared: bool = await preparation_finished
		return prepared and not _closed
	if not executable().is_empty():
		return true
	if _request != null:
		return false
	_preparing = true
	_preparation_generation += 1
	var generation := _preparation_generation
	_preparation_deadline = Time.get_ticks_msec() + PREPARATION_TIMEOUT_MS
	var attempts := 0
	while not _closed and generation == _preparation_generation and Time.get_ticks_msec() < _preparation_deadline:
		_retryable_failure = false
		_waiting_for_install = false
		var prepared: bool = await _install_once()
		if _closed or generation != _preparation_generation:
			return false
		if prepared:
			return _finish_preparation(generation, true)
		if _waiting_for_install:
			# Another editor owns this hash. Wait for its verified cache, never delete
			# its live lock, download concurrently, or spin without a deadline.
			await get_tree().create_timer(minf(0.25, maxf(0.001, (_preparation_deadline - Time.get_ticks_msec()) / 1000.0))).timeout
			continue
		attempts += 1
		if not _retryable_failure or attempts >= MAX_DOWNLOAD_ATTEMPTS:
			break
		_set_state("retrying", "Preparing secure connection…")
		if _closed or generation != _preparation_generation:
			return false
		await get_tree().create_timer(minf(pow(2, attempts - 1), maxf(0.001, (_preparation_deadline - Time.get_ticks_msec()) / 1000.0))).timeout
	if generation != _preparation_generation or _closed:
		return false
	if state in ["waiting", "retrying"]:
		_set_state("error", "Secure connection preparation timed out. Try signing in again.")
	return _finish_preparation(generation, false)


func _finish_preparation(generation: int, success: bool) -> bool:
	if generation == _preparation_generation:
		_preparing = false
		_preparation_deadline = 0
		preparation_finished.emit(success)
	return success


func _install_once() -> bool:
	if _closed or state in ["downloading", "verifying"] or not _lock.is_empty() or _request != null or entry.is_empty():
		return false
	if not executable().is_empty():
		_set_state("ready", "Secure credential helper is installed.")
		return true
	_generation += 1
	var generation := _generation
	var target := _target()
	if not Package.no_links(target) or DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK or not _acquire_lock(target.get_base_dir()):
		_set_state("waiting" if _waiting_for_install else "error", "Preparing secure connection…" if _waiting_for_install else "The secure connection cache is unavailable. Check its permissions and try signing in again.")
		return false
	# Content-addressed files are immutable. Changed bytes are never overwritten.
	if FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target):
		var valid := not executable().is_empty()
		_release_lock()
		_set_state("ready" if valid else "error", "Secure credential helper is installed." if valid else "Cached helper bytes changed. They were preserved; remove the changed helper from the Orca user-data cache before retrying.")
		return valid
	var scratch := _lock.path_join("download.part")
	downloaded_bytes = 0
	_set_state("downloading", "Downloading secure credential helper from Orca's GitHub Release…")
	if _closed or generation != _generation:
		_release_lock()
		return false
	var url: String = DOWNLOAD_ROOT + "v" + version + "/" + entry["asset"]
	var result := await _download(url, scratch, int(entry["size"]))
	if generation != _generation or _closed:
		_release_lock()
		return false
	if not result:
		_release_lock()
		_set_state("error", "Secure connection preparation could not finish. Check your connection and try signing in again.")
		return false
	_set_state("verifying", "Verifying native helper size, SHA-256 and architecture…")
	if _closed or generation != _generation:
		_release_lock()
		return false
	if not verify_file(scratch, entry) or (OS.get_name() != "Windows" and FileAccess.set_unix_permissions(scratch, 448) != OK) or not Package.no_links(target) or FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target) or DirAccess.rename_absolute(scratch, target) != OK:
		_release_lock()
		_set_state("error", "Helper verification or installation failed. No unverified helper was enabled.")
		return false
	_release_lock()
	_set_state("ready", "Secure credential helper is installed.")
	return true


func _acquire_lock(directory: String) -> bool:
	var lock := directory.path_join("install-lock")
	if not Package.no_links(lock):
		return false
	if DirAccess.dir_exists_absolute(lock):
		var owner := Package.read_json(lock.path_join("owner.json"), 4096)
		if not _recognized_lock(lock, owner):
			return false
		if Package.process_alive(int(owner["pid"])):
			_waiting_for_install = true
			return false
		if FileAccess.file_exists(lock.path_join("download.part")):
			DirAccess.remove_absolute(lock.path_join("download.part"))
		if DirAccess.remove_absolute(lock.path_join("owner.json")) != OK or DirAccess.remove_absolute(lock) != OK:
			return false
	if DirAccess.make_dir_absolute(lock) != OK:
		return false
	_owner = {"pid": OS.get_process_id(), "token": Crypto.new().generate_random_bytes(16).hex_encode()}
	_lock = lock
	if not Package.write_json(lock.path_join("owner.json"), _owner):
		DirAccess.remove_absolute(lock)
		_lock = ""
		_owner.clear()
		return false
	return true


static func _recognized_lock(lock: String, owner: Dictionary) -> bool:
	if owner.size() != 2 or typeof(owner.get("pid")) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(owner["pid"])) or owner["pid"] <= 0 or owner["pid"] > 2147483647 or owner["pid"] != floorf(owner["pid"]) or typeof(owner.get("token")) != TYPE_STRING or owner["token"].length() != 32 or not owner["token"].is_valid_hex_number(false):
		return false
	var directory := DirAccess.open(lock)
	if directory == null:
		return false
	directory.include_hidden = true
	if not directory.get_directories().is_empty():
		return false
	for name in directory.get_files():
		var path := lock.path_join(name)
		if name not in ["owner.json", "download.part"] or not Package.no_links(path):
			return false
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null or file.get_length() > (4096 if name == "owner.json" else MAX_FILE):
			return false
	return true


func _release_lock() -> void:
	var saved := Package.read_json(_lock.path_join("owner.json"), 4096) if not _lock.is_empty() else {}
	if not _lock.is_empty() and Package.no_links(_lock) and _recognized_lock(_lock, saved) and int(saved["pid"]) == int(_owner.get("pid", -1)) and saved["token"] == _owner.get("token"):
		DirAccess.remove_absolute(_lock.path_join("download.part"))
		DirAccess.remove_absolute(_lock.path_join("owner.json"))
		DirAccess.remove_absolute(_lock)
	_lock = ""
	_owner.clear()


func _download(initial: String, destination: String, limit: int) -> bool:
	var url := initial
	var deadline := Time.get_ticks_msec() + 120000
	if _preparation_deadline > 0:
		deadline = mini(deadline, _preparation_deadline)
	for hop in 4:
		if _closed or Time.get_ticks_msec() >= deadline or not allowed_download_url(url, initial) or not Package.no_links(destination):
			return false
		var request := HTTPRequest.new()
		request.timeout = maxf(0.001, (deadline - Time.get_ticks_msec()) / 1000.0)
		request.body_size_limit = limit
		request.accept_gzip = false
		request.max_redirects = 0
		request.download_file = destination
		add_child(request)
		_request = request
		request.request_completed.connect(func(result, code, headers, body): _network_reply.emit([result, code, headers, body]), CONNECT_ONE_SHOT)
		if request.request(_transport_url(url), PackedStringArray(["User-Agent: Orca-Godot-Native-Helper", "Accept-Encoding: identity"])) != OK:
			_retryable_failure = true
			_request = null
			request.queue_free()
			return false
		set_process(true)
		var reply: Array = await _network_reply
		# Leave HTTPRequest's completion signal before callers can unload/free us.
		if not _closed:
			await get_tree().process_frame
		set_process(false)
		_request = null
		request.queue_free()
		if _closed or state != "downloading":
			return false
		if reply[1] in [301, 302, 303, 307, 308] and reply[0] in [HTTPRequest.RESULT_SUCCESS, HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED]:
			var location := ""
			for header in reply[2]:
				if str(header).to_lower().begins_with("location:"):
					if not location.is_empty():
						return false
					location = str(header).substr(9).strip_edges()
			url = location
			continue
		_retryable_failure = reply[0] in [HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_REQUEST_FAILED, HTTPRequest.RESULT_TIMEOUT] or (reply[0] == HTTPRequest.RESULT_SUCCESS and (reply[1] == 429 or reply[1] >= 500))
		return reply[0] == HTTPRequest.RESULT_SUCCESS and reply[1] == 200
	return false


static func allowed_download_url(url: String, initial: String) -> bool:
	if url == initial:
		return url.begins_with(DOWNLOAD_ROOT)
	return url.length() <= 8192 and url.begins_with("https://release-assets.githubusercontent.com/") and not url.contains("\r") and not url.contains("\n") and not url.contains("\\") and not url.contains("#") and not url.contains("@")


func _transport_url(url: String) -> String:
	return url


func _process(_delta: float) -> void:
	if _request != null:
		var count := _request.get_downloaded_bytes()
		if count != downloaded_bytes:
			downloaded_bytes = count
			changed.emit()


func cancel() -> void:
	_generation += 1
	_preparation_generation += 1
	var preparing := _preparing
	_preparing = false
	_preparation_deadline = 0
	var request := _request
	if state in ["downloading", "verifying", "waiting", "retrying"]:
		_set_state("missing", "Helper installation cancelled.")
	if request != null:
		request.cancel_request()
		_network_reply.emit([HTTPRequest.RESULT_REQUEST_FAILED, 0, PackedStringArray(), PackedByteArray()])
	_release_lock()
	set_process(false)
	if preparing:
		preparation_finished.emit(false)


func _exit_tree() -> void:
	_closed = true
	cancel()


func _set_state(next: String, message: String) -> void:
	state = next
	status = message
	changed.emit()
