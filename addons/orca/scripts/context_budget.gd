@tool
extends RefCounted

const COMPACTION_NOTICE := "ORCA CONTEXT NOTICE: Earlier completed conversation turns were omitted to stay within this model's context window. The current turn and all tool-call/result groups remain complete."
const TOKEN_BYTES := 3
const MESSAGE_OVERHEAD_TOKENS := 8
const TOOL_OVERHEAD_TOKENS := 24
const ImageAttachments = preload("res://addons/orca/scripts/image_attachments.gd")
const ScriptReferences = preload("res://addons/orca/scripts/script_references.gd")
const ResponsesProtocol = preload("res://addons/orca/scripts/responses_protocol.gd")


static func prepare(messages: Array, tools: Array, context_window: int, include_history_images: bool = true, hosted_output_tokens: int = 0, context_policy: Dictionary = {}, request_config: Dictionary = {}) -> Dictionary:
	var hosted := hosted_output_tokens > 0
	var original_estimate := estimate_tokens(messages, tools, include_history_images, hosted, context_policy, request_config)
	if context_window <= 0:
		return _result(true, messages, false, 0, original_estimate, 0, 0, 0)
	var final_reserve := hosted_output_tokens if hosted else clampi(context_window / 8, 512, 16384)
	var tool_reserve := clampi(context_window / (32 if hosted else 10), 512, 8192) if not tools.is_empty() else 0
	var input_budget := context_window - final_reserve - tool_reserve
	if input_budget <= 0:
		return _result(false, messages, false, 0, original_estimate, input_budget, final_reserve, tool_reserve, "The selected model's context window is too small for Orca's response reserves.")
	if original_estimate <= input_budget:
		return _result(true, messages, false, 0, original_estimate, input_budget, final_reserve, tool_reserve)

	var compacted := messages.duplicate(true)
	var marker_present := _has_notice(compacted)
	var removable_start := 2 if marker_present else 1
	var protected_start := _protected_turn_start(compacted, removable_start)
	var boundaries := _complete_turn_ends(compacted, removable_start, protected_start)
	var dropped_turns := 0
	var removed_count := 0
	for boundary in boundaries:
		removed_count = int(boundary) - removable_start
		dropped_turns += 1
		var candidate := compacted.duplicate(true)
		for index in range(int(boundary) - 1, removable_start - 1, -1):
			candidate.remove_at(index)
		if not marker_present:
			candidate.insert(1, {"role": "system", "content": COMPACTION_NOTICE})
		var estimate := estimate_tokens(candidate, tools, include_history_images, hosted, context_policy, request_config)
		if estimate <= input_budget:
			var inserted_count := 0 if marker_present else 1
			var result := _result(true, candidate, true, dropped_turns, estimate, input_budget, final_reserve, tool_reserve)
			result["removed_start"] = removable_start
			result["removed_count"] = removed_count
			result["inserted_count"] = inserted_count
			return result

	return _result(false, messages, false, 0, original_estimate, input_budget, final_reserve, tool_reserve, "The system prompt, tools, and current turn exceed the selected model's safe input budget. Shorten the prompt or choose a model with a larger context window.")


