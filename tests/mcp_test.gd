extends SceneTree

const Service = preload("res://addons/orca/scripts/mcp_service.gd")
const Config = preload("res://addons/orca/scripts/mcp_config.gd")
const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
class StopFailure extends "res://addons/orca/scripts/mcp_stdio_client.gd":
	var deny_stop := true
	func _stop_process(pid: int) -> int:
		return ERR_BUSY if deny_stop else super._stop_process(pid)
class FixtureService extends "res://addons/orca/scripts/mcp_service.gd":
	func _fresh_registry() -> Dictionary:
		return _registry.duplicate(true)
var failures := 0
var service


func _init() -> void:
	call_deferred("_run")


func _config(mode: String = "normal", profile: String = "blender") -> Dictionary:
	return {"id": "fixture", "name": "Fixture", "command": "/usr/bin/python3", "arguments": [ProjectSettings.globalize_path("res://tests/mcp_fixture.py"), mode], "profile": profile}


func _connect(mode: String = "normal", profile: String = "blender") -> Dictionary:
	service.connections.assign([_config(mode, profile)])
	service._registry["connections"] = service.connections.duplicate(true)
	var action: Dictionary = service.prepare_launch(service.connections[0].duplicate(true))
	var result: Dictionary = await service.connect_server(action)
	if mode == "normal" and result.get("success", false):
		var pid: int = service._clients["fixture"]._child["pid"]
		_expect(not (await service.connect_server(action)).get("success", false) and service._clients["fixture"]._child["pid"] == pid, "one Enable action cannot be replayed or replace its process")
	return result


