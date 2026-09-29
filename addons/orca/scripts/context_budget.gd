@tool
extends RefCounted

const COMPACTION_NOTICE := "ORCA CONTEXT NOTICE: Earlier completed conversation turns were omitted to stay within this model's context window. The current turn and all tool-call/result groups remain complete."
const TOKEN_BYTES := 3
const MESSAGE_OVERHEAD_TOKENS := 8
const TOOL_OVERHEAD_TOKENS := 24


static func prepare(messages: Array, tools: Array, context_window: int) -> Dictionary:
	var original_estimate := estimate_tokens(messages, tools)
	if context_window <= 0:
		return _result(true, messages, false, 0, original_estimate, 0, 0, 0)
	var final_reserve := clampi(context_window / 8, 512, 16384)
	var tool_reserve := clampi(context_window / 10, 512, 8192) if not tools.is_empty() else 0
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
		var estimate := estimate_tokens(candidate, tools)
		if estimate <= input_budget:
			var inserted_count := 0 if marker_present else 1
			var result := _result(true, candidate, true, dropped_turns, estimate, input_budget, final_reserve, tool_reserve)
			result["removed_start"] = removable_start
			result["removed_count"] = removed_count
			result["inserted_count"] = inserted_count
			return result

	return _result(false, messages, false, 0, original_estimate, input_budget, final_reserve, tool_reserve, "The system prompt, tools, and current turn exceed the selected model's safe input budget. Shorten the prompt or choose a model with a larger context window.")


static func estimate_tokens(messages: Array, tools: Array) -> int:
	var serialized := JSON.stringify({"messages": messages, "tools": tools})
	var byte_count := serialized.to_utf8_buffer().size()
	return ceili(float(byte_count) / TOKEN_BYTES) + messages.size() * MESSAGE_OVERHEAD_TOKENS + tools.size() * TOOL_OVERHEAD_TOKENS


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