static func estimate_tokens(messages: Array, tools: Array, include_history_images: bool = true, hosted: bool = false, context_policy: Dictionary = {}, request_config: Dictionary = {}) -> int:
	var text_messages := ImageAttachments.project_messages(ScriptReferences.request_messages(messages), include_history_images)
	var image_tokens := 0
	var opaque_tokens := 0
	for message in text_messages:
		if typeof(message) != TYPE_DICTIONARY:
			continue
		for image in message.get("images", []):
			image_tokens += int(context_policy.get("image_tokens", 16384)) if hosted else ImageAttachments.image_token_reserve(image)
		message.erase("images")
		if hosted and context_policy.get("opaque_reasoning_bytes") == true and message.has("reasoning_content"):
			var packet := JSON.stringify({"reasoning_content": message["reasoning_content"]})
			opaque_tokens += packet.to_utf8_buffer().size() + packet.count(":") + packet.count(",")
			message.erase("reasoning_content")
	var serialized := JSON.stringify({"messages": text_messages, "tools": tools})
	if not hosted and request_config.get("api_mode") == "responses":
		# Estimate exactly the validated representation the adapter will send. The
		# canonical assistant contains both visible calls/text and retained items;
		# the wire uses the latter once. Compaction still operates on full history.
		var projected := ResponsesProtocol.request_body(text_messages, tools, request_config)
		if projected.get("success", false):
			serialized = JSON.stringify(projected["body"])
	var byte_count := serialized.to_utf8_buffer().size()
	if hosted:
		# Match the gateway's contextual estimate, not its separate byte-upper-bound
		# billing reservation. Opaque Responses continuation retains full byte cost.
		var contextual_bytes := byte_count + serialized.count(":") + serialized.count(",")
		return image_tokens + opaque_tokens + ceili(float(contextual_bytes) / 3.0) + messages.size() * 32 + tools.size() * 64
	return image_tokens + ceili(float(byte_count) / TOKEN_BYTES) + messages.size() * MESSAGE_OVERHEAD_TOKENS + tools.size() * TOOL_OVERHEAD_TOKENS


static func _protected_turn_start(messages: Array, minimum_index: int) -> int:
	var last_user := -1
	for index in range(messages.size() - 1, minimum_index - 1, -1):
		if _role(messages[index]) == "user":
			last_user = index
			break
	if last_user < 0:
		return messages.size()
	var start := last_user
	while start > minimum_index and _role(messages[start - 1]) == "system":
		start -= 1
	return start


static func _complete_turn_ends(messages: Array, start: int, end: int) -> PackedInt32Array:
	var boundaries := PackedInt32Array()
	var cursor := start
	while cursor < end:
		while cursor < end and _role(messages[cursor]) == "system":
			cursor += 1
		if cursor >= end or _role(messages[cursor]) != "user":
			break
		cursor += 1
		var completed := false
		while cursor < end:
			var message = messages[cursor]
			if _role(message) != "assistant":
				break
			var calls = message.get("tool_calls", []) if typeof(message) == TYPE_DICTIONARY else []
			cursor += 1
			if typeof(calls) == TYPE_ARRAY and not calls.is_empty():
				if not _consume_matching_results(messages, calls, cursor, end):
					return boundaries
				cursor += calls.size()
				continue
			completed = true
			boundaries.append(cursor)
			break
		if not completed:
			break
	return boundaries


static func _consume_matching_results(messages: Array, calls: Array, start: int, end: int) -> bool:
	if start + calls.size() > end:
		return false
	var expected := PackedStringArray()
	for call in calls:
		if typeof(call) != TYPE_DICTIONARY:
			return false
		var call_id := str(call.get("id", ""))
		if call_id.is_empty() or call_id in expected:
			return false
		expected.append(call_id)
	for offset in range(calls.size()):
		var message = messages[start + offset]
		if _role(message) != "tool" or str(message.get("tool_call_id", "")) not in expected:
			return false
		expected.erase(str(message.get("tool_call_id", "")))
	return expected.is_empty()


static func _has_notice(messages: Array) -> bool:
	return messages.size() > 1 and _role(messages[1]) == "system" and str(messages[1].get("content", "")) == COMPACTION_NOTICE


static func _role(message) -> String:
	return str(message.get("role", "")) if typeof(message) == TYPE_DICTIONARY else ""


static func _result(success: bool, messages: Array, compacted: bool, dropped_turns: int, estimated_tokens: int, input_budget: int, final_reserve: int, tool_reserve: int, error: String = "") -> Dictionary:
	return {
		"success": success,
		"messages": messages.duplicate(true),
		"compacted": compacted,
		"dropped_turns": dropped_turns,
		"estimated_tokens": estimated_tokens,
		"input_budget": input_budget,
		"final_reserve": final_reserve,
		"tool_reserve": tool_reserve,
		"error": error,
		"removed_start": -1,
		"removed_count": 0,
		"inserted_count": 0
	}
