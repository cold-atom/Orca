@tool
extends "res://addons/orca/scripts/blender_workspace_service.gd"

## Reuses only reviewed artifact handoff and command validation. No workspace startup.
const LIVE_SCRIPT := "res://addons/orca/blender/live_session.py"
const LIVE_COMMANDS := ["primitive", "mesh", "transform", "mesh_edit", "delete", "duplicate", "collider", "lod", "rigid_body", "cloth", "join", "modifier", "material", "texture", "bake", "uv_unwrap", "armature", "skin", "constraint", "keyframes", "bake_animation", "shape_key", "geometry_nodes", "curve", "light", "camera"]
var server_id := ""
var server_name := ""
var token := ""
var dispatch_code: Callable
var _authorization: Callable
var _executing := false
var _object_selection: Array = []
var latest_checkpoint := {}


func automation_binding() -> Dictionary:
	if state != "connected" or _current_script_hashes() != _script_hashes: return {}
	return {"root": ProjectSettings.globalize_path("res://").simplify_path(), "instance_id": get_instance_id(), "token": token, "generation": _generation, "workspace": workspace, "hashes": _script_hashes.duplicate(true)}


func _ready() -> void:
	pass # Loading/restoring this service never creates a process or permission.


func _current_script_hashes() -> Dictionary:
	var hashes := super._current_script_hashes()
	if hashes.is_empty() or not Paths.no_links(ProjectSettings.globalize_path(LIVE_SCRIPT)): return {}
	var file := FileAccess.open(LIVE_SCRIPT, FileAccess.READ)
	if file == null or file.get_length() == 0 or file.get_length() > 1024 * 1024: return {}
	hashes[LIVE_SCRIPT] = FileAccess.get_sha256(LIVE_SCRIPT)
	var worker := "res://addons/orca/blender/live_export.py"
	if not Paths.no_links(ProjectSettings.globalize_path(worker)): return {}
	var worker_file := FileAccess.open(worker, FileAccess.READ)
	if worker_file == null or worker_file.get_length() == 0 or worker_file.get_length() > 1024 * 1024: return {}
	hashes[worker] = FileAccess.get_sha256(worker)
	return hashes


