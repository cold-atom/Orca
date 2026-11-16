@tool
extends Node

## MCP 2025 stdio transport. No shell, automatic launch, reconnect or call replay.
signal changed

const VERSIONS := ["2025-11-25", "2025-06-18", "2024-11-05"]
const MAX_FRAME := 128 * 1024
const MAX_REQUEST := 8192
const MAX_TRUSTED_REQUEST := 32 * 1024 # Fixed Orca helper framing; no advertised/model limit.
const MAX_LIST := 64
const TIMEOUT_MS := 30000

var state := "disconnected"
var failure := ""
var tools: Array[Dictionary] = []
var resources: Array[Dictionary] = []
var truncated := false
var revision := 0
var _child: Dictionary = {}
var _buffer := PackedByteArray()
var _serial := 0
var _pending_id := 0
var _response: Dictionary = {}
var _received := 0
var _stderr_received := 0
var _notifications := 0
var _active_requests := 0
var _active_connections := 0


func connect_process(command: String, arguments: Array) -> Dictionary:
	_active_connections += 1
	var result := await _connect_process(command, arguments)
	_active_connections -= 1
	changed.emit()
	return result


func settling() -> bool:
	return _active_requests > 0 or _active_connections > 0


func _connect_process(command: String, arguments: Array) -> Dictionary:
	if not close():
		return {"success": false, "error": failure}
	failure = ""
	state = "connecting"
	changed.emit()
	_child = OS.execute_with_pipe(command, PackedStringArray(arguments), false)
	if _child.is_empty() or not _child.get("stdio") is FileAccess or not _child.get("stderr") is FileAccess:
		return _fail("Could not start the configured MCP executable.")
	set_process(true)
	var generation := revision
	var initialized := await request("initialize", {"protocolVersion": VERSIONS[0], "capabilities": {}, "clientInfo": {"name": "Orca", "version": "1.9.0"}})
	if not initialized.get("success", false):
		return initialized
	var result: Dictionary = initialized["result"]
	if result.get("protocolVersion") not in VERSIONS or typeof(result.get("capabilities")) != TYPE_DICTIONARY or typeof(result.get("serverInfo")) != TYPE_DICTIONARY:
		return _fail("The MCP server returned an unsupported initialization contract.")
	for field in ["name", "version"]:
		if typeof(result["serverInfo"].get(field)) != TYPE_STRING or result["serverInfo"][field].is_empty() or result["serverInfo"][field].length() > 256:
			return _fail("The MCP server returned invalid identity metadata.")
	if not _send({"jsonrpc": "2.0", "method": "notifications/initialized"}):
		return _fail("Could not acknowledge MCP initialization.")
	var capabilities: Dictionary = result["capabilities"]
	for kind in ["tools", "resources"]:
		if not capabilities.has(kind):
			continue
		if typeof(capabilities[kind]) != TYPE_DICTIONARY:
			return _fail("Invalid MCP capabilities.")
		var listed := await _list(kind)
		if not listed.get("success", false):
			return listed
	if revision != generation or state != "connecting":
		return {"success": false, "error": "The MCP connection changed during discovery."}
	state = "connected"
	changed.emit()
	return {"success": true}


