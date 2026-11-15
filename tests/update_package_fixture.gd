extends SceneTree

const Package = preload("res://addons/orca/scripts/update_package.gd")
const Service = preload("res://addons/orca/scripts/update_service.gd")
var failures := 0

class FixtureService:
	extends Service
	var project := ""
	var origin := ""
	func _project_root() -> String: return project
	func _runner_root(_project: String) -> String: return project.path_join("runner")
	func _transport_url(url: String) -> String:
		if url == RELEASE_API: return origin + "/latest"
		if url.begins_with(DOWNLOAD_ROOT): return origin + "/download"
		return origin + "/cdn"

func _init() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func _run() -> void:
	var setup = JSON.parse_string(OS.read_string_from_stdin())
	if typeof(setup) != TYPE_DICTIONARY:
		quit(1)
		return
	var project: String = setup["project"]
	if setup.get("operation") in ["validate", "workspace-validation"]:
		var workspace := Package.owned_workspace(project, true)
		var result := Package.extract_archive(setup["archive"], workspace["root"].path_join("staged"), setup["version"], setup["digest"], "4.7.2")
		check(result.get("success", false), "actual installable addon package validates without executing its scripts")
		if setup.get("operation") == "workspace-validation":
			for path in ["blender/workspace_connector.py", "blender/workspace_contract.py"]:
				check(FileAccess.file_exists(workspace["root"].path_join("staged").path_join(path)), "workspace Python source survives production extraction")
			for index in setup["bad_archives"].size():
				var path: String = setup["bad_archives"][index]
				var bad: Dictionary = Package.extract_archive(path, workspace["root"].path_join("bad-%d" % index), setup["version"], FileAccess.get_sha256(path), "4.7.2")
				check(not bad.get("success", false) and str(bad.get("error", "")).contains("manifest"), "manifest-consistent but incomplete workspace archive is rejected")
		print("Repository update package: " + ("PASS" if failures == 0 else str(result)))
		quit(0 if failures == 0 else 1)
		return
	if setup.get("operation") in ["roundtrip", "download-failure", "cancel-download"]:
		var service := FixtureService.new()
		service.project = project
		service.origin = setup["origin"]
		root.add_child(service)
		service.installed_version = "1.3.0"
		await service.check_for_updates()
		check(service.state == "available", "real metadata transport")
		if setup.get("operation") in ["download-failure", "cancel-download"]:
			var before := Package.inspect_tree(project.path_join("addons/orca"))
			var result: Dictionary
			if setup.get("operation") == "cancel-download":
				var terminal := {"done": false, "result": {}}
				_collect_preparation(service, terminal)
				var deadline := Time.get_ticks_msec() + 10000
				while service.state != "downloading" and Time.get_ticks_msec() < deadline:
					await process_frame
				service.cancel()
				while not terminal["done"] and Time.get_ticks_msec() < deadline:
					await process_frame
				check(terminal["done"], "cancelled download continuation resolves")
				result = terminal["result"]
			else:
				result = await service.prepare_update()
			check(not result.get("success", false), "failed/cancelled download refuses installation")
			check(Package.inspect_tree(project.path_join("addons/orca"), before["hash"]).get("success", false), "failed download preserves installed bytes")
			check(service._installer.is_empty(), "failed download starts no independent installer")
			service.free()
			print("Update download failure: " + ("PASS" if failures == 0 else "FAIL"))
			quit(0 if failures == 0 else 1)
			return
		var prepared: Dictionary = await service.prepare_update()
		check(prepared.get("success", false), "real bounded download/redirect/checksum/extraction")
		if prepared.get("success", false):
			var launch: Dictionary = await service.launch_installer(prepared)
			check(launch.get("success", false), "independent installer verified READY")
			check(Package.inspect_tree(project.path_join("addons/orca"))["manifest"]["version"] == "1.3.0", "installer does not mutate while owner process is alive")
			if launch.get("success", false) and failures == 0:
				service.hand_off()
				quit(0)
				return
		print(service.status)
		service.free()
	else:
		var workspace := Package.owned_workspace(project, true)
		check(workspace.get("success", false), "isolated workspace")
		var stage: String = workspace["root"].path_join("staged")
		var good: Dictionary = Package.extract_archive(setup["archive"], stage, "1.4.0", setup["digest"], "4.7.2")
		check(good.get("success", false), "valid manifest/archive extraction")
		if good.get("success", false):
			var old := Package.inspect_tree(project.path_join("addons/orca"))
			check(old.get("success", false), "official installation matches manifest")
			check(not Package.install(project, "0".repeat(64), good["hash"]).get("success", false), "stale hash refuses replacement")
			var installed := Package.install(project, old["hash"], good["hash"])
			check(installed.get("success", false), "directory replacement completes")
			check(Package.inspect_tree(project.path_join("addons/orca"))["manifest"]["version"] == "1.4.0", "new release installed")
			check(Package.recover(project).get("success", false), "verified rollback completes")
			check(Package.inspect_tree(project.path_join("addons/orca"))["manifest"]["version"] == "1.3.0", "rollback restores original release")
			Package.remove_tree(stage)
			# Simulate interruption after the original directory move, before the
			# staged version is installed. The independent recovery path must work
			# even when addons/orca is temporarily absent.
			var target := project.path_join("addons/orca")
			var backup: String = workspace["root"].path_join("backup")
			check(Package.write_json(workspace["root"].path_join("transaction.json"), {"format": Package.FORMAT, "old_hash": old["hash"], "new_hash": good["hash"], "state": "prepared"}), "interrupted transaction recorded")
			check(DirAccess.rename_absolute(target, backup) == OK, "simulated original directory move")
			check(Package.recover(project).get("success", false) and DirAccess.dir_exists_absolute(target), "missing-addon interruption recovers the original")
			var lock := Package.acquire_lock(project, OS.get_process_id())
			check(lock.get("success", false), "exclusive preparation lock")
			check(not Package.acquire_lock(project, OS.get_process_id()).get("success", false), "second installer cannot steal a live lock")
			Package.release_lock(workspace["root"], OS.get_process_id())
			var restaged := Package.extract_archive(setup["archive"], stage, "1.4.0", setup["digest"], "4.7.2")
			check(restaged.get("success", false) and Package.install(project, old["hash"], good["hash"]).get("success", false), "prepare independent rollback-conflict controls")
			var backup_script := backup.path_join("orca.gd")
			var current_script := target.path_join("orca.gd")
			var previous_source := FileAccess.get_file_as_string(backup_script)
			var new_source := FileAccess.get_file_as_string(current_script)
			_write(backup_script, "owner changed rollback copy\n")
			check(not Package.recover(project).get("success", false) and Package.inspect_tree(target, good["hash"]).get("success", false), "modified backup blocks rollback and preserves current release")
			check(FileAccess.get_file_as_string(backup_script) == "owner changed rollback copy\n", "modified rollback bytes are preserved")
			_write(backup_script, previous_source)
			_write(current_script, "owner changed current addon\n")
			check(not Package.recover(project).get("success", false) and FileAccess.get_file_as_string(current_script) == "owner changed current addon\n", "modified current addon is never overwritten by rollback")
			_write(current_script, new_source)
			check(Package.recover(project).get("success", false), "unchanged copies permit rollback after conflict controls")
			Package.remove_tree(stage)
		for archive in setup.get("bad_archives", []):
			check(not Package.archive_index(archive).get("success", false), "malformed/traversing/oversized ZIP is rejected before decompression")
		check(not Package.extract_archive(setup["archive"], stage, "1.4.0", "0".repeat(64), "4.7.2").get("success", false), "wrong archive checksum refused")
		var changed := FileAccess.open(project.path_join("addons/orca/orca.gd"), FileAccess.WRITE)
		changed.store_string("user change\n")
		changed.close()
		check(not Package.inspect_tree(project.path_join("addons/orca")).get("success", false), "modified installation refused")
	print("Update package fixture: " + ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _collect_preparation(service, terminal: Dictionary) -> void:
	terminal["result"] = await service.prepare_update()
	terminal["done"] = true


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