func begin(send: Callable, authorized: Callable, previous_token: String = "") -> Dictionary:
	if not send.is_valid() or not authorized.is_valid() or not authorized.call(): return failure("Enable live authoring explicitly in idle Work mode.")
	_script_hashes = _current_script_hashes()
	if _script_hashes.is_empty(): return failure("The shipped live-authoring helper is missing or unreadable. Reinstall the complete Orca plugin.")
	token = Crypto.new().generate_random_bytes(16).hex_encode()
	workspace = cache_root().path_join("live-" + token)
	if not Paths.no_links(workspace) or DirAccess.make_dir_recursive_absolute(workspace) != OK: return failure("The private live-authoring cache is unavailable.")
	dispatch_code = send
	var hashes := {}
	for path in _script_hashes: hashes[str(path).get_file()] = _script_hashes[path]
	var code := "import sys, types, hashlib\n"
	if not previous_token.is_empty():
		code += "_old = sys.modules.pop(%s, None)\nif _old is not None: _old.close()\n" % JSON.stringify("_orca_live_" + previous_token)
	code += "_p = %s\nwith open(_p, 'rb') as _f: _b = _f.read(1048577)\nif hashlib.sha256(_b).hexdigest() != %s: raise ValueError('The shipped helper changed')\n_m = types.ModuleType(%s)\n_m.__file__ = _p\nexec(compile(_b, _p, 'exec'), _m.__dict__)\ntry:\n result = _m.start(%s, %s, %s)\n sys.modules[_m.__name__] = _m\nexcept Exception as _e:\n _m.close()\n result = {'ok': False, 'message': str(_e)[:240] if isinstance(_e, ValueError) else 'Live-authoring setup failed'}\n" % [JSON.stringify(ProjectSettings.globalize_path(LIVE_SCRIPT)), JSON.stringify(_script_hashes[LIVE_SCRIPT]), JSON.stringify("_orca_live_" + token), JSON.stringify(workspace), JSON.stringify(token), JSON.stringify(hashes)]
	_executing = true
	var response: Dictionary = await dispatch_code.call(code)
	_executing = false
	if not authorized.call() or _current_script_hashes() != _script_hashes: return failure("Live-authoring setup was interrupted or changed. Enable again explicitly.")
	var parsed := decode(response)
	if not parsed.get("success", false): return parsed
	var data: Dictionary = parsed["data"]
	if data.get("catalog_sha256") != COMMAND_CONTRACT_SHA256 or typeof(data.get("data")) != TYPE_DICTIONARY or not _valid_current(data["data"]): return failure("The live Blender helper returned an incompatible command/session contract.")
	_executing = true
	var catalog_response: Dictionary = await dispatch_code.call("import sys\n_m = sys.modules.get(%s)\nresult = _m.command_catalog() if _m is not None else {'ok': False}\n" % JSON.stringify("_orca_live_" + token))
	_executing = false
	if not authorized.call() or _current_script_hashes() != _script_hashes: return failure("Live-authoring setup was interrupted or changed. Enable again explicitly.")
	var catalog_result := decode(catalog_response)
	if not catalog_result.get("success", false): return catalog_result
	var encoded = catalog_result["data"].get("catalog_json")
	if typeof(encoded) != TYPE_STRING or encoded.sha256_text() != COMMAND_CONTRACT_SHA256: return failure("The live command catalog does not match the shipped contract.")
	var catalog_value = JSON.parse_string(encoded)
	if typeof(catalog_value) != TYPE_DICTIONARY: return failure("Invalid live command catalog.")
	capabilities.clear()
	for name in LIVE_COMMANDS:
		if not catalog_value.has(name): return failure("A required live command is unavailable.")
		capabilities[name] = catalog_value[name]
	current = data["data"].duplicate(true)
	_generation += 1
	state = "connected"
	status = "Live authoring ready"
	changed.emit()
	return success(status, {})


func _valid_current(value: Dictionary) -> bool:
	return typeof(value.get("revision")) in [TYPE_INT, TYPE_FLOAT] and value["revision"] == floorf(value["revision"]) and value["revision"] >= 1 and value["revision"] <= 128 and typeof(value.get("sha256")) == TYPE_STRING and value["sha256"].length() == 64 and value["sha256"].is_valid_hex_number(false) and value.get("live_token") == token and typeof(value.get("scene")) == TYPE_STRING and typeof(value.get("document")) == TYPE_STRING and typeof(value.get("objects")) == TYPE_ARRAY and value["objects"].size() <= 128


func _catalog_hint() -> String:
	return 'For the live catalog send only operation="help" and the current server_id.'


func prepare(snapshot_value: Dictionary, arguments: Dictionary) -> Dictionary:
	var selected = arguments.get("objects", [])
	var local := arguments.duplicate(true)
	local.erase("objects")
	if arguments.get("operation") in ["preview", "export"]:
		if typeof(selected) != TYPE_ARRAY or selected.is_empty() or selected.size() > 16: return argument_failure("Select one to sixteen exact live-scene object names for preview/export.")
		var names := {}
		for name in selected:
			if typeof(name) != TYPE_STRING or names.has(name) or not current["objects"].any(func(value): return typeof(value) == TYPE_DICTIONARY and value.get("name") == name): return argument_failure("The preview/export selection does not match the inspected live scene.")
			names[name] = true
	elif arguments.has("objects"):
		return argument_failure("Only preview and export accept object selections.")
	var prepared := super.prepare(snapshot_value, local)
	if not prepared.get("success", false): return prepared
	var review: Dictionary = prepared["review"]
	review["live_operation"] = true
	review["document"] = current["document"]
	review["scene"] = current["scene"]
	review["server_name"] = server_name
	if arguments.get("operation") in ["preview", "export"]: review["objects"] = selected.duplicate()
	_reviews[review["review_id"]] = review.duplicate(true)
	return prepared