func _list(kind: String) -> Dictionary:
	var entries: Array[Dictionary] = []
	var cursor := ""
	var cursors := {}
	var identities := {}
	for page in range(4):
		var response := await request(kind + "/list", {} if cursor.is_empty() else {"cursor": cursor})
		if not response.get("success", false):
			return response
		var result: Dictionary = response["result"]
		if typeof(result.get(kind)) != TYPE_ARRAY or result[kind].size() > MAX_LIST:
			return _fail("The MCP catalog exceeds its bounds or is malformed.")
		for raw in result[kind]:
			if typeof(raw) != TYPE_DICTIONARY:
				return _fail("Invalid MCP catalog entry.")
			var identity = raw.get("name" if kind == "tools" else "uri")
			if typeof(identity) != TYPE_STRING or identity.is_empty() or identity.length() > 1024 or identities.has(identity):
				return _fail("Invalid or duplicate MCP catalog identity.")
			identities[identity] = true
			if entries.size() >= MAX_LIST:
				truncated = true
				break
			entries.append(raw.duplicate(true))
		if not result.has("nextCursor"):
			break
		if typeof(result["nextCursor"]) != TYPE_STRING or result["nextCursor"].is_empty() or result["nextCursor"].length() > 1024 or cursors.has(result["nextCursor"]):
			return _fail("Invalid or repeated MCP catalog cursor.")
		cursor = result["nextCursor"]
		cursors[cursor] = true
		if entries.size() == MAX_LIST or page == 3:
			truncated = true
			break
	if kind == "tools":
		tools = entries
	else:
		resources = entries
	return {"success": true}


func request(method: String, params: Dictionary, request_limit: int = MAX_REQUEST) -> Dictionary:
	_active_requests += 1
	var result := await _request(method, params, request_limit)
	_active_requests -= 1
	return result


func _request(method: String, params: Dictionary, request_limit: int = MAX_REQUEST) -> Dictionary:
	if request_limit not in [MAX_REQUEST, MAX_TRUSTED_REQUEST]: return {"success": false, "error": "Unsupported local MCP request budget."}
	if _child.is_empty() or _pending_id != 0 or state not in ["connecting", "connected"]:
		return {"success": false, "error": "The MCP connection is unavailable or busy."}
	_serial += 1
	_pending_id = _serial
	var request_id := _pending_id
	_response.clear()
	_received = _buffer.size()
	_stderr_received = 0
	_notifications = 0
	var generation := revision
	if not _send({"jsonrpc": "2.0", "id": _pending_id, "method": method, "params": params}, request_limit):
		return _fail("The MCP request could not be sent.")
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while _response.is_empty() and generation == revision and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if generation != revision:
		if _pending_id == request_id:
			_pending_id = 0
		return {"success": false, "error": failure if not failure.is_empty() else "The MCP request was cancelled. No automatic retry was made."}
	if _response.is_empty():
		return _fail("The MCP request timed out. No automatic retry was made.")
	var response := _response.duplicate(true)
	_response.clear()
	_pending_id = 0
	if response.has("error"):
		# Server errors can contain credentials or arbitrary payloads. Keep raw
		# errors off Settings, support reports and persisted activity receipts.
		return {"success": false, "error": "The MCP server rejected the request."}
	return {"success": true, "result": response["result"]}


func busy() -> bool:
	return _pending_id != 0


func close() -> bool:
	revision += 1
	if not _child.is_empty():
		var pid := int(_child.get("pid", 0))
		if pid > 0 and OS.is_process_running(pid) and _stop_process(pid) != OK and OS.is_process_running(pid):
			failure = "The MCP bridge could not be stopped. Disconnect again before reconnecting."
			state = "stop_failed"
			set_process(false)
			changed.emit()
			return false # Retain the exact PID/pipes; never overwrite lost ownership.
		for key in ["stdio", "stderr"]:
			var pipe = _child.get(key)
			if pipe is FileAccess and pipe.is_open():
				pipe.close()
	_child.clear()
	_buffer.clear()
	_response.clear()
	tools.clear()
	resources.clear()
	truncated = false
	state = "disconnected"
	set_process(false)
	changed.emit()
	return true


func _stop_process(pid: int) -> int:
	return OS.kill(pid) # Only our retained direct bridge; never Blender or descendants.


func _exit_tree() -> void:
	close()


