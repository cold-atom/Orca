@tool
extends RefCounted

# Only wire projection/normalization. Orca owns tool execution and approvals.
const Provider = preload("res://addons/orca/scripts/providers/anthropic_provider.gd")
const PRIVATE_FIELD := "_orca_anthropic"
const FORMAT_VERSION := 1
const MAX_BLOCKS := 64
const MAX_CALLS := 16
const MAX_BYTES := 2 * 1024 * 1024
const MAX_MESSAGES := 2048
const MAX_INPUT_WORK := 8192

var _message: Dictionary = {}
var _blocks: Array = []
var _open_index := -1
var _arguments := ""
var _bytes := {"text": 0, "thinking": 0, "arguments": 0}
var _ended := false


static func binding(config: Dictionary) -> String:
	return JSON.stringify([FORMAT_VERSION, Provider.API_VERSION, config.get("provider", ""), config.get("base_url", ""), config.get("model", ""), config.get("reasoning_effort", "default"), "anthropic_messages"]).sha256_text()


static func request_body(messages: Array, tools: Array, config: Dictionary, serial_tools: bool = false) -> Dictionary:
	if messages.size() > MAX_MESSAGES or tools.size() > 128: return _failure("Anthropic request exceeds its message or schema limit.")
	var error := Provider.new().validate_config(config)
	if not error.is_empty(): return _failure(error)
	var system := PackedStringArray()
	var turns: Array = []
	var pending: Array[String] = []
	var results: Array = []
	var used_ids := {}
	for message in messages:
		if typeof(message) != TYPE_DICTIONARY: return _failure("Invalid Anthropic input message.")
		var role = message.get("role")
		if role == "system":
			if typeof(message.get("content")) != TYPE_STRING: return _failure("Invalid Anthropic system context.")
			system.append(message["content"])
			continue
		if role == "tool":
			var id = message.get("tool_call_id")
			if not _identifier(id) or id not in pending or typeof(message.get("content")) != TYPE_STRING: return _failure("Unmatched or invalid Anthropic tool result.")
			pending.erase(id)
			results.append({"type": "tool_result", "tool_use_id": id, "content": message["content"]})
			if pending.is_empty():
				_append_turn(turns, "user", results)
				results = []
			continue
		if not pending.is_empty(): return _failure("Anthropic tool calls require all matching results before another message.")
		if role not in ["user", "assistant"]: return _failure("Unsupported Anthropic input role.")
		var content: Array = []
		if role == "assistant" and message.has(PRIVATE_FIELD):
			var retained = message[PRIVATE_FIELD]
			if typeof(retained) != TYPE_DICTIONARY or retained.get("binding") != binding(config) or typeof(retained.get("blocks")) != TYPE_ARRAY: return _failure("Anthropic private continuation belongs to another profile.")
			if retained.get("digest") != JSON.stringify(retained["blocks"]).sha256_text(): return _failure("Anthropic private continuation changed.")
			var checked := _checked_blocks(retained["blocks"])
			if not checked.get("success", false) or checked.get("text") != message.get("content", "") or checked.get("calls") != message.get("tool_calls", []): return _failure("Anthropic private continuation no longer matches its assistant message.")
			content = checked["blocks"]
		else:
			var source = message.get("content", "")
			if typeof(source) == TYPE_STRING:
				if not source.is_empty(): content.append({"type": "text", "text": source})
			elif typeof(source) == TYPE_ARRAY and role == "user":
				if source.size() > 16: return _failure("Too many Anthropic image/text parts.")
				for part in source:
					if typeof(part) != TYPE_DICTIONARY: return _failure("Invalid Anthropic image/text part.")
					if part.get("type") == "text" and typeof(part.get("text")) == TYPE_STRING:
						if not part["text"].is_empty(): content.append({"type": "text", "text": part["text"]})
					elif part.get("type") == "image_url" and typeof(part.get("image_url")) == TYPE_DICTIONARY and typeof(part["image_url"].get("url")) == TYPE_STRING:
						var url: String = part["image_url"]["url"]
						var split := url.find(";base64,")
						if not url.begins_with("data:image/") or split < 0 or url.substr(5, split - 5) not in ["image/png", "image/jpeg", "image/webp"]: return _failure("Anthropic accepts only Orca's validated inline still images.")
						content.append({"type": "image", "source": {"type": "base64", "media_type": url.substr(5, split - 5), "data": url.substr(split + 8)}})
					else: return _failure("Unsupported Anthropic input content block.")
			else: return _failure("Invalid Anthropic message content.")
			var calls = message.get("tool_calls", [])
			if typeof(calls) != TYPE_ARRAY or calls.size() > MAX_CALLS or (role != "assistant" and not calls.is_empty()): return _failure("Invalid Anthropic input calls.")
			for call in calls:
				if typeof(call) != TYPE_DICTIONARY or call.get("type") != "function" or not _identifier(call.get("id")) or typeof(call.get("function")) != TYPE_DICTIONARY or not _identifier(call["function"].get("name")): return _failure("Invalid Anthropic function call.")
				var input := _parse_input(call["function"].get("arguments"))
				if not input.get("success", false): return input
				content.append({"type": "tool_use", "id": call["id"], "name": call["function"]["name"], "input": input["input"]})
		for block in content:
			if block["type"] != "tool_use": continue
			if used_ids.has(block["id"]): return _failure("Duplicate Anthropic tool-use ID.")
			used_ids[block["id"]] = true
			pending.append(block["id"])
		if not content.is_empty(): _append_turn(turns, role, content)
	if not pending.is_empty(): return _failure("Anthropic request is missing tool results.")
	if turns.is_empty() or turns[-1]["role"] != "user": return _failure("Anthropic request must end with a user message or matching tool results.")
	var schemas: Array = []
	for tool in tools:
		if typeof(tool) != TYPE_DICTIONARY or tool.get("type") != "function" or typeof(tool.get("function")) != TYPE_DICTIONARY: return _failure("Anthropic supports only Orca function tools.")
		var function: Dictionary = tool["function"]
		if not _identifier(function.get("name")) or typeof(function.get("parameters")) != TYPE_DICTIONARY: return _failure("Invalid Anthropic function schema.")
		schemas.append({"name": function["name"], "description": function.get("description", ""), "input_schema": function["parameters"]})
	var body := {"model": config.get("model", ""), "messages": turns, "stream": true, "max_tokens": 8192}
	if not system.is_empty(): body["system"] = "\n\n".join(system)
	if not schemas.is_empty():
		body["tools"] = schemas
		body["tool_choice"] = {"type": "auto"}
		if serial_tools: body["tool_choice"]["disable_parallel_tool_use"] = true
	Provider.new().apply_chat_options(body, str(config.get("reasoning_effort", "default")))
	return {"success": true, "body": body}


