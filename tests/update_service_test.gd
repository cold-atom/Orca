extends SceneTree

const Service = preload("res://addons/orca/scripts/update_service.gd")
const Package = preload("res://addons/orca/scripts/update_package.gd")
var failures := 0

class FixtureService:
	extends Service
	var preferences := {}
	var response := {}
	var requests := 0
	var delay := 1
	func _setting(key: String, fallback): return preferences.get(key, fallback)
	func _save_setting(key: String, value) -> void: preferences[key] = value
	func _fetch(_url: String, _limit: int, _destination: String = "", _downloads: bool = false) -> Dictionary:
		requests += 1
		for frame in delay:
			await get_tree().process_frame
		return {"success": true, "bytes": JSON.stringify(response).to_utf8_buffer()}

func _init() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func release(version: String = "1.4.0") -> Dictionary:
	return {"draft": false, "prerelease": false, "tag_name": "v" + version, "assets": [{"name": "orca-v" + version + ".zip", "browser_download_url": Service.DOWNLOAD_ROOT + "v" + version + "/orca-v" + version + ".zip", "size": 1234, "digest": "sha256:" + "a".repeat(64)}]}

func _run() -> void:
	check(Package.compare_versions("1.10.0", "1.9.0") == 1, "versions compare numerically")
	for invalid in ["1.4", "01.4.0", "1.4.0-beta", "v1.4.0", "1.4.0.0", "1.-1.0"]:
		check(Package.version_parts(invalid).is_empty(), "malformed/prerelease versions rejected")
	var normalized := Service.normalize_release(release(), "1.3.0")
	check(normalized.get("success", false) and normalized["release"]["version"] == "1.4.0", "new official stable asset accepted")
	for installed in ["1.3.0", "1.4.0"]:
		var patch := Service.normalize_release(release("1.4.1"), installed)
		check(patch.get("success", false) and patch.get("release", {}).get("version") == "1.4.1", "packaging follow-up is newer than installed " + installed)
	check(Service.normalize_release(release("1.4.1"), "1.4.1").get("release", {"bad": true}).is_empty(), "installed packaging follow-up gives no update")
	check(Service.normalize_release(release("1.3.0"), "1.3.0").get("release", {"bad": true}).is_empty(), "same version gives no update")
	check(Service.normalize_release(release("1.2.0"), "1.3.0").get("release", {"bad": true}).is_empty(), "older release never downgrades")
	for field in ["draft", "prerelease"]:
		var bad := release()
		bad[field] = true
		check(not Service.normalize_release(bad, "1.3.0").get("success", false), "draft/prerelease refused")
	for field in ["browser_download_url", "digest", "size"]:
		var bad := release()
		bad["assets"][0][field] = {"browser_download_url": "https://attacker.example/orca.zip", "digest": "", "size": Package.MAX_ARCHIVE + 1}[field]
		check(not Service.normalize_release(bad, "1.3.0").get("success", false), "invalid asset URL/checksum/size refused")
	var duplicate := release()
	duplicate["assets"].append(duplicate["assets"][0].duplicate(true))
	check(not Service.normalize_release(duplicate, "1.3.0").get("success", false), "duplicate update asset refused")
	var initial: String = normalized["release"]["url"]
	check(Service.allowed_download_url("https://release-assets.githubusercontent.com/github-production-release-asset/file?sig=value", initial), "fixed GitHub release CDN accepted")
	for url in ["http://release-assets.githubusercontent.com/file", "https://release-assets.githubusercontent.com.attacker.example/file", "https://github.com/other/release.zip", "https://user@release-assets.githubusercontent.com/file", "https://release-assets.githubusercontent.com/file#fragment"]:
		check(not Service.allowed_download_url(url, initial), "redirect origin/downgrade rejected")
	var service := FixtureService.new()
	root.add_child(service)
	service.installed_version = "1.3.0"
	service.response = release()
	await service.check_for_updates()
	check(service.state == "available" and service.requests == 1, "bounded check discovers update")
	service.dismiss()
	check(service.dismissed(), "Later persists dismissal for exact version")
	service.release["version"] = "1.5.0"
	check(not service.dismissed(), "newer version is not suppressed by old dismissal")
	service.release = normalized["release"]
	service.delay = 3
	service.check_for_updates()
	service.cancel()
	for frame in 5:
		await process_frame
	check(service.state == "available" and service.release["version"] == "1.4.0", "cancelled checks cannot apply stale results")
	service.set_automatic_checks(false)
	check(not service.automatic_checks(), "automatic-check preference is explicit")
	var disabled := OS.get_environment("ORCA_DISABLE_UPDATE_CHECKS")
	OS.set_environment("ORCA_DISABLE_UPDATE_CHECKS", "")
	service._automatic_check()
	check(service.requests == 2, "disabled automatic checks do not send requests")
	service.set_automatic_checks(true)
	service._automatic_check()
	check(service.requests == 2, "recent check is rate-limited for one day")
	OS.set_environment("ORCA_DISABLE_UPDATE_CHECKS", disabled)
	service.free()
	print("Update service: " + ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
