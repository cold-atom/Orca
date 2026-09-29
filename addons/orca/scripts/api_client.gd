@tool
extends Node

const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")

signal request_completed(response: Dictionary)
signal request_failed(error: Dictionary)
signal request_cancelled
signal stream_started
signal stream_delta(content: String)

const CONNECT_TIMEOUT_MS := 30000
const INACTIVITY_TIMEOUT_MS := 60000
const MAX_RESPONSE_BYTES := 4 * 1024 * 1024
const MAX_SSE_LINE_BYTES := 1024 * 1024
const MAX_SSE_EVENT_BYTES := 1024 * 1024
const MAX_ASSISTANT_CONTENT_BYTES := 2 * 1024 * 1024
const MAX_REASONING_CONTENT_BYTES := 2 * 1024 * 1024
const MAX_TOOL_ARGUMENT_BYTES := 2 * 1024 * 1024
const MAX_TOOL_METADATA_BYTES := 1024 * 1024
const MAX_REASONING_DETAILS_BYTES := 2 * 1024 * 1024
const MAX_ERROR_BODY_BYTES := 64 * 1024
const MAX_REASONING_DETAILS := 256
const MAX_TOOL_CALLS_PER_RESPONSE := 16
const CONNECT_RETRY_DELAY_SECONDS := 0.5
const MAX_CONNECT_RETRIES := 1

var _config
var _http_client: HTTPClient
var _request_serial := 0
var _is_requesting := false
var _cancel_requested := false
var _raw_response := PackedByteArray()
var _line_buffer := PackedByteArray()
var _event_data_lines := PackedStringArray()
var _skip_next_lf := false
var _is_first_sse_line := true
var _received_sse_event := false
var _stream_done := false
var _stream_error := ""
var _assistant_content := ""
var _tool_calls: Dictionary = {}
var _finish_reason = null
var _stream_usage: Dictionary = {}
var _request_model := ""
var _configured_request_model := ""
var _configured_api_url := ""
var _request_may_have_usage := false
var _configured_provider := ""
var _reasoning_content := ""
var _reasoning_details: Array = []
var _response_bytes_received := 0
var _event_data_bytes := 0
var _assistant_content_bytes := 0
var _reasoning_content_bytes := 0
var _tool_argument_bytes := 0
var _tool_metadata_bytes := 0
var _reasoning_details_bytes := 0
var _request_phase := "idle"
var _response_code := 0


func _ready() -> void:
	_config = preload("res://addons/orca/scripts/config.gd")


func is_requesting() -> bool:
	return _is_requesting


func last_request_may_have_usage() -> bool:
	return _request_may_have_usage


func send_chat_completion(messages: Array, tools: Array = [], provider_config: Dictionary = {}) -> void:
	if _is_requesting:
		request_failed.emit(_make_error("A request is already in progress.", "state", false))
		return
	_request_may_have_usage = false

	var request_config: Dictionary = _config.get_active_provider_config() if provider_config.is_empty() else provider_config.duplicate(true)
	var provider = ProviderRegistry.get_provider(str(request_config.get("provider", "custom")))
	var api_key = str(request_config.get("api_key", ""))
	if api_key.is_empty():
		request_failed.emit(_make_error("API Key is missing. Please set it in Settings.", "configuration", false))
		return
	if str(request_config.get("model", "")).is_empty():
		request_failed.emit(_make_error("No model is selected. Choose a model in Settings.", "configuration", false))
		return

	var url = provider.chat_url(request_config)
	_configured_api_url = url

	var endpoint := _parse_url(url)
	if endpoint.is_empty():
		request_failed.emit(_make_error("Invalid API URL. Use a complete http:// or https:// URL.", "configuration", false))
		return

	var body = {
		"model": request_config.get("model", ""),
		"messages": provider.sanitize_messages(messages),
		"stream": true,
		"stream_options": {"include_usage": true}
	}
	if not tools.is_empty():
		body["tools"] = tools
		body["tool_choice"] = "auto"
	provider.apply_chat_options(body, str(request_config.get("reasoning_effort", "default")))

	_reset_stream_state()
	_request_model = str(body["model"])
	_configured_request_model = _request_model
	_configured_provider = str(request_config.get("provider", "custom"))
	_is_requesting = true
	_cancel_requested = false
	_request_serial += 1
	_perform_request(_request_serial, endpoint, provider.request_headers(api_key), body, true, MAX_CONNECT_RETRIES)


