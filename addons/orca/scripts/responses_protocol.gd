@tool
extends RefCounted

# Stateless wire conversion. Opaque reasoning is bound to one profile, retained
# only during the active tool turn, and never becomes visible/session metadata.
const PRIVATE_FIELD := "_orca_responses"
const DeepSeekCompatibility = preload("res://addons/orca/scripts/deepseek_response_compatibility.gd")
const MAX_ITEMS := 64
const MAX_TEXT_BYTES := 2 * 1024 * 1024
const MAX_ARGUMENT_BYTES := 2 * 1024 * 1024
const MAX_REASONING_BYTES := 2 * 1024 * 1024
const MAX_ID_CHARS := 256


static func binding(config: Dictionary) -> String:
	return JSON.stringify([config.get("provider", ""), config.get("base_url", ""), config.get("model", ""), config.get("reasoning_effort", "default"), "responses", config.get("continuation_style", "standard"), DeepSeekCompatibility.FORMAT_VERSION if DeepSeekCompatibility.enabled(config) else 0]).sha256_text()


static func request_body(messages: Array, tools: Array, config: Dictionary, serial_tools: bool = false) -> Dictionary:
	var inputs: Array = []
	for message in messages:
		if typeof(message) != TYPE_DICTIONARY:
			return _failure("Invalid Responses input message.")
		var role: String = str(message.get("role", ""))
		var retained = message.get(PRIVATE_FIELD, {})
		if role == "assistant" and typeof(retained) == TYPE_DICTIONARY and retained.get("binding") == binding(config):
			var checked := _output(retained.get("items"), config)
			if not checked.get("success", false) or checked.get("content") != message.get("content", "") or checked.get("calls") != message.get("tool_calls", []):
				return _failure("Retained Responses continuation is invalid or no longer matches its assistant message.")
			inputs.append_array(checked["items"])
			continue
		if role == "tool":
			if not _identifier(message.get("tool_call_id")) or typeof(message.get("content")) != TYPE_STRING:
				return _failure("Invalid Responses function output.")
			inputs.append({"type": "function_call_output", "call_id": message["tool_call_id"], "output": message["content"]})
			continue
		if role not in ["system", "developer", "user", "assistant"]:
			return _failure("Unsupported Responses input role.")
		var content = message.get("content", "")
		if typeof(content) == TYPE_STRING:
			if role != "assistant" or not content.is_empty():
				inputs.append({"role": role, "content": content})
		elif typeof(content) == TYPE_ARRAY and role == "user":
			var parts: Array = []
			for part in content:
				if typeof(part) != TYPE_DICTIONARY:
					return _failure("Invalid Responses image/text input.")
				if part.get("type") == "text" and typeof(part.get("text")) == TYPE_STRING:
					parts.append({"type": "input_text", "text": part["text"]})
				elif part.get("type") == "image_url" and typeof(part.get("image_url")) == TYPE_DICTIONARY and typeof(part["image_url"].get("url")) == TYPE_STRING:
					parts.append({"type": "input_image", "image_url": part["image_url"]["url"], "detail": "auto"})
				else:
					return _failure("Unsupported Responses input part.")
			inputs.append({"role": role, "content": parts})
		else:
			return _failure("Invalid Responses input content.")
		var calls = message.get("tool_calls", [])
		if typeof(calls) != TYPE_ARRAY:
			return _failure("Invalid Responses input calls.")
		for call in calls:
			if role != "assistant" or typeof(call) != TYPE_DICTIONARY or call.get("type") != "function" or not _identifier(call.get("id")) or typeof(call.get("function")) != TYPE_DICTIONARY or not _identifier(call["function"].get("name")) or typeof(call["function"].get("arguments")) != TYPE_STRING:
				return _failure("Invalid Responses input function call.")
			inputs.append({"type": "function_call", "call_id": call["id"], "name": call["function"]["name"], "arguments": call["function"]["arguments"]})
	var converted_tools: Array = []
	for tool in tools:
		if typeof(tool) != TYPE_DICTIONARY or tool.get("type") != "function" or typeof(tool.get("function")) != TYPE_DICTIONARY:
			return _failure("Responses supports only Orca function tools.")
		var function: Dictionary = tool["function"]
		converted_tools.append({"type": "function", "name": function.get("name", ""), "description": function.get("description", ""), "parameters": function.get("parameters", {}), "strict": false})
	var body := {"model": config.get("model", ""), "input": inputs, "stream": true, "store": false, "include": ["reasoning.encrypted_content"], "truncation": "disabled", "max_output_tokens": 8192}
	if not converted_tools.is_empty():
		body["tools"] = converted_tools
		body["tool_choice"] = "auto"
		var external_tools: bool = converted_tools.any(func(tool): return tool.get("name") in ["blender_workspace", "inspect_mcp"])
		if (serial_tools or external_tools) and config.get("continuation_style", "standard") == "standard":
			body["parallel_tool_calls"] = false
	var effort: String = str(config.get("reasoning_effort", "default"))
	if not effort.is_empty() and effort != "default":
		body["reasoning"] = {"effort": effort}
	return {"success": true, "body": body}


static func completion(data: Dictionary, config: Dictionary) -> Dictionary:
	if data.get("status") != "completed" or data.get("error") != null or data.get("incomplete_details") != null:
		return _failure("Responses did not complete successfully (status: %s)." % str(data.get("status", "missing")).left(40))
	var output := _output(data.get("output"), config, true)
	if not output.get("success", false):
		return output
	if str(output["content"]).strip_edges().is_empty() and output["calls"].is_empty():
		return _failure("The provider completed without visible assistant content or a valid tool call.")
	var message := {"role": "assistant", "content": output["content"], PRIVATE_FIELD: {"binding": binding(config), "items": output["items"]}}
	if not output["calls"].is_empty():
		message["tool_calls"] = output["calls"]
	return {"success": true, "raw_content": output["raw_content"], "response": {"model": data.get("model", ""), "choices": [{"message": message, "finish_reason": "stop" if output["calls"].is_empty() else "tool_calls"}], "usage": data.get("usage", {})}}