func _run() -> void:
	service = FixtureService.new()
	root.add_child(service)
	_expect(service.snapshot()["servers"].is_empty(), "startup never launches saved configurations")
	var config := _config()
	_expect(not Service._accepts_empty_arguments({"type": "object", "properties": "invalid"}), "malformed schemas cannot enable Blender calls")
	_expect(not Config.validate(config).is_empty(), "valid absolute executable and argument array")
	_expect(Config._entries([config, config], Config.MAX_REUSABLE).is_empty(), "duplicate reusable ids are invalid")
	_expect(Config._entries([config], 0).is_empty(), "reusable entry count is bounded")
	var wrong_root_record := {"version": 1, "root": "/different/project/", "connections": [config]}
	_expect(Config._project_entries(wrong_root_record, Config.project_root()).is_empty(), "legacy descriptions remain bound to their declared root")
	for invalid in [{}, {"id": "x"}, {"command": "python3"}, {"arguments": "--shell"}, {"profile": "execute"}, {"id": "../bad"}, {"name": "x\ny"}]:
		var changed := config.duplicate(true)
		changed.merge(invalid, true)
		if invalid.is_empty() or invalid == {"id": "x"}:
			continue
		_expect(Config.validate(changed).is_empty(), "reject invalid configuration " + str(invalid))
	var denied: Dictionary = await service.connect_server(service.prepare_launch(config))
	_expect(not denied["success"] and service._clients.is_empty(), "stale or unsaved launch consent cannot launch")
	var stopping := StopFailure.new()
	root.add_child(stopping)
	var stop_start: Dictionary = await stopping.connect_process(config["command"], config["arguments"])
	_expect(stop_start["success"], "retained-process stop fixture connects")
	var retained_pid: int = stopping._child.get("pid", 0)
	_expect(not stopping.close() and stopping.state == "stop_failed", "failed stop stays explicit")
	stop_start = await stopping.connect_process(config["command"], config["arguments"])
	_expect(not stop_start["success"] and stopping._child.get("pid") == retained_pid, "failed stop cannot lose PID or launch a replacement")
	stopping.deny_stop = false
	_expect(stopping.close(), "explicit stop retry releases the same bridge")
	stopping.queue_free()
	await _live_limit()
	var connected := await _connect()
	_expect(connected.get("success", false), "real stdio initialize/list/initialized: " + str(connected))
	var snapshot: Dictionary = service.snapshot()
	_expect(not Service.context(snapshot).contains(config["command"]) and not Service.context(snapshot).contains(Config.project_root()), "launch settings and local project binding stay out of MCP model context")
	var operations: Array = snapshot.get("servers", {}).get("fixture", {}).get("operations", [])
	_expect(operations.has("blender_scene") and operations.has("read_resource"), "explicit Blender and text contracts admitted")
	_expect(not operations.has("execute_blender_code"), "readOnlyHint cannot authorize arbitrary Python")
	_expect(not JSON.stringify(snapshot).contains("SECRET-SERVER-INSTRUCTION"), "server instructions excluded")
	var args := {"server_id": "fixture", "operation": "blender_scene"}
	denied = await service.inspect(snapshot, args, false)
	_expect(not denied["success"], "external calls require exact approval")
	var read: Dictionary = await service.inspect(snapshot, args, true)
	_expect(read.get("success", false) and str(read.get("content", "")).contains("café 木"), "fragmented UTF-8 tool result")
	read = await service.inspect(snapshot, {"server_id": "fixture", "operation": "read_resource", "uri": "fixture://guide"}, true)
	_expect(read.get("success", false), "listed text resource read")
	for bad in [{"server_id": "fixture", "operation": "execute_blender_code"}, {"server_id": "fixture", "operation": "read_resource", "uri": "file:///secret"}, {"server_id": "fixture", "operation": "blender_scene", "code": "evil"}]:
		_expect(not service.prepare_inspection(snapshot, bad)["success"], "reject unknown operation/URI/arguments")
	await _controller(snapshot, args)
	await _official_profile()
	service.disconnect_server("fixture")
	_expect(not service.prepare_inspection(snapshot, args)["success"], "disconnect revokes snapshots")
	for mode in ["bad_version", "wrong_id", "malformed", "invalid_utf8", "duplicate", "cursor"]:
		connected = await _connect(mode)
		_expect(not connected.get("success", false), "reject protocol failure: " + mode)
	connected = await _connect("required")
	_expect(connected.get("success", false) and not service.snapshot()["servers"]["fixture"]["operations"].has("blender_scene"), "incompatible schema cannot use fixed inspection")
	for mode in ["tool_error", "binary", "changed", "exit", "flood"]:
		connected = await _connect(mode)
		_expect(connected.get("success", false), "failure fixture connects: " + mode)
		read = await service.inspect(service.snapshot(), args, true)
		_expect(not read.get("success", false), "bounded failed read: " + mode)
	connected = await _connect("server_request")
	read = await service.inspect(service.snapshot(), args, true)
	_expect(read.get("success", false), "unsupported server roots/sampling requests disclose no client context")
	connected = await _connect("hang")
	create_timer(0.1).timeout.connect(service.cancel_active_reads)
	var start := Time.get_ticks_msec()
	read = await service.inspect(service.snapshot(), args, true)
	_expect(not read["success"] and Time.get_ticks_msec() - start < 2000, "Stop interrupts a hung read without replay")
	connected = await _connect("timeout")
	start = Time.get_ticks_msec()
	read = await service.inspect(service.snapshot(), args, true)
	_expect(not read["success"] and Time.get_ticks_msec() - start >= 29000 and Time.get_ticks_msec() - start < 32000, "absolute request deadline")
	service.shutdown()
	service.queue_free()
	await process_frame
	print("mcp_test: %d failures" % failures)
	quit(1 if failures else 0)


func _live_limit() -> void:
	var bounded := FixtureService.new()
	root.add_child(bounded)
	var entries: Array[Dictionary] = []
	for index in 5:
		var config := _config("normal", "resources")
		config["id"] = "limit_%d" % index
		config["name"] = "Limit %d" % index
		entries.append(config)
	bounded.connections.assign(entries)
	bounded._registry["connections"] = entries.duplicate(true)
	for index in 4:
		var result: Dictionary = await bounded.connect_server(bounded.prepare_launch(entries[index]))
		_expect(result.get("success", false), "live-limit fixture explicitly enables owned bridge")
	var blocked: Dictionary = await bounded.connect_server(bounded.prepare_launch(entries[4]))
	_expect(not blocked.get("success", false) and bounded._clients.size() == 4, "canonical setup can exceed four descriptions but cannot start a fifth bridge")
	bounded.shutdown()
	bounded.queue_free()
	await process_frame