static func _append_turn(turns: Array, role: String, blocks: Array) -> void:
	if not turns.is_empty() and turns[-1]["role"] == role: turns[-1]["content"].append_array(blocks.duplicate(true))
	else: turns.append({"role": role, "content": blocks.duplicate(true)})


static func completion(data: Dictionary, config: Dictionary) -> Dictionary:
	if data.get("type") != "message" or data.get("role") != "assistant" or not _identifier(data.get("id")) or not _model_matches(config.get("model"), data.get("model")): return _failure("Invalid or mismatched Anthropic completion identity.")
	var checked := _checked_blocks(data.get("content"))
	if not checked.get("success", false): return checked
	var reason = data.get("stop_reason")
	if reason not in ["end_turn", "tool_use"] or (reason == "tool_use") != (not checked["calls"].is_empty()): return _failure("Anthropic response is incomplete, refused, or has a contradictory stop reason.")
	if str(checked["text"]).strip_edges().is_empty() and checked["calls"].is_empty(): return _failure("Anthropic completed without visible text or a valid tool call.")
	var usage = data.get("usage", {})
	if typeof(usage) != TYPE_DICTIONARY: return _failure("Invalid Anthropic usage.")
	for key in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]:
		if usage.has(key) and not _integer(usage[key], 0, 1000000000): return _failure("Invalid Anthropic token count.")
	var message := {"role": "assistant", "content": checked["text"]}
	if not checked["calls"].is_empty():
		message["tool_calls"] = checked["calls"]
		message[PRIVATE_FIELD] = {"binding": binding(config), "blocks": checked["blocks"], "digest": JSON.stringify(checked["blocks"]).sha256_text()}
	return {"success": true, "response": {"model": data["model"], "choices": [{"message": message, "finish_reason": "tool_calls" if reason == "tool_use" else "stop"}], "usage": usage.duplicate(true)}}