func execute(review: Dictionary, authorized: Callable) -> Dictionary:
	var review_id: String = review.get("review_id", "")
	if not authorized.is_valid() or not authorized.call() or not _reviews.has(review_id) or _reviews[review_id] != review: return failure("The original live Blender proposal was not approved.")
	_authorization = authorized
	_object_selection = review.get("objects", []).duplicate()
	_executing = true
	if review.get("operation") in ["import", "place"]:
		if not authorized.is_valid() or not authorized.call():
			_executing = false
			return failure("The live asset handoff is no longer approved.")
		var fresh := await _request("inspect", {})
		if not fresh.get("success", false) or fresh["data"].get("sha256") != review.get("sha256"):
			_executing = false
			return failure("The live source changed before asset handoff. Inspect and export again.")
	var result := await super.execute(review, authorized)
	_executing = false
	_authorization = Callable()
	_object_selection.clear()
	result.get("data", {})["live_operation"] = true
	if result.has("model_content"): result["model_content"] = str(result["model_content"]).replace("BLENDER WORKSPACE EVIDENCE", "LIVE BLENDER EVIDENCE")
	if result.get("success", false) and review.get("operation") == "edit": result["data"]["save_pending"] = current.get("dirty", true)
	if not result.get("success", false) and result.get("data", {}).get("uncertain", false): pause()
	return result


func _request(operation: String, arguments: Dictionary) -> Dictionary:
	if not _authorization.is_valid() or not _authorization.call() or _current_script_hashes() != _script_hashes: return failure("The live operation is no longer authorized.")
	var payload := arguments.duplicate(true)
	payload["operation"] = operation
	if operation in ["preview", "export"]: payload["objects"] = _object_selection.duplicate()
	var response: Dictionary = await dispatch_code.call(_call_code(payload))
	var decoded := decode(response)
	if not decoded.get("success", false):
		if decoded.get("data", {}).get("uncertain", false) or decoded.get("data", {}).get("authoring_revoked", false): pause()
		return decoded
	if not _authorization.is_valid() or not _authorization.call():
		pause()
		var interrupted := failure("The accepted live operation was interrupted. Inspect Blender before continuing; no operation was replayed.")
		interrupted["data"]["uncertain"] = true
		return interrupted
	var result: Dictionary = decoded["data"]
	var recovery = result.get("recovery", {})
	if typeof(recovery) == TYPE_DICTIONARY and typeof(recovery.get("file")) == TYPE_STRING and recovery["file"] == recovery["file"].get_file():
		var file: String = workspace.path_join(recovery["file"])
		if Paths.no_links(file) and FileAccess.get_sha256(file) == recovery.get("sha256"): latest_checkpoint = recovery.duplicate(true)
	if operation in ["preview", "export"]:
		if typeof(result.get("baseline")) != TYPE_DICTIONARY or not _valid_current(result["baseline"]):
			pause()
			return uncertain_failure("Invalid live preview/export baseline.")
		current = result["baseline"].duplicate(true)
	var data = result.get("data", {})
	if typeof(data) != TYPE_DICTIONARY:
		pause()
		return uncertain_failure("The live helper returned malformed evidence.")
	if operation == "inspect": data["user_textures"] = textures.duplicate(true)
	return {"success": true, "data": data}


func _call_code(payload: Dictionary) -> String:
	return "import sys, json\n_m = sys.modules.get(%s)\nresult = _m.dispatch(json.loads(%s)) if _m is not None else {'ok': False, 'authoring_revoked': True, 'message': 'Live authoring is no longer enabled'}\n" % [JSON.stringify("_orca_live_" + token), JSON.stringify(JSON.stringify(payload))]