func _official_profile() -> void:
	_expect(not Config.validate(_config("lab", "blender_lab")).is_empty(), "official profile is a valid explicit configuration")
	for profiles in [["lab", "blender"], ["normal", "blender_lab"], ["lab", "resources"]]:
		var connected := await _connect(profiles[0], profiles[1])
		var catalog: Dictionary = service.snapshot()["servers"]["fixture"]
		_expect(connected.get("success", false) and not catalog["operations"].has("blender_scene") and not catalog["operations"].has("blender_status"), "no cross-profile inference: " + str(profiles))
	var connected := await _connect("lab_mixed", "blender_lab")
	_expect(connected.get("success", false), "official/mixed catalog connects")
	var snapshot: Dictionary = service.snapshot()
	var catalog: Dictionary = snapshot["servers"]["fixture"]
	_expect(catalog["inspection_tools"] == Service.PROFILE_READS["blender_lab"], "only exact official tools are bound even in a mixed catalog")
	_expect(Service.context(snapshot).contains("get_objects_summary") and Service.context(snapshot).contains("get_blendfile_summary_datablocks"), "model context distinguishes official scene and data-block summary")
	var scene_args := {"server_id": "fixture", "operation": "blender_scene"}
	var prepared: Dictionary = service.prepare_inspection(snapshot, scene_args)
	_expect(prepared.get("tool_name") == "get_objects_summary" and prepared.get("profile") == "blender_lab", "review discloses exact official profile and tool")
	var tampered := snapshot.duplicate(true)
	tampered["servers"]["fixture"]["inspection_tools"]["blender_scene"] = "execute_blender_code"
	_expect(not service.prepare_inspection(tampered, scene_args)["success"], "snapshot tool tampering cannot grant dispatch")
	var denied: Dictionary = await service.inspect(snapshot, scene_args, false)
	_expect(not denied["success"], "official read still requires approval")
	for operation in ["blender_scene", "blender_status"]:
		var read: Dictionary = await service.inspect(snapshot, {"server_id": "fixture", "operation": operation}, true)
		var data = JSON.parse_string(read.get("content", ""))
		_expect(read.get("success", false) and typeof(data) == TYPE_DICTIONARY and data.get("status") == "ok", "official structured/text JSON normalization: " + operation)
		if typeof(data) == TYPE_DICTIONARY:
			_expect(data.has("collections") if operation == "blender_scene" else data.get("datablock_counts", {}).get("objects") == 3, "profile-specific summary dispatch: " + operation)
	for extra in [{"tool_name": "execute_blender_code"}, {"profile": "blender"}, {"code": "evil"}]:
		var args := scene_args.duplicate(true)
		args.merge(extra)
		_expect(not service.prepare_inspection(snapshot, args)["success"], "model cannot override official dispatch " + str(extra))
	await _controller(snapshot, scene_args)
	connected = await _connect("lab_required", "blender_lab")
	_expect(connected.get("success", false) and not service.snapshot()["servers"]["fixture"]["operations"].has("blender_scene"), "required arguments deny official scene read independently of summary")
	_expect(service.snapshot()["servers"]["fixture"]["operations"].has("blender_status"), "compatible official summary remains available")
	for mode in ["lab_tool_error", "lab_binary", "lab_changed", "lab_exit", "lab_flood"]:
		connected = await _connect(mode, "blender_lab")
		var read: Dictionary = await service.inspect(service.snapshot(), scene_args, true)
		_expect(connected.get("success", false) and not read.get("success", false), "official failed read: " + mode)
	connected = await _connect("lab_hang", "blender_lab")
	create_timer(0.1).timeout.connect(service.cancel_active_reads)
	var started := Time.get_ticks_msec()
	var cancelled: Dictionary = await service.inspect(service.snapshot(), scene_args, true)
	_expect(not cancelled["success"] and Time.get_ticks_msec() - started < 2000, "Stop interrupts an in-flight official inspection")
	connected = await _connect("lab_mixed", "blender")
	_expect(service.snapshot()["servers"]["fixture"]["inspection_tools"] == Service.PROFILE_READS["blender"], "legacy saved profile keeps community dispatch")
	_expect(not service.prepare_inspection(snapshot, scene_args)["success"], "profile replacement invalidates official turn snapshot")


