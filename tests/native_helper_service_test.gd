extends SceneTree

const Helper = preload("res://addons/orca/scripts/native_helper_service.gd")
var failures := 0

class DeadlineHelper extends Helper:
	var waiting := false
	func _ready() -> void: entry = {"fixture": true}
	func executable() -> String: return ""
	func _install_once() -> bool:
		_preparation_deadline = Time.get_ticks_msec() + 20
		_waiting_for_install = waiting
		_retryable_failure = not waiting
		_set_state("waiting" if waiting else "error", "Fixture preparation pending.")
		return false

func _init() -> void: call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func _run() -> void:
	var helpers := []
	for platform in Helper.PLATFORMS:
		for architecture in Helper.PLATFORMS[platform]:
			var bytes := PackedByteArray()
			bytes.resize(128)
			match platform:
				"linux":
					bytes[0] = 127
					bytes[1] = 69
					bytes[2] = 76
					bytes[3] = 70
					bytes[4] = 2
					bytes[5] = 1
					bytes.encode_u16(16, 2)
					bytes.encode_u16(18, 62)
				"windows":
					bytes[0] = 77
					bytes[1] = 90
					bytes.encode_u32(60, 64)
					bytes[64] = 80
					bytes[65] = 69
					bytes.encode_u16(68, 0x8664)
				"macos":
					bytes[0] = 207
					bytes[1] = 250
					bytes[2] = 237
					bytes[3] = 254
					bytes.encode_u32(4, 0x100000c if architecture == "arm64" else 0x1000007)
					bytes.encode_u32(12, 2)
			var hash := HashingContext.new()
			hash.start(HashingContext.HASH_SHA256)
			hash.update(bytes)
			var item := {"platform": platform, "architecture": architecture, "asset": "credential_helper_%s.%s%s" % [platform, architecture, ".exe" if platform == "windows" else ""], "size": bytes.size(), "sha256": hash.finish().hex_encode()}
			helpers.append(item)
			check(Helper.valid_native_header(bytes, item), "correct native architecture accepted: " + item["asset"])
			check(not Helper.valid_native_header(bytes.slice(0, 63), item), "truncated header rejected")
			bytes[0] = 0
			check(not Helper.valid_native_header(bytes, item), "wrong native header rejected")
	var catalog := {"format": Helper.FORMAT, "version": "1.4.0", "helpers": helpers}
	check(Helper.normalize_catalog(catalog, "1.4.0").get("success", false), "four supported platforms accepted")
	check(not Helper.normalize_catalog(catalog, "1.4.1").get("success", false), "catalog must match installed plugin version")
	for field in ["asset", "size", "sha256", "architecture", "platform", "extra"]:
		var changed := catalog.duplicate(true)
		var item: Dictionary = changed["helpers"][0]
		match field:
			"size": item[field] = Helper.MAX_FILE + 1
			"sha256": item[field] = "F".repeat(64)
			"architecture": item[field] = "arm64"
			"platform": item[field] = "other"
			_: item[field] = "../../untrusted"
		check(not Helper.normalize_catalog(changed, "1.4.0").get("success", false), "malformed helper field rejected: " + field)
	var duplicate := catalog.duplicate(true)
	duplicate["helpers"][1] = duplicate["helpers"][0].duplicate(true)
	check(not Helper.normalize_catalog(duplicate, "1.4.0").get("success", false), "duplicate platform asset rejected")
	var initial := Helper.DOWNLOAD_ROOT + "v1.4.0/credential_helper_linux.x86_64"
	check(Helper.allowed_download_url(initial, initial), "official initial asset accepted")
	check(Helper.allowed_download_url("https://release-assets.githubusercontent.com/example?token=public", initial), "official GitHub asset redirect accepted")
	for url in ["http://release-assets.githubusercontent.com/a", "https://release-assets.githubusercontent.com.attacker.example/a", "https://github.com/other/project/a", "https://release-assets.githubusercontent.com/a\r\nAuthorization: secret", "https://release-assets.githubusercontent.com/a#fragment"]:
		check(not Helper.allowed_download_url(url, initial), "wrong/malformed redirect denied")
	for waiting in [true, false]:
		var pending := DeadlineHelper.new()
		pending.waiting = waiting
		root.add_child(pending)
		var started := Time.get_ticks_msec()
		check(not await pending.prepare(), "preparation deadline bounds lock/retry waits")
		check(Time.get_ticks_msec() - started < 500 and not pending.busy(), "deadline resolves waiters without a long backoff")
		pending.free()
	var cancelled := DeadlineHelper.new()
	root.add_child(cancelled)
	cancelled.changed.connect(func():
		if cancelled.state == "retrying": cancelled.cancel())
	check(not await cancelled.prepare() and not cancelled.busy(), "cancellation at retry state settles preparation")
	cancelled.free()
	print("Native helper catalog/header tests: " + ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
