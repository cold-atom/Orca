extends SceneTree

const Store = preload("res://addons/orca/scripts/credential_store.gd")
const Helper = preload("res://addons/orca/scripts/native_helper_service.gd")

class FixtureHelper extends Helper:
	func cache_root() -> String:
		return OS.get_environment("ORCA_TEST_HELPER_CACHE")

func _new_store():
	var store := Store.new()
	store.helper_service = FixtureHelper.new()
	store.add_child(store.helper_service)
	return store

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var phase := OS.get_environment("ORCA_TEST_VAULT_PHASE")
	if not phase.is_empty():
		await _run_persistence(phase)
		return
	var store = _new_store()
	root.add_child(store)
	var scope := _test_scope()
	if not await store.acquire(scope):
		push_error("Could not acquire the native OS credential vault")
		quit(1)
		return
	var record := {"version": 1, "synthetic": true, "refresh_token": "fixture-only"}
	var before: Dictionary = await store.read_record()
	var saved: bool = await store.write_record(record)
	var restored: Dictionary = await store.read_record()
	var second = _new_store()
	root.add_child(second)
	var lock_state := {"acquired": false}
	_acquire_second(second, scope, lock_state)
	await create_timer(0.2).timeout
	var serialized: bool = not lock_state["acquired"]
	store.release()
	var deadline := Time.get_ticks_msec() + 10000
	while not lock_state["acquired"] and Time.get_ticks_msec() < deadline:
		await process_frame
	var shared: Dictionary = await second.read_record()
	var rotated: bool = await second.write_record({"version": 2, "synthetic": true})
	second.release()
	second.free()
	await store.acquire(scope)
	var latest: Dictionary = await store.read_record()
	var erased: bool = await store.erase()
	var after: Dictionary = await store.read_record()
	store.release()
	store.free()
	var canonical = JSON.parse_string(JSON.stringify(record))
	var ok: bool = before.get("success", false) and before.get("record", {}) == {} and saved and restored.get("record") == canonical and erased and after.get("record", {}) == {} and serialized and shared.get("record") == canonical and rotated and int(latest.get("record", {}).get("version", 0)) == 2
	if not ok:
		print("Vault checks (no credentials): read=%s empty=%s save=%s match=%s erase=%s cleared=%s serialized=%s acquired=%s rotated=%s" % [before.get("success", false), before.get("record", {}) == {}, saved, restored.get("record") == canonical, erased, after.get("record", {}) == {}, serialized, lock_state["acquired"], rotated])
	print("Native OS vault round-trip: " + ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _acquire_second(store, scope: String, state: Dictionary) -> void:
	state["acquired"] = await store.acquire(scope)


func _test_scope() -> String:
	var scope := OS.get_environment("ORCA_TEST_VAULT_SCOPE")
	return Crypto.new().generate_random_bytes(32).hex_encode() if scope.is_empty() else scope


func _run_persistence(phase: String) -> void:
	var scope := OS.get_environment("ORCA_TEST_VAULT_SCOPE")
	if scope.length() != 64 or phase not in ["save", "restore", "erase", "cleanup"]:
		quit(1)
		return
	var store = _new_store()
	root.add_child(store)
	if not await store.acquire(scope):
		store.free()
		quit(1)
		return
	var first := {"version": 1, "synthetic": true, "refresh_token": "fixture-only"}
	var rotated := {"version": 2, "synthetic": true}
	var record: Dictionary = await store.read_record()
	var ok := bool(record.get("success", false))
	match phase:
		"save":
			ok = ok and record.get("record", {}) == {} and await store.write_record(first)
		"restore":
			ok = ok and record.get("record", {}) == JSON.parse_string(JSON.stringify(first)) and await store.write_record(rotated)
		"erase":
			ok = ok and record.get("record", {}) == JSON.parse_string(JSON.stringify(rotated))
			var erased: bool = await store.erase()
			var after: Dictionary = await store.read_record()
			ok = ok and erased and after.get("success", false) and after.get("record", {}) == {}
		"cleanup":
			ok = await store.erase()
	store.free()
	print("Native OS vault persistence (%s): %s" % [phase, "PASS" if ok else "FAIL"])
	quit(0 if ok else 1)