static func _checked_blocks(raw) -> Dictionary:
	if typeof(raw) != TYPE_ARRAY or raw.size() > MAX_BLOCKS: return _failure("Anthropic content blocks exceed their limit or are invalid.")
	var blocks: Array = []
	var calls: Array = []
	var text := ""
	var thinking_bytes := 0
	var argument_bytes := 0
	var ids := {}
	for source in raw:
		if typeof(source) != TYPE_DICTIONARY: return _failure("Invalid Anthropic content block.")
		var block := {"type": source.get("type")}
		match block["type"]:
			"text":
				if typeof(source.get("text")) != TYPE_STRING or typeof(source.get("citations", [])) != TYPE_ARRAY or not source.get("citations", []).is_empty(): return _failure("Unsupported Anthropic text block.")
				block["text"] = source["text"]
				text += source["text"]
			"thinking":
				if typeof(source.get("thinking")) != TYPE_STRING or typeof(source.get("signature")) != TYPE_STRING or source["signature"].is_empty(): return _failure("Anthropic thinking is missing its signature.")
				block.merge({"thinking": source["thinking"], "signature": source["signature"]})
				thinking_bytes += source["thinking"].to_utf8_buffer().size() + source["signature"].to_utf8_buffer().size()
			"redacted_thinking":
				if typeof(source.get("data")) != TYPE_STRING or source["data"].is_empty(): return _failure("Invalid Anthropic redacted thinking.")
				block["data"] = source["data"]
				thinking_bytes += source["data"].to_utf8_buffer().size()
			"tool_use":
				if not _identifier(source.get("id")) or ids.has(source["id"]) or not _identifier(source.get("name")) or typeof(source.get("input")) != TYPE_DICTIONARY or calls.size() >= MAX_CALLS: return _failure("Invalid, duplicate, or excessive Anthropic tool use.")
				if source.has("caller") and source["caller"] != {"type": "direct"}: return _failure("Anthropic server-executed tool calls are unsupported.")
				var work := [0]
				if not _bounded_value(source["input"], work): return _failure("Anthropic tool input exceeds its work limit.")
				var arguments := JSON.stringify(source["input"])
				argument_bytes += arguments.to_utf8_buffer().size()
				ids[source["id"]] = true
				block.merge({"id": source["id"], "name": source["name"], "input": source["input"].duplicate(true)})
				calls.append({"id": source["id"], "type": "function", "function": {"name": source["name"], "arguments": arguments}})
			_: return _failure("Unsupported Anthropic content; only Orca function tools are accepted.")
		if text.to_utf8_buffer().size() > MAX_BYTES or thinking_bytes > MAX_BYTES or argument_bytes > MAX_BYTES: return _failure("Anthropic text, thinking, or arguments exceeded their byte limit.")
		blocks.append(block)
	return {"success": true, "blocks": blocks, "calls": calls, "text": text}


