extends SceneTree

const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var probe := Probe.new()
	get_root().add_child(probe)
	var result: Dictionary = {}
	probe.probe_passed.connect(func(binding: Dictionary): result.merge({"kind": "passed", "binding": binding}, true))
	probe.probe_failed.connect(func(_binding: Dictionary, message: String): result.merge({"kind": "failed", "message": message}, true))
	_expect(probe.start_probe({"provider": "ollama", "base_url": "http://127.0.0.1:18473/probe", "api_key": "", "model": "probe-model", "reasoning_effort": "default", "confirmed_origin": ""}), "localhost probe should start")
	var deadline := Time.get_ticks_msec() + 15000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(result.get("kind") == "passed", "two-step localhost compatibility probe should pass: " + str(result))
	_expect(result.get("binding", {}).get("origin") == "http://127.0.0.1:18473" and result.get("binding", {}).get("model") == "probe-model", "probe result should retain the exact normalized binding")
	probe.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("agent_compatibility_probe_integration_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("agent_compatibility_probe_integration_test: ", failure)
	quit(1)
