extends SceneTree

const Helper = preload("res://addons/orca/scripts/native_helper_service.gd")
const Account = preload("res://addons/orca/scripts/account_service.gd")
const Cloud = preload("res://addons/orca/scripts/providers/orca_cloud_provider.gd")

class FixtureHelper extends Helper:
	var directory := ""
	var server := ""
	var automatic := true
	func _ready() -> void:
		set_process(false)
		if automatic: call_deferred("_automatic_startup")
	func automatic_downloads_enabled() -> bool: return automatic
	func cache_root() -> String: return directory
	func _transport_url(url: String) -> String:
		return server + ("/redirect-target" if url.begins_with("https://release-assets.githubusercontent.com/") else "/download")

class FixtureAccount extends Account:
	var calls: Array[String] = []
	func _ready() -> void: pass
	func _request(path: String, _method: int, _body: Dictionary = {}, _token: String = "") -> Dictionary:
		calls.append(path)
		await get_tree().process_frame
		match path:
			"/v1/auth/token/refresh":
				return {"success": true, "body": {"access_token": "fixture-access", "refresh_token": "fixture-rotated", "token_type": "Bearer", "expires_in": 900, "session_id": "fixture-session"}}
			"/v1/account":
				return {"success": true, "body": {"account": {"id": "fixture-account", "display_name": "Fixture"}}}
			"/v1/models":
				return {"success": true, "body": {"data": []}}
		return {"success": false}

class FixtureVault extends RefCounted:
	var helper
	var record := {}
	var reads := 0
	func available() -> bool: return not helper.executable().is_empty()
	func acquire(_scope: String) -> bool: return available()
	func read_record() -> Dictionary:
		reads += 1
		return {"success": true, "record": record.duplicate(true)}
	func write_record(value: Dictionary) -> bool:
		record = value.duplicate(true)
		return true
	func erase() -> bool:
		record.clear()
		return true
	func release() -> void: pass

var failures := 0