func consume(data: Dictionary, config: Dictionary) -> Dictionary:
	var type = data.get("type")
	if type == "error": return _failure("Anthropic returned a streaming error.")
	if _ended: return _failure("Anthropic emitted content after completion.")
	if type == "ping": return {"success": true}
	if type == "message_start":
		var message = data.get("message")
		if not _message.is_empty() or typeof(message) != TYPE_DICTIONARY or message.get("type") != "message" or message.get("role") != "assistant" or not _identifier(message.get("id")) or not _model_matches(config.get("model"), message.get("model")) or message.get("content") != [] or message.get("stop_reason") != null or typeof(message.get("usage", {})) != TYPE_DICTIONARY: return _failure("Invalid or mismatched Anthropic stream start.")
		_message = {"type": "message", "id": message["id"], "role": "assistant", "model": message["model"], "usage": message.get("usage", {}).duplicate(true), "stop_reason": null}
		return {"success": true}
	if type not in ["content_block_start", "content_block_delta", "content_block_stop", "message_delta", "message_stop"]: return {"success": true}
	if _message.is_empty(): return _failure("Anthropic content arrived before message_start.")
	if type == "content_block_start":
		var index = data.get("index")
		var block = data.get("content_block")
		if not _integer(index, 0, MAX_BLOCKS - 1) or index != _blocks.size() or _open_index != -1 or _message["stop_reason"] != null or typeof(block) != TYPE_DICTIONARY or block.get("type") not in ["text", "thinking", "redacted_thinking", "tool_use"]: return _failure("Invalid Anthropic block start or unsupported content.")
		_blocks.append(block.duplicate(true))
		_open_index = int(index)
		_arguments = ""
		var visible := ""
		if block["type"] == "text":
			if typeof(block.get("text")) != TYPE_STRING: return _failure("Invalid Anthropic text start.")
			visible = block["text"]
			_bytes["text"] += visible.to_utf8_buffer().size()
		elif block["type"] == "thinking":
			if typeof(block.get("thinking")) != TYPE_STRING or typeof(block.get("signature")) != TYPE_STRING: return _failure("Invalid Anthropic thinking start.")
			_bytes["thinking"] += block["thinking"].to_utf8_buffer().size() + block["signature"].to_utf8_buffer().size()
		elif block["type"] == "redacted_thinking":
			if typeof(block.get("data")) != TYPE_STRING: return _failure("Invalid Anthropic redacted thinking start.")
			_bytes["thinking"] += block["data"].to_utf8_buffer().size()
		elif typeof(block.get("input")) != TYPE_DICTIONARY: return _failure("Invalid Anthropic tool start.")
		if not _within_bytes(): return _failure("Anthropic stream exceeded a content byte limit.")
		return {"success": true, "text": visible, "partial": true}
	if type in ["content_block_delta", "content_block_stop"]:
		if not _integer(data.get("index"), 0, MAX_BLOCKS - 1) or data["index"] != _open_index: return _failure("Anthropic block delta/stop has no matching open block.")
		var block: Dictionary = _blocks[_open_index]
		if type == "content_block_stop":
			if block["type"] == "tool_use" and not _arguments.is_empty():
				if not block["input"].is_empty(): return _failure("Anthropic tool input conflicts with streamed arguments.")
				var parsed := _parse_input(_arguments)
				if not parsed.get("success", false): return parsed
				block["input"] = parsed["input"]
			_open_index = -1
			_arguments = ""
			return {"success": true}
		var delta = data.get("delta")
		if typeof(delta) != TYPE_DICTIONARY: return _failure("Invalid Anthropic block delta.")
		var field := ""
		var bucket := ""
		if block["type"] == "text" and delta.get("type") == "text_delta":
			field = "text"
			bucket = "text"
		elif block["type"] == "thinking" and delta.get("type") in ["thinking_delta", "signature_delta"]:
			field = "thinking" if delta["type"] == "thinking_delta" else "signature"
			bucket = "thinking"
		elif block["type"] == "tool_use" and delta.get("type") == "input_json_delta":
			field = "partial_json"
			bucket = "arguments"
		else: return _failure("Anthropic delta does not match its content block.")
		if typeof(delta.get(field)) != TYPE_STRING: return _failure("Invalid Anthropic delta text.")
		_bytes[bucket] += delta[field].to_utf8_buffer().size()
		if not _within_bytes(): return _failure("Anthropic stream exceeded a content byte limit.")
		if field == "partial_json": _arguments += delta[field]
		else: block[field] += delta[field]
		return {"success": true, "text": delta[field] if field == "text" else ""}
	if _open_index != -1: return _failure("Anthropic ended with an incomplete content block.")
	if type == "message_delta":
		var delta = data.get("delta")
		if typeof(delta) != TYPE_DICTIONARY or typeof(data.get("usage", {})) != TYPE_DICTIONARY: return _failure("Invalid Anthropic message delta.")
		if delta.get("stop_reason") != null:
			if _message["stop_reason"] != null: return _failure("Duplicate Anthropic stop reason.")
			_message["stop_reason"] = delta["stop_reason"]
		_message["usage"].merge(data.get("usage", {}), true)
		return {"success": true}
	_ended = true
	_message["content"] = _blocks
	return completion(_message, config)


