@tool
extends Node

const MAX_BYTES := 16384
const NativeHelper = preload("res://addons/orca/scripts/native_helper_service.gd")
var helper_service
var _process: Dictionary = {}
var _buffer := PackedByteArray()
var _scope := ""


func _ready() -> void:
	if helper_service == null:
		helper_service = NativeHelper.new()
		add_child(helper_service)


func available() -> bool:
	return not _executable().is_empty()


func acquire(scope: String) -> bool:
	var executable := _executable()
	if not _process.is_empty() or executable.is_empty() or scope.length() != 64:
		return false
	_scope = scope
	_process = OS.execute_with_pipe(executable, [scope], false)
	if _process.is_empty():
		return false
	if await _read_line(50000) != "READY":
		release()
		return false
	return true


func read_record() -> Dictionary:
	var response := await _command("get")
	if response == "MISSING":
		return {"success": true, "record": {}}
	if not response.begins_with("VALUE "):
		return {"success": false}
	var bytes := Marshalls.base64_to_raw(response.substr(6))
	var value = JSON.parse_string(bytes.get_string_from_utf8())
	return {"success": typeof(value) == TYPE_DICTIONARY, "record": value if typeof(value) == TYPE_DICTIONARY else {}}


func write_record(record: Dictionary) -> bool:
	var encoded := Marshalls.raw_to_base64(JSON.stringify(record).to_utf8_buffer())
	if encoded.length() > 16000:
		return false
	return await _command("put " + encoded) == "OK"


func erase() -> bool:
	return await _command("delete") == "OK"


func release() -> void:
	if not _process.is_empty():
		var pid := int(_process.get("pid", 0))
		var pipe = _process.get("stdio")
		if pipe != null and pipe.is_open():
			if pid > 0 and OS.is_process_running(pid):
				pipe.store_string("release\n")
			pipe.close()
		var errors = _process.get("stderr")
		if errors != null and errors.is_open():
			errors.close()
		# No helper may remain blocked on an unlock prompt after its owner closes.
		# This PID came only from our fixed executable, never from model input.
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
	_process.clear()
	_buffer.clear()


func _exit_tree() -> void:
	release()


func _command(command: String) -> String:
	if _process.is_empty():
		return "ERROR"
	_process["stdio"].store_string(command + "\n")
	return await _read_line(30000)


func _read_line(timeout_ms: int) -> String:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not _process.is_empty() and Time.get_ticks_msec() < deadline:
		var newline := _buffer.find(10)
		if newline >= 0:
			var line := _buffer.slice(0, newline).get_string_from_utf8()
			_buffer = _buffer.slice(newline + 1)
			return line
		var chunk: PackedByteArray = _process["stdio"].get_buffer(4096)
		_buffer.append_array(chunk)
		if _buffer.size() > MAX_BYTES or not OS.is_process_running(int(_process.get("pid", 0))):
			return "ERROR"
		await get_tree().process_frame
	return "ERROR"


func _executable() -> String:
	return helper_service.executable() if helper_service != null else ""