static func decode(response: Dictionary) -> Dictionary:
	if not response.get("success", false):
		var interrupted := failure("The live Blender request failed or timed out. Its effects may be uncertain; inspect Blender before enabling again.")
		interrupted["data"]["uncertain"] = true
		return interrupted
	var normalized := preload("res://addons/orca/scripts/mcp_service.gd").normalize_result(response.get("result", {}), "")
	if not normalized.get("success", false): return uncertain_failure("The live server returned unsupported or oversized evidence.")
	if not Client._bounded_json(normalized["content"]): return uncertain_failure("The live result exceeds its JSON work budget.")
	var parser := JSON.new()
	if parser.parse(normalized["content"]) != OK or typeof(parser.data) != TYPE_DICTIONARY: return uncertain_failure("Malformed live Blender result.")
	var value = parser.data
	if value.has("status"):
		if value.get("status") != "ok" or typeof(value.get("result")) != TYPE_DICTIONARY: return uncertain_failure("The Blender server reported a native execution failure.")
		value = value["result"]
	if typeof(value.get("ok")) != TYPE_BOOL: return uncertain_failure("The live helper returned an invalid outcome.")
	if not value["ok"]:
		var completed = value.get("completed_commands", 0)
		if typeof(completed) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(completed)) or completed != floorf(completed) or completed < 0 or completed > 16: return uncertain_failure("The live helper returned an invalid partial-operation receipt.")
		var failed := failure(str(value.get("message", "Live authoring did not complete.")).left(240))
		failed["data"]["uncertain"] = value.get("uncertain", false) == true
		failed["data"]["authoring_revoked"] = value.get("authoring_revoked", false) == true
		failed["data"]["completed_commands"] = int(completed)
		failed["data"]["recovery_available"] = typeof(value.get("recovery")) == TYPE_DICTIONARY and not value["recovery"].is_empty()
		return failed
	return {"success": true, "data": value}


static func uncertain_failure(message: String) -> Dictionary:
	var result := failure(message)
	result["data"]["uncertain"] = true
	return result


func undo_last(authorized: Callable) -> Dictionary:
	if busy() or state != "connected" or not authorized.is_valid() or not authorized.call(): return failure("Undo requires idle Work mode and the current live-session receipt.")
	_executing = true
	var response: Dictionary = await dispatch_code.call(_call_code({"operation": "undo", "revision": current["revision"], "sha256": current["sha256"]}))
	_executing = false
	var result := decode(response)
	if result.get("success", false): pause()
	return success("The last Orca live edit was undone. Enable authoring again to refresh native identities.", {}) if result.get("success", false) else result


func pause() -> void:
	state = "paused"
	status = "Live authoring paused. Inspect Blender and enable again explicitly."
	_generation += 1
	_reviews.clear()
	changed.emit()


func busy() -> bool:
	return _executing


static func definition() -> Dictionary:
	var value := preload("res://addons/orca/scripts/blender_workspace_service.gd").definition()
	var function: Dictionary = value["function"]
	function["name"] = "blender_session"
	function["description"] = "Send blender_session as the ONLY tool call in its response. For catalog help send just server_id and operation=help. Omit unused fields entirely. inspect refreshes the baseline; edit takes validated JSON commands; preview/export need exact object names including parents/rigs. Only a separately confirmed live-session grant covers help/inspect/edit/preview/export. Import/place always require exact review. No arbitrary Python/tools/paths or document save/reload; no replay."
	var parameters: Dictionary = function["parameters"]
	parameters["properties"]["server_id"] = {"type": "string", "maxLength": 48}
	parameters["properties"]["objects"] = {"type": "array", "items": {"type": "string", "maxLength": 256}, "minItems": 1, "maxItems": 16, "description": "Only preview/export: exact names from live inspect, including the asset's parent/armature."}
	parameters["required"].append("server_id")
	return value