func cancel_request() -> void:
	if not _is_requesting:
		return
	_cancel_requested = true
	_request_serial += 1
	_is_requesting = false
	if _http_client != null:
		_http_client.close()
		_http_client = null
	_reset_stream_state()
	request_cancelled.emit()


func _perform_request(request_id: int, endpoint: Dictionary, base_headers: PackedStringArray, body: Dictionary, allow_usage_retry: bool, connect_retries_remaining: int) -> void:
	_http_client = HTTPClient.new()
	_http_client.read_chunk_size = 4096
	var json_body := JSON.stringify(body)
	var headers := base_headers.duplicate()
	headers.append("Content-Length: " + str(json_body.to_utf8_buffer().size()))

	var tls_options: TLSOptions = null
	if endpoint["scheme"] == "https":
		tls_options = TLSOptions.client()

	_request_phase = "connecting"
	var error := _http_client.connect_to_host(endpoint["host"], endpoint["port"], tls_options)
	if error != OK:
		await _retry_connection_or_fail(request_id, endpoint, base_headers, body, allow_usage_retry, connect_retries_remaining, "Failed to connect to the API host: " + error_string(error), "connection")
		return

	var deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	while _is_current_request(request_id) and _http_client.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		error = _http_client.poll()
		if error != OK:
			await _retry_connection_or_fail(request_id, endpoint, base_headers, body, allow_usage_retry, connect_retries_remaining, "Connection failed: " + error_string(error), "connection")
			return
		if Time.get_ticks_msec() > deadline:
			await _retry_connection_or_fail(request_id, endpoint, base_headers, body, allow_usage_retry, connect_retries_remaining, "Connection timed out.", "timeout")
			return
		await get_tree().process_frame

	if not _is_current_request(request_id):
		return
	if _http_client.get_status() != HTTPClient.STATUS_CONNECTED:
		await _retry_connection_or_fail(request_id, endpoint, base_headers, body, allow_usage_retry, connect_retries_remaining, _status_error(_http_client.get_status()), _status_category(_http_client.get_status()))
		return

	_request_phase = "submitting"
	error = _http_client.request(HTTPClient.METHOD_POST, endpoint["target"], headers, json_body)
	if error != OK:
		_fail_request(request_id, "Failed to initiate HTTP request: " + error_string(error), "connection", true)
		return
	# Once HTTPClient accepts the POST, a later failure may still have incurred provider usage.
	_request_may_have_usage = true

	_request_phase = "waiting_for_response"
	deadline = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	while _is_current_request(request_id) and _http_client.get_status() == HTTPClient.STATUS_REQUESTING:
		error = _http_client.poll()
		if error != OK:
			_fail_request(request_id, "HTTP request failed: " + error_string(error), "connection", true)
			return
		if Time.get_ticks_msec() > deadline:
			_fail_request(request_id, "The API did not begin responding in time.", "timeout", true)
			return
		await get_tree().process_frame

	if not _is_current_request(request_id):
		return
	if not _http_client.has_response():
		var response_status := _http_client.get_status()
		_fail_request(request_id, _status_error(response_status), _status_category(response_status), true)
		return

	var response_code := _http_client.get_response_code()
	_response_code = response_code
	var response_headers := _http_client.get_response_headers_as_dictionary()
	var content_type := _get_header(response_headers, "content-type").to_lower()
	var media_type := content_type.split(";", false, 1)[0].strip_edges()
	var is_sse := media_type == "text/event-stream"
	var is_json := _is_json_media_type(media_type)
	if response_code == HTTPClient.RESPONSE_OK:
		if is_sse:
			stream_started.emit()

	_request_phase = "receiving_response"
	var last_activity := Time.get_ticks_msec()
	while _is_current_request(request_id):
		error = _http_client.poll()
		if error != OK:
			_fail_request(request_id, "Connection failed while receiving the response: " + error_string(error), "connection", false)
			return

		var received_data := false
		while _http_client.get_status() == HTTPClient.STATUS_BODY:
			var chunk := _http_client.read_response_body_chunk()
			if chunk.is_empty():
				break
			received_data = true
			last_activity = Time.get_ticks_msec()
			_response_bytes_received += chunk.size()
			if response_code == HTTPClient.RESPONSE_OK and is_sse:
				_consume_sse_bytes(chunk)
				if not _is_current_request(request_id):
					return
				if _stream_done:
					if _stream_error.is_empty():
						_complete_stream(request_id)
					else:
						_fail_request(request_id, _stream_error, "response_limit" if _stream_error.contains("limit") else "malformed_response", false)
					return
			else:
				_raw_response.append_array(chunk)
				var buffered_limit := MAX_ERROR_BODY_BYTES if response_code != HTTPClient.RESPONSE_OK else MAX_RESPONSE_BYTES
				if _raw_response.size() > buffered_limit:
					var message := "HTTP %d returned an error body larger than the %d KiB safety limit." % [response_code, MAX_ERROR_BODY_BYTES / 1024] if response_code != HTTPClient.RESPONSE_OK else "The JSON response exceeded the 4 MiB safety limit."
					_fail_request(request_id, message, "response_limit", false)
					return
			if _response_bytes_received > MAX_RESPONSE_BYTES:
				_fail_request(request_id, "The streamed response exceeded the 4 MiB aggregate safety limit (%s received). Hidden reasoning and tool arguments count toward this limit." % _format_bytes(_response_bytes_received), "response_limit", false)
				return

		var status := _http_client.get_status()
		if status in [HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
			_fail_request(request_id, _status_error(status), _status_category(status), false)
			return
		if status in [HTTPClient.STATUS_CONNECTED, HTTPClient.STATUS_DISCONNECTED]:
			break
		if not received_data and Time.get_ticks_msec() - last_activity > INACTIVITY_TIMEOUT_MS:
			_fail_request(request_id, "The response stream timed out due to inactivity.", "timeout", false)
			return
		await get_tree().process_frame

	if not _is_current_request(request_id):
		return
	if response_code != HTTPClient.RESPONSE_OK:
		var error_body := _raw_response.get_string_from_utf8().strip_edges()
		if allow_usage_retry and response_code in [400, 422] and error_body.to_lower().contains("stream_options"):
			_http_client.close()
			_http_client = null
			_reset_stream_state()
			body.erase("stream_options")
			await _perform_request(request_id, endpoint, base_headers, body, false, MAX_CONNECT_RETRIES)
			return
		var error_message := "HTTP Error " + str(response_code)
		if not error_body.is_empty():
			error_message += ": " + error_body
		_fail_request(request_id, error_message, "http", response_code in [408, 425, 429, 500, 502, 503, 504])
		return

	if is_json:
		_complete_json_response(request_id)
		return
	if not is_sse:
		_fail_request(request_id, "The API returned an unexpected Content-Type: %s." % (media_type if not media_type.is_empty() else "missing"), "malformed_response", false)
		return

	_finish_sse_input()
	if _stream_done:
		if _stream_error.is_empty():
			_complete_stream(request_id)
		else:
			_fail_request(request_id, _stream_error, "response_limit" if _stream_error.contains("limit") else "malformed_response", false)
		return
	if _received_sse_event and _finish_reason != null:
		_complete_stream(request_id)
		return

	_fail_request(request_id, "The response stream ended before its completion marker.", "connection", false)


func _consume_sse_bytes(bytes: PackedByteArray) -> void:
	for byte in bytes:
		if _skip_next_lf:
			_skip_next_lf = false
			if byte == 10:
				continue
		if byte == 13:
			_process_sse_line(_line_buffer.get_string_from_utf8())
			_line_buffer.clear()
			_skip_next_lf = true
		elif byte == 10:
			_process_sse_line(_line_buffer.get_string_from_utf8())
			_line_buffer.clear()
		else:
			_line_buffer.append(byte)
			if _line_buffer.size() > MAX_SSE_LINE_BYTES:
				_stream_error = "A streamed response line exceeded the 1 MiB safety limit."
				_stream_done = true
				return


func _process_sse_line(line: String) -> void:
	if _is_first_sse_line:
		_is_first_sse_line = false
		if line.begins_with(String.chr(0xfeff)):
			line = line.substr(1)
	if line.is_empty():
		_dispatch_sse_event()
		return
	if line.begins_with(":"):
		return

	var separator := line.find(":")
	var field := line if separator == -1 else line.substr(0, separator)
	var value := "" if separator == -1 else line.substr(separator + 1)
	if value.begins_with(" "):
		value = value.substr(1)
	if field == "data":
		_event_data_bytes += value.to_utf8_buffer().size()
		if not _event_data_lines.is_empty():
			_event_data_bytes += 1
		if _event_data_bytes > MAX_SSE_EVENT_BYTES:
			_stream_error = "A streamed response event exceeded the 1 MiB safety limit."
			_stream_done = true
			return
		_event_data_lines.append(value)


func _dispatch_sse_event() -> void:
	if _event_data_lines.is_empty():
		return
	var payload := "\n".join(_event_data_lines)
	_event_data_lines.clear()
	_event_data_bytes = 0
	_received_sse_event = true
	if payload.strip_edges() == "[DONE]":
		_stream_done = true
		return

	var json := JSON.new()
	if json.parse(payload) != OK:
		_stream_error = "The API returned a malformed streaming event."
		_stream_done = true
		return
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		return
	if data.has("model"):
		_request_model = str(data["model"])
	if data.has("usage"):
		var normalized_usage := _normalize_usage(data["usage"])
		if not normalized_usage.is_empty():
			_stream_usage = normalized_usage
	if data.has("error"):
		var api_error = data["error"]
		if typeof(api_error) == TYPE_DICTIONARY:
			_stream_error = str(api_error.get("message", "The API returned a streaming error."))
		else:
			_stream_error = str(api_error)
		_stream_done = true
		return

	var choices = data.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.is_empty():
		return
	var choice = choices[0]
	if typeof(choice) != TYPE_DICTIONARY:
		return
	var delta = choice.get("delta", {})
	if typeof(delta) != TYPE_DICTIONARY:
		return

	var content = delta.get("content")
	if typeof(content) == TYPE_STRING and not content.is_empty():
		_assistant_content_bytes += content.to_utf8_buffer().size()
		if _assistant_content_bytes > MAX_ASSISTANT_CONTENT_BYTES:
			_stream_error = "Assistant text exceeded the 2 MiB safety limit."
			_stream_done = true
			return
		_assistant_content += content
		stream_delta.emit(content)
	var reasoning_content = delta.get("reasoning_content", delta.get("reasoning", null))
	if typeof(reasoning_content) == TYPE_STRING and not reasoning_content.is_empty():
		_reasoning_content_bytes += reasoning_content.to_utf8_buffer().size()
		if _reasoning_content_bytes > MAX_REASONING_CONTENT_BYTES:
			_stream_error = "Provider reasoning content exceeded the 2 MiB safety limit."
			_stream_done = true
			return
		_reasoning_content += reasoning_content
	var reasoning_details = delta.get("reasoning_details", [])
	if typeof(reasoning_details) == TYPE_ARRAY:
		_accumulate_reasoning_details(reasoning_details)

	var tool_call_deltas = delta.get("tool_calls", [])
	if typeof(tool_call_deltas) == TYPE_ARRAY:
		for tool_call_delta in tool_call_deltas:
			_accumulate_tool_call(tool_call_delta)

	if choice.get("finish_reason") != null:
		_finish_reason = choice.get("finish_reason")


func _accumulate_tool_call(delta) -> void:
	if typeof(delta) != TYPE_DICTIONARY:
		return
	var index := int(delta.get("index", 0))
	var tool_call: Dictionary = _tool_calls.get(index, {
		"id": "",
		"type": "function",
		"function": {"name": "", "arguments": ""}
	})
	if typeof(delta.get("id")) == TYPE_STRING:
		tool_call["id"] += delta["id"]
	if typeof(delta.get("type")) == TYPE_STRING:
		tool_call["type"] = delta["type"]
	var function_delta = delta.get("function", {})
	if typeof(function_delta) == TYPE_DICTIONARY:
		var function: Dictionary = tool_call["function"]
		if typeof(function_delta.get("name")) == TYPE_STRING:
			function["name"] += function_delta["name"]
		if typeof(function_delta.get("arguments")) == TYPE_STRING:
			_tool_argument_bytes += function_delta["arguments"].to_utf8_buffer().size()
			if _tool_argument_bytes > MAX_TOOL_ARGUMENT_BYTES:
				_stream_error = "Tool-call arguments exceeded the 2 MiB safety limit."
				_stream_done = true
				return
			function["arguments"] += function_delta["arguments"]
		tool_call["function"] = function
	var extra_content = delta.get("extra_content")
	if typeof(extra_content) == TYPE_DICTIONARY:
		_tool_metadata_bytes += JSON.stringify(extra_content).to_utf8_buffer().size()
		if _tool_metadata_bytes > MAX_TOOL_METADATA_BYTES:
			_stream_error = "Tool-call metadata exceeded the 1 MiB safety limit."
			_stream_done = true
			return
		tool_call["extra_content"] = _merge_stream_metadata(tool_call.get("extra_content", {}), extra_content)
	_tool_calls[index] = tool_call


func _merge_stream_metadata(existing, incoming, depth: int = 0):
	if depth >= 8 or typeof(existing) != TYPE_DICTIONARY or typeof(incoming) != TYPE_DICTIONARY:
		return incoming.duplicate(true) if typeof(incoming) in [TYPE_DICTIONARY, TYPE_ARRAY] else incoming
	var merged: Dictionary = existing.duplicate(true)
	for key in incoming:
		var value = incoming[key]
		if typeof(value) == TYPE_DICTIONARY and typeof(merged.get(key)) == TYPE_DICTIONARY:
			merged[key] = _merge_stream_metadata(merged[key], value, depth + 1)
		elif typeof(value) == TYPE_STRING and typeof(merged.get(key)) == TYPE_STRING:
			merged[key] += value
		else:
			merged[key] = value.duplicate(true) if typeof(value) in [TYPE_DICTIONARY, TYPE_ARRAY] else value
	return merged


func _accumulate_reasoning_details(deltas: Array) -> void:
	for local_index in range(deltas.size()):
		var raw_detail = deltas[local_index]
		if typeof(raw_detail) != TYPE_DICTIONARY:
			continue
		var detail: Dictionary = raw_detail
		_reasoning_details_bytes += JSON.stringify(detail).to_utf8_buffer().size()
		if _reasoning_details_bytes > MAX_REASONING_DETAILS_BYTES:
			_stream_error = "Provider reasoning details exceeded the 2 MiB safety limit."
			_stream_done = true
			return
		var detail_index := _reasoning_detail_index(detail)
		if detail_index < 0 or detail_index >= MAX_REASONING_DETAILS:
			_stream_error = "The provider returned too many reasoning detail blocks."
			_stream_done = true
			return
		while _reasoning_details.size() <= detail_index:
			_reasoning_details.append({})
		var accumulated: Dictionary = _reasoning_details[detail_index]
		for key in detail:
			var value = detail[key]
			if key in ["text", "summary", "data", "signature"] and typeof(value) == TYPE_STRING and typeof(accumulated.get(key)) == TYPE_STRING:
				accumulated[key] += value
			else:
				accumulated[key] = value
		_reasoning_details[detail_index] = accumulated


func _reasoning_detail_index(detail: Dictionary) -> int:
	if detail.has("index"):
		return maxi(0, int(detail["index"]))
	var detail_id := str(detail.get("id", ""))
	if not detail_id.is_empty():
		for index in range(_reasoning_details.size()):
			if str(_reasoning_details[index].get("id", "")) == detail_id:
				return index
	return _reasoning_details.size()


func _finish_sse_input() -> void:
	if not _line_buffer.is_empty():
		_process_sse_line(_line_buffer.get_string_from_utf8())
		_line_buffer.clear()
	if not _event_data_lines.is_empty() and not _stream_done:
		_dispatch_sse_event()


func _complete_stream(request_id: int) -> void:
	if not _is_current_request(request_id):
		return
	var tool_call_error := _validate_tool_calls()
	if not tool_call_error.is_empty():
		_fail_request(request_id, tool_call_error, "malformed_response", false)
		return
	var assistant_message := {
		"role": "assistant",
		"content": _assistant_content
	}
	if not _tool_calls.is_empty():
		var indices := _tool_calls.keys()
		indices.sort()
		var completed_tool_calls := []
		for index in indices:
			completed_tool_calls.append(_tool_calls[index])
		assistant_message["tool_calls"] = completed_tool_calls
	if not _reasoning_content.is_empty():
		assistant_message["reasoning_content"] = _reasoning_content
	if not _reasoning_details.is_empty():
		assistant_message["reasoning_details"] = _reasoning_details.duplicate(true)

	var response := {
		"choices": [{
			"message": assistant_message,
			"finish_reason": _finish_reason
		}],
		"model": _request_model,
		"requested_model": _configured_request_model,
		"requested_api_url": _configured_api_url,
		"requested_provider": _configured_provider
	}
	if not _stream_usage.is_empty():
		response["usage"] = _stream_usage.duplicate(true)
	_finish_request(request_id)
	request_completed.emit(response)


func _complete_json_response(request_id: int) -> void:
	var json := JSON.new()
	if json.parse(_raw_response.get_string_from_utf8()) != OK:
		_fail_request(request_id, "Failed to parse the API response.", "malformed_response", false)
		return
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		_fail_request(request_id, "Invalid API response format.", "malformed_response", false)
		return
	var response_error := _validate_json_response(data)
	if not response_error.is_empty():
		_fail_request(request_id, response_error, "malformed_response", false)
		return
	data["requested_model"] = _configured_request_model
	data["requested_api_url"] = _configured_api_url
	data["requested_provider"] = _configured_provider
	_finish_request(request_id)
	request_completed.emit(data)


func _finish_request(request_id: int) -> void:
	if request_id != _request_serial:
		return
	_is_requesting = false
	if _http_client != null:
		_http_client.close()
		_http_client = null
	_reset_stream_state()


func _fail_request(request_id: int, message: String, category: String, retryable: bool) -> void:
	if not _is_current_request(request_id):
		return
	var error := _make_error(message, category, retryable)
	_finish_request(request_id)
	request_failed.emit(error)


func _retry_connection_or_fail(request_id: int, endpoint: Dictionary, base_headers: PackedStringArray, body: Dictionary, allow_usage_retry: bool, retries_remaining: int, message: String, category: String) -> void:
	if retries_remaining <= 0:
		_fail_request(request_id, message, category, true)
		return
	if _http_client != null:
		_http_client.close()
		_http_client = null
	await get_tree().create_timer(CONNECT_RETRY_DELAY_SECONDS).timeout
	if not _is_current_request(request_id):
		return
	_reset_stream_state()
	await _perform_request(request_id, endpoint, base_headers, body, allow_usage_retry, retries_remaining - 1)


func _is_current_request(request_id: int) -> bool:
	return _is_requesting and not _cancel_requested and request_id == _request_serial


func _reset_stream_state() -> void:
	_raw_response.clear()
	_line_buffer.clear()
	_event_data_lines.clear()
	_skip_next_lf = false
	_is_first_sse_line = true
	_received_sse_event = false
	_stream_done = false
	_stream_error = ""
	_assistant_content = ""
	_tool_calls.clear()
	_finish_reason = null
	_stream_usage.clear()
	_reasoning_content = ""
	_reasoning_details.clear()
	_response_bytes_received = 0
	_event_data_bytes = 0
	_assistant_content_bytes = 0
	_reasoning_content_bytes = 0
	_tool_argument_bytes = 0
	_tool_metadata_bytes = 0
	_reasoning_details_bytes = 0
	_request_phase = "idle"
	_response_code = 0


func _validate_tool_calls() -> String:
	var calls: Array = []
	for index in _tool_calls:
		calls.append(_tool_calls[index])
	return _validate_tool_call_array(calls)


func _validate_json_response(data: Dictionary) -> String:
	var choices = data.get("choices")
	if typeof(choices) != TYPE_ARRAY or choices.is_empty() or typeof(choices[0]) != TYPE_DICTIONARY:
		return "The provider returned an invalid choices array."
	var message = choices[0].get("message")
	if typeof(message) != TYPE_DICTIONARY:
		return "The provider returned an invalid assistant message."
	if message.has("content") and message.get("content") != null and typeof(message.get("content")) != TYPE_STRING:
		return "The provider returned assistant content in an invalid format."
	if message.has("tool_calls"):
		return _validate_tool_call_array(message.get("tool_calls"))
	return ""


func _validate_tool_call_array(tool_calls) -> String:
	if typeof(tool_calls) != TYPE_ARRAY:
		return "The provider returned tool_calls in an invalid format."
	if tool_calls.size() > MAX_TOOL_CALLS_PER_RESPONSE:
		return "The provider returned more than %d tool calls in one response." % MAX_TOOL_CALLS_PER_RESPONSE
	var seen_ids: Dictionary = {}
	for raw_call in tool_calls:
		if typeof(raw_call) != TYPE_DICTIONARY:
			return "The provider returned an invalid tool call."
		var tool_call: Dictionary = raw_call
		if str(tool_call.get("type", "")) != "function":
			return "The provider returned a tool call with an invalid type."
		var call_id := str(tool_call.get("id", "")).strip_edges()
		if call_id.is_empty():
			return "The provider returned a tool call without an ID."
		if seen_ids.has(call_id):
			return "The provider returned duplicate tool-call IDs."
		seen_ids[call_id] = true
		var function = tool_call.get("function", {})
		if typeof(function) != TYPE_DICTIONARY or str(function.get("name", "")).strip_edges().is_empty():
			return "The provider returned a tool call without a function name."
		if not function.has("arguments") or typeof(function.get("arguments")) != TYPE_STRING:
			return "The provider returned tool-call arguments in an invalid format."
	return ""


func _make_error(message: String, category: String, retryable: bool) -> Dictionary:
	return {
		"message": message,
		"category": category,
		"phase": _request_phase,
		"retryable": retryable,
		"http_status": _response_code,
		"bytes_received": _response_bytes_received,
		"response_started": _response_code > 0,
		"partial_response": _assistant_content_bytes > 0 or _reasoning_content_bytes > 0 or _reasoning_details_bytes > 0 or not _tool_calls.is_empty()
	}


func _is_json_media_type(media_type: String) -> bool:
	return media_type == "application/json" or media_type.ends_with("+json")


func _format_bytes(byte_count: int) -> String:
	if byte_count >= 1024 * 1024:
		return "%.2f MiB" % (float(byte_count) / float(1024 * 1024))
	if byte_count >= 1024:
		return "%.1f KiB" % (float(byte_count) / 1024.0)
	return "%d bytes" % byte_count


func _normalize_usage(raw_usage) -> Dictionary:
	if typeof(raw_usage) != TYPE_DICTIONARY:
		return {}
	var input_value = raw_usage.get("prompt_tokens", raw_usage.get("input_tokens", null))
	var output_value = raw_usage.get("completion_tokens", raw_usage.get("output_tokens", null))
	if typeof(input_value) not in [TYPE_INT, TYPE_FLOAT] or typeof(output_value) not in [TYPE_INT, TYPE_FLOAT]:
		return {}
	var input_tokens := int(input_value)
	var output_tokens := int(output_value)
	if input_tokens < 0 or output_tokens < 0:
		return {}
	var total_value = raw_usage.get("total_tokens", input_tokens + output_tokens)
	var total_tokens := int(total_value) if typeof(total_value) in [TYPE_INT, TYPE_FLOAT] else input_tokens + output_tokens
	if total_tokens < 0:
		total_tokens = input_tokens + output_tokens
	var cached_value = raw_usage.get("cached_tokens", 0)
	var cached_tokens := int(cached_value) if typeof(cached_value) in [TYPE_INT, TYPE_FLOAT] else 0
	var details = raw_usage.get("prompt_tokens_details", {})
	if typeof(details) == TYPE_DICTIONARY:
		var detailed_cached = details.get("cached_tokens", cached_tokens)
		if typeof(detailed_cached) in [TYPE_INT, TYPE_FLOAT]:
			cached_tokens = int(detailed_cached)
		var detailed_cache_write = details.get("cache_write_tokens", null)
		if typeof(detailed_cache_write) in [TYPE_INT, TYPE_FLOAT]:
			raw_usage["cache_write_tokens"] = int(detailed_cache_write)
	var cache_hit_value = raw_usage.get("prompt_cache_hit_tokens", null)
	if typeof(cache_hit_value) in [TYPE_INT, TYPE_FLOAT]:
		cached_tokens = int(cache_hit_value)
	var cache_read_value = raw_usage.get("cache_read_input_tokens", null)
	var cache_write_value = raw_usage.get("cache_creation_input_tokens", raw_usage.get("cache_write_tokens", 0))
	var cache_write_tokens := int(cache_write_value) if typeof(cache_write_value) in [TYPE_INT, TYPE_FLOAT] else 0
	var regular_value = raw_usage.get("regular_input_tokens", null)
	var regular_input_tokens := int(regular_value) if typeof(regular_value) in [TYPE_INT, TYPE_FLOAT] else input_tokens - cached_tokens - cache_write_tokens
	var has_separate_cache_counters: bool = typeof(cache_read_value) in [TYPE_INT, TYPE_FLOAT] or raw_usage.has("cache_creation_input_tokens")
	if has_separate_cache_counters:
		if typeof(cache_read_value) not in [TYPE_INT, TYPE_FLOAT]:
			cached_tokens = 0
		else:
			cached_tokens = int(cache_read_value)
		regular_input_tokens = int(input_value)
		input_tokens = regular_input_tokens + cached_tokens + cache_write_tokens
	elif typeof(regular_value) in [TYPE_INT, TYPE_FLOAT]:
		regular_input_tokens = int(regular_value)
	else:
		regular_input_tokens = input_tokens - cached_tokens - cache_write_tokens
	var usage := {
		"input_tokens": input_tokens,
		"regular_input_tokens": maxi(0, regular_input_tokens),
		"output_tokens": output_tokens,
		"total_tokens": maxi(total_tokens, input_tokens + output_tokens),
		"cached_tokens": clampi(cached_tokens, 0, input_tokens),
		"cache_write_tokens": clampi(cache_write_tokens, 0, input_tokens)
	}
	var reported_cost = raw_usage.get("cost", raw_usage.get("total_cost", null))
	if reported_cost != null and (typeof(reported_cost) == TYPE_FLOAT or typeof(reported_cost) == TYPE_INT) and float(reported_cost) >= 0.0:
		usage["cost"] = float(reported_cost)
	return usage


func _parse_url(url: String) -> Dictionary:
	var scheme_separator := url.find("://")
	if scheme_separator == -1:
		return {}
	var scheme := url.substr(0, scheme_separator).to_lower()
	if scheme != "http" and scheme != "https":
		return {}

	var remainder := url.substr(scheme_separator + 3)
	var path_start := remainder.find("/")
	var authority := remainder if path_start == -1 else remainder.substr(0, path_start)
	var target := "/" if path_start == -1 else remainder.substr(path_start)
	var host := authority
	var port := 443 if scheme == "https" else 80

	if authority.begins_with("["):
		var bracket_end := authority.find("]")
		if bracket_end == -1:
			return {}
		host = authority.substr(1, bracket_end - 1)
		if authority.length() > bracket_end + 1:
			if authority[bracket_end + 1] != ":":
				return {}
			port = int(authority.substr(bracket_end + 2))
	else:
		var port_separator := authority.rfind(":")
		if port_separator != -1:
			host = authority.substr(0, port_separator)
			port = int(authority.substr(port_separator + 1))

	if host.is_empty() or port <= 0 or port > 65535:
		return {}
	return {"scheme": scheme, "host": host, "port": port, "target": target}


func _get_header(headers: Dictionary, requested_name: String) -> String:
	for header_name in headers:
		if str(header_name).to_lower() == requested_name:
			return str(headers[header_name])
	return ""


func _status_error(status: HTTPClient.Status) -> String:
	match status:
		HTTPClient.STATUS_CANT_RESOLVE:
			return "Cannot resolve the API hostname."
		HTTPClient.STATUS_CANT_CONNECT:
			return "Cannot connect to the API host."
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return "TLS handshake with the API host failed."
		HTTPClient.STATUS_CONNECTION_ERROR:
			return "The API connection failed."
		_:
			return "The API connection closed unexpectedly."


func _status_category(status: HTTPClient.Status) -> String:
	if status == HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
		return "tls"
	if status == HTTPClient.STATUS_CANT_RESOLVE:
		return "dns"
	return "connection"