func _controller(snapshot: Dictionary, args: Dictionary) -> void:
	var controller := Controller.new()
	root.add_child(controller)
	controller.mcp_service = service
	controller.script_change_writer = func(_record): return true
	_expect(controller.set_auto_apply_enabled(true), "fixture enables script Auto apply before starting a turn")
	controller._turn_mcp_snapshot = snapshot.duplicate(true)
	controller._active_turn_id = 11
	controller._is_running = true
	controller._mode = Controller.AgentMode.PLAN
	var result: Dictionary = await controller._inspect_mcp(args, "read1", 11, Controller.AgentMode.PLAN)
	_expect(not result["success"], "runtime Plan denial")
	controller._mode = Controller.AgentMode.BUILD
	var batch := [{"function": {"name": "inspect_mcp", "arguments": JSON.stringify(args)}}, {"function": {"name": "read_file", "arguments": "{}"}}]
	_expect(not controller._validate_tool_batch(batch)["success"], "external inspection cannot join a multi-call batch")
	controller.mcp_read_requested.connect(func(turn_id: int, request: Dictionary):
		controller.resolve_mcp_read("stale", turn_id, true)
		_expect(not controller._mcp_read_decided, "stale call cannot grant approval")
		controller.resolve_mcp_read(request["call_id"], turn_id, false)
	, CONNECT_ONE_SHOT)
	result = await controller._inspect_mcp(args, "read2", 11, Controller.AgentMode.BUILD)
	_expect(result["outcome"] == "rejected", "user rejection")
	controller.mcp_read_requested.connect(func(turn_id: int, request: Dictionary): controller.resolve_mcp_read(request["call_id"], turn_id, true), CONNECT_ONE_SHOT)
	result = await controller._execute_tool_call({"id": "read3", "function": {"name": "inspect_mcp", "arguments": JSON.stringify(args)}}, 11)
	_expect(result["outcome"] == "completed" and result["call_id"] == "read3", "approved read returns exact provider call receipt")
	controller.mcp_read_requested.connect(func(_turn_id: int, _request: Dictionary): controller.cancel_current_request(), CONNECT_ONE_SHOT)
	result = await controller._inspect_mcp(args, "read4", 11, Controller.AgentMode.BUILD)
	_expect(result["outcome"] == "cancelled", "Stop during exact review")
	controller._is_running = true
	controller._active_turn_id = 12
	controller._cancel_requested = false
	controller._turn_mcp_snapshot = service.snapshot()
	controller.mcp_read_requested.connect(func(turn_id: int, request: Dictionary):
		service.disconnect_server("fixture")
		controller.resolve_mcp_read(request["call_id"], turn_id, true)
	, CONNECT_ONE_SHOT)
	result = await controller._inspect_mcp(args, "stale_read", 12, Controller.AgentMode.BUILD)
	_expect(not result["success"] and result["content"].contains("changed"), "disconnect during review invalidates approval before dispatch")
	controller._turn_provider_config = {"provider": "orca_cloud", "hosted_mcp_inspection": true}
	_expect(not controller._turn_allows_mcp(), "Cloud advertisement alone cannot grant managed tools")
	controller._is_running = false
	controller.queue_free()
	await process_frame


func _expect(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		printerr("mcp_test: ", message)