static func _output(raw_items, config: Dictionary = {}, normalize_display: bool = false) -> Dictionary:
	if typeof(raw_items) != TYPE_ARRAY or raw_items.size() > MAX_ITEMS:
		return _failure("Responses output items exceeded the limit or have an invalid format.")
	var items: Array = []
	var calls: Array = []
	var text := ""
	var text_bytes := 0
	var argument_bytes := 0
	var reasoning_bytes := 0
	var ids := {}
	var call_ids := {}
	for raw in raw_items:
		if typeof(raw) != TYPE_DICTIONARY or not _identifier(raw.get("id")) or ids.has(raw["id"]):
			return _failure("Responses returned an invalid or duplicate output item ID.")
		ids[raw["id"]] = true
		var item := {"id": raw["id"], "type": raw.get("type", "")}
		match item["type"]:
			"reasoning":
				if raw.get("status") not in [null, "completed"]:
					return _failure("Responses returned incomplete reasoning state.")
				item["summary"] = [] # Never replay or display reasoning summaries.
				if raw.get("content") != null:
					if typeof(raw["content"]) != TYPE_ARRAY or raw["content"].size() > MAX_ITEMS:
						return _failure("Responses returned invalid reasoning content.")
					if not raw["content"].is_empty() and not DeepSeekCompatibility.enabled(config):
						return _failure("This response requires the explicit DeepSeek reasoning continuation setting.")
					if not raw["content"].is_empty():
						item["content"] = []
						for part in raw["content"]:
							if typeof(part) != TYPE_DICTIONARY or part.get("type") != "reasoning_text" or typeof(part.get("text")) != TYPE_STRING:
								return _failure("Responses returned unsupported DeepSeek reasoning content.")
							reasoning_bytes += part["text"].to_utf8_buffer().size()
							item["content"].append({"type": "reasoning_text", "text": part["text"]})
				if raw.get("encrypted_content") != null:
					if typeof(raw["encrypted_content"]) != TYPE_STRING:
						return _failure("Responses returned invalid encrypted reasoning.")
					reasoning_bytes += raw["encrypted_content"].to_utf8_buffer().size()
					item["encrypted_content"] = raw["encrypted_content"]
			"message":
				if raw.get("role") != "assistant" or raw.get("status", "completed") != "completed" or typeof(raw.get("content")) != TYPE_ARRAY or raw["content"].size() > MAX_ITEMS:
					return _failure("Responses returned an invalid or incomplete assistant message.")
				item["role"] = "assistant"
				item["content"] = []
				if raw.has("phase"):
					if raw["phase"] not in ["commentary", "final_answer"]:
						return _failure("Responses returned an invalid assistant phase.")
					item["phase"] = raw["phase"]
				for part in raw["content"]:
					if typeof(part) != TYPE_DICTIONARY or part.get("type") != "output_text" or typeof(part.get("text")) != TYPE_STRING:
						return _failure("Responses returned refused or unsupported assistant content.")
					text_bytes += part["text"].to_utf8_buffer().size()
					text += part["text"]
					item["content"].append({"type": "output_text", "text": part["text"], "annotations": []})
			"function_call":
				if raw.get("status", "completed") != "completed" or not _identifier(raw.get("call_id")) or call_ids.has(raw["call_id"]) or not _identifier(raw.get("name")) or typeof(raw.get("arguments")) != TYPE_STRING or calls.size() >= 16:
					return _failure("Responses returned invalid, duplicate, incomplete, or excessive function calls.")
				call_ids[raw["call_id"]] = true
				argument_bytes += raw["arguments"].to_utf8_buffer().size()
				item.merge({"call_id": raw["call_id"], "name": raw["name"], "arguments": raw["arguments"]})
				calls.append({"id": raw["call_id"], "type": "function", "function": {"name": raw["name"], "arguments": raw["arguments"]}})
			_:
				return _failure("Responses returned an unsupported output item; only Orca function tools are supported.")
		if text_bytes > MAX_TEXT_BYTES or argument_bytes > MAX_ARGUMENT_BYTES or reasoning_bytes > MAX_REASONING_BYTES:
			return _failure("Responses output exceeded the text, arguments, or reasoning limit.")
		items.append(item)
	var raw_text := text
	if normalize_display and DeepSeekCompatibility.enabled(config):
		var start := DeepSeekCompatibility.prefix_start(text)
		if start >= 0:
			text = DeepSeekCompatibility.normalize(text)
			var offset := 0
			for item in items:
				if item["type"] != "message":
					continue
				for part in item["content"]:
					var original: String = part["text"]
					var first := maxi(start, offset) - offset
					var last := mini(start + DeepSeekCompatibility.MARKER.length(), offset + original.length()) - offset
					if last > first:
						part["text"] = original.left(first) + original.substr(last)
					offset += original.length()
	return {"success": true, "items": items, "content": text, "raw_content": raw_text, "calls": calls}


static func _identifier(value) -> bool:
	if typeof(value) != TYPE_STRING or value.is_empty() or value.length() > MAX_ID_CHARS or value != value.strip_edges():
		return false
	for index in range(value.length()):
		if value.unicode_at(index) < 32:
			return false
	return true


static func _failure(message: String) -> Dictionary:
	return {"success": false, "error": message}