func _process(_delta: float) -> void:
	if _child.is_empty():
		return
	var chunk: PackedByteArray = _child["stdio"].get_buffer(16384)
	_buffer.append_array(chunk)
	_received += chunk.size()
	var errors: PackedByteArray = _child["stderr"].get_buffer(16384)
	_stderr_received += errors.size() # Drain, bound and discard; never log secrets.
	if _buffer.size() > MAX_FRAME or _received > MAX_FRAME or _stderr_received > MAX_FRAME:
		_fail("The MCP server exceeded its output limit.")
		return
	for frame_index in range(16):
		var newline := _buffer.find(10)
		if newline < 0:
			break
		var bytes := _buffer.slice(0, newline)
		_buffer = _buffer.slice(newline + 1)
		if not _valid_utf8(bytes):
			_fail("Invalid MCP UTF-8 framing.")
			return
		var text := bytes.get_string_from_utf8()
		if not _bounded_json(text):
			_fail("Invalid MCP JSON framing.")
			return
		var parser := JSON.new()
		if parser.parse(text) != OK or typeof(parser.data) != TYPE_DICTIONARY:
			_fail("Invalid MCP JSON message.")
			return
		var message: Dictionary = parser.data
		if message.get("jsonrpc") != "2.0":
			_fail("Invalid MCP JSON-RPC version.")
			return
		if message.has("method"):
			_notifications += 1
			if _notifications > 64:
				_fail("The MCP server exceeded its notification limit.")
				return
			if message.has("id"):
				if typeof(message["id"]) not in [TYPE_STRING, TYPE_INT, TYPE_FLOAT] or str(message["id"]).length() > 128:
					_fail("Invalid MCP server request identity.")
					return
				_send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "Client capability not supported"}})
			elif message["method"] in ["notifications/tools/list_changed", "notifications/resources/list_changed"]:
				_fail("The MCP catalog changed. Reconnect to review the new capabilities.")
				return
		elif _pending_id != 0 and typeof(message.get("id")) in [TYPE_INT, TYPE_FLOAT] and message["id"] == _pending_id:
			if not _response.is_empty() or message.has("result") == message.has("error") or typeof(message.get("result", message.get("error"))) != TYPE_DICTIONARY:
				_fail("Invalid or duplicate MCP response.")
				return
			_response = message
		else:
			_fail("Unexpected MCP response identity.")
			return
	if not _child.is_empty() and not OS.is_process_running(int(_child.get("pid", 0))) and _response.is_empty():
		_fail("The MCP process exited.")


func _send(message: Dictionary, request_limit: int = MAX_REQUEST) -> bool:
	var bytes := (JSON.stringify(message) + "\n").to_utf8_buffer()
	if _child.is_empty() or request_limit not in [MAX_REQUEST, MAX_TRUSTED_REQUEST] or bytes.size() > request_limit:
		return false
	_child["stdio"].store_buffer(bytes)
	return _child["stdio"].get_error() == OK


func _fail(message: String) -> Dictionary:
	failure = message
	close()
	_pending_id = 0
	return {"success": false, "error": message}


static func _bounded_json(text: String) -> bool:
	var depth := 0
	var quoted := false
	var escaped := false
	for character in text:
		if quoted:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == '"':
				quoted = false
		elif character == '"':
			quoted = true
		elif character in ["{", "["]:
			depth += 1
			if depth > 24:
				return false
		elif character in ["}", "]"]:
			depth -= 1
	return not quoted and depth == 0


static func _valid_utf8(bytes: PackedByteArray) -> bool:
	var index := 0
	while index < bytes.size():
		var first := bytes[index]
		if first == 0:
			return false
		if first < 128:
			index += 1
			continue
		var count := 2 if first >= 194 and first <= 223 else 3 if first >= 224 and first <= 239 else 4 if first >= 240 and first <= 244 else 0
		if count == 0 or index + count > bytes.size():
			return false
		for offset in range(1, count):
			if bytes[index + offset] < 128 or bytes[index + offset] > 191:
				return false
		var second := bytes[index + 1]
		if (first == 224 and second < 160) or (first == 237 and second > 159) or (first == 240 and second < 144) or (first == 244 and second > 143):
			return false
		index += count
	return true