func _init() -> void: call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func _run() -> void:
	var args = JSON.parse_string(OS.read_string_from_stdin())
	var catalog: Dictionary = args["catalog"]
	check(Helper.normalize_catalog(catalog, "1.4.0").get("success", false), "fixture catalog accepted")
	var kind: String = args["kind"]
	var helper := FixtureHelper.new()
	helper.directory = args["cache"]
	helper.server = args["server"]
	helper.entry = catalog["helpers"][0].duplicate(true)
	helper.version = "1.4.0"
	helper.automatic = kind not in ["suppressed", "cancel_before_download"]
	root.add_child(helper)
	var account := FixtureAccount.new()
	account.native_helper = helper
	account._vault = FixtureVault.new()
	account._vault.helper = helper
	helper.changed.connect(account._on_native_helper_changed)
	root.add_child(account)
	check(account.calls.is_empty() and not helper.busy(), "construction never initiates authentication")
	if kind == "cancel_before_download":
		helper.changed.connect(func():
			if helper.state == "downloading": helper.cancel())
	if kind == "cancel_before_auth":
		helper.changed.connect(func():
			if helper.state == "ready": account.cancel_pairing())
	if kind == "suppressed":
		for frame in 5: await process_frame
		check(not helper.busy() and helper.executable().is_empty() and account.calls.is_empty(), "suppressed startup downloads nothing")
	elif kind == "background":
		await process_frame
		check(helper.busy(), "first startup prepares helper automatically")
		check(await helper.prepare(), "startup completes verified preparation")
		check(account.calls.is_empty(), "background completion never starts browser sign-in")
	elif kind in ["restore", "startup_cancelled", "restore_missing"]:
		if kind != "restore_missing":
			account._vault.record = {"version": 1, "origin": Cloud.ORIGIN, "refresh_token": "fixture-saved", "session_id": "fixture-session"}
		account._startup_restore_pending = true
		var restored := {}
		_collect_restore(account, restored)
		if kind == "startup_cancelled": await account.cancel_pairing()
		while not restored.has("done"): await process_frame
		check(not account._startup_restore_pending, "startup restoration settles once")
		if kind == "restore":
			check(account.connected() and account.calls == ["/v1/auth/token/refresh", "/v1/account", "/v1/models"], "saved account restores after helper without browser pairing")
			await account._restore_after_helper(account._generation)
			check(account.calls.size() == 3, "ready signals cannot restore connected account twice")
		else:
			check(account.calls.is_empty() and not account.connected(), "missing/cancelled startup has no authentication")
			if kind == "startup_cancelled": check(account._vault.reads == 0, "cancelled startup never reads saved credentials")
	elif kind == "lock":
		var results := {}
		_collect_prepare(helper, results, "one")
		await create_timer(0.05).timeout
		var other := FixtureHelper.new()
		other.automatic = false
		other.directory = helper.directory
		other.server = helper.server
		other.entry = helper.entry.duplicate(true)
		other.version = helper.version
		root.add_child(other)
		_collect_prepare(other, results, "two")
		check(other.state == "waiting", "another editor waits for the live hash lock")
		while results.size() < 2: await process_frame
		check(results["one"] and results["two"], "both editors reuse the single verified installation")
		other.queue_free()
	elif kind in ["cancel", "shutdown", "teardown"]:
		account.begin_pairing()
		var deadline := Time.get_ticks_msec() + 3000
		while helper._request != null and helper._request.get_http_client_status() != HTTPClient.STATUS_BODY and Time.get_ticks_msec() < deadline: await process_frame
		check(helper._request != null, "fixture reaches active background download")
		if kind == "teardown":
			var target := helper._target()
			account.queue_free()
			helper.queue_free()
			for frame in 5: await process_frame
			check(not FileAccess.file_exists(target) and not DirAccess.dir_exists_absolute(target.get_base_dir().path_join("install-lock")), "teardown removes its partial and lock")
			_finish()
			return
		if kind == "shutdown": helper.cancel()
		else:
			await account.cancel_pairing()
			check(helper.busy(), "cancelling sign-in leaves background preparation running")
			check(await helper.prepare(), "background preparation survives sign-in cancellation")
		for frame in 5: await process_frame
		check(account.calls.is_empty(), "cancelled sign-in never resumes authentication")
		check((not helper.executable().is_empty()) == (kind == "cancel"), "only sign-in cancellation retains successful preparation")
	elif kind == "retry_signin":
		check(not await helper.prepare(), "background retries are bounded")
		check(account.calls.is_empty() and account.status == "Sign in to use Orca-hosted models.", "background failure stays quiet")
		await account.begin_pairing()
		check(account.calls == ["/v1/auth/device/code"], "normal Sign in retries failed helper preparation")
	else:
		# A click during startup shares preparation; repeated clicks coalesce.
		account.begin_pairing()
		account.begin_pairing()
		var deadline := Time.get_ticks_msec() + 12000
		while account.state == "connecting" and Time.get_ticks_msec() < deadline: await process_frame
		var success := kind in ["success", "redirect", "cached", "retry", "cancel_before_auth"]
		check((not helper.executable().is_empty()) == success, "only verified preparation becomes executable")
		check(account.calls.size() == (1 if success and kind != "cancel_before_auth" else 0), "only surviving explicit sign-in proceeds once")
		if kind in ["success", "redirect"]:
			var bytes := FileAccess.get_file_as_bytes(helper.executable())
			var file := FileAccess.open(helper.executable(), FileAccess.WRITE)
			file.store_buffer(bytes + PackedByteArray([1]))
			file.close()
			check(helper.executable().is_empty(), "changed cached bytes cannot execute")
			check(not await helper.prepare(), "changed cache is never overwritten or retried")
	check(not DirAccess.dir_exists_absolute(helper._target().get_base_dir().path_join("install-lock")), "completed preparation releases its lock")
	account.queue_free()
	helper.queue_free()
	for frame in 3: await process_frame
	_finish()

func _finish() -> void:
	print("Native helper background/account fixture: " + ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _collect_prepare(helper, results: Dictionary, key: String) -> void:
	results[key] = await helper.prepare()

func _collect_restore(account, results: Dictionary) -> void:
	await account._restore_after_helper(account._generation)
	results["done"] = true