func _within_bytes() -> bool:
	return _bytes.values().all(func(value): return value <= MAX_BYTES)


static func _parse_input(raw) -> Dictionary:
	if typeof(raw) != TYPE_STRING or raw.to_utf8_buffer().size() > MAX_BYTES: return _failure("Anthropic tool arguments are invalid or oversized.")
	# Bound nesting before the native JSON parser allocates a nested object graph.
	var depth := 0
	var quoted := false
	var escaped := false
	for character in raw:
		if quoted:
			if escaped: escaped = false
			elif character == "\\": escaped = true
			elif character == "\"": quoted = false
		elif character == "\"": quoted = true
		elif character in ["{", "["]:
			depth += 1
			if depth > 16: return _failure("Anthropic tool arguments exceed their nesting limit.")
		elif character in ["}", "]"]: depth -= 1
	var parser := JSON.new()
	if parser.parse(raw) != OK: return _failure("Anthropic tool arguments must be a valid JSON object.")
	var input = parser.data
	var work := [0]
	if typeof(input) != TYPE_DICTIONARY or not _bounded_value(input, work): return _failure("Anthropic tool arguments must be a bounded JSON object.")
	return {"success": true, "input": input}


static func _bounded_value(value, work: Array, depth: int = 0) -> bool:
	work[0] += 1
	if work[0] > MAX_INPUT_WORK or depth > 16: return false
	if typeof(value) == TYPE_FLOAT and not is_finite(value): return false
	if typeof(value) not in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_ARRAY, TYPE_DICTIONARY]: return false
	if typeof(value) in [TYPE_ARRAY, TYPE_DICTIONARY]:
		if value.size() > MAX_INPUT_WORK - work[0]: return false
		for key in value:
			if not _bounded_value(value[key] if typeof(value) == TYPE_DICTIONARY else key, work, depth + 1): return false
	return true


static func _identifier(value) -> bool:
	if typeof(value) != TYPE_STRING or value.is_empty() or value.length() > 256: return false
	for character in value:
		if not "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains(character): return false
	return true


static func _model_matches(requested, returned) -> bool:
	if not _identifier(requested) or not _identifier(returned): return false
	if requested == returned: return true
	var suffix: String = str(returned).trim_prefix(str(requested) + "-")
	return str(returned).begins_with(str(requested) + "-") and suffix.length() == 8 and suffix.is_valid_int()


static func _integer(value, minimum: int, maximum: int) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and float(value) == floor(float(value)) and value >= minimum and value <= maximum


static func _failure(error: String) -> Dictionary:
	return {"success": false, "error": error}
