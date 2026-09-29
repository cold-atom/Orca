extends SceneTree

const ContextBudget = preload("res://addons/orca/scripts/context_budget.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_unknown_limit()
	_test_complete_turn_compaction()
	_test_historical_tool_turn_compaction()
	_test_active_tool_group_is_indivisible()
	_test_repeated_compaction_notice()
	_test_oversized_active_turn_fails()
	_test_malformed_history_is_not_split()
	_finish()


func _test_unknown_limit() -> void:
	var messages := [{"role": "system", "content": "system"}, {"role": "user", "content": "current"}]
	var result := ContextBudget.prepare(messages, [], 0)
	_expect(result.get("success", false) and not result.get("compacted", true), "unknown context limits should continue without speculative compaction")
	_expect(result.get("messages") == messages, "unknown context limits should preserve exact history")


func _test_complete_turn_compaction() -> void:
	var messages := [
		{"role": "system", "content": "system"},
		{"role": "user", "content": "old-one " + "a".repeat(12000)},
		{"role": "assistant", "content": "old-answer-one"},
		{"role": "user", "content": "recent-user"},
		{"role": "assistant", "content": "recent-answer"},
		{"role": "system", "content": "current editor context"},
		{"role": "user", "content": "current-user"}
	]
	var result := ContextBudget.prepare(messages, _tools(), 4096)
	_expect(result.get("success", false) and result.get("compacted", false), "an oversized request should compact completed turns")
	var compacted: Array = result.get("messages", [])
	_expect(_contains_content(compacted, ContextBudget.COMPACTION_NOTICE), "compacted history should disclose omitted turns to the model")
	_expect(not _contains_content(compacted, "old-one "), "the oldest complete turn should be removed")
	_expect(_contains_content(compacted, "recent-user") and _contains_content(compacted, "recent-answer"), "newer complete turns should remain when they fit")
	_expect(_contains_content(compacted, "current editor context") and _contains_content(compacted, "current-user"), "request-scoped context and the active turn must remain")


func _test_active_tool_group_is_indivisible() -> void:
	var calls := [
		{"id": "call_a", "type": "function", "function": {"name": "read_file", "arguments": "{}"}},
		{"id": "call_b", "type": "function", "function": {"name": "search_files", "arguments": "{}"}}
	]
	var messages := [
		{"role": "system", "content": "system"},
		{"role": "user", "content": "old " + "x".repeat(12000)},
		{"role": "assistant", "content": "old answer"},
		{"role": "user", "content": "current"},
		{"role": "assistant", "content": "", "reasoning_content": "provider continuation", "tool_calls": calls},
		{"role": "tool", "tool_call_id": "call_a", "content": "first result"},
		{"role": "tool", "tool_call_id": "call_b", "content": "second result"}
	]
	var result := ContextBudget.prepare(messages, _tools(), 4096)
	_expect(result.get("success", false), "a request with a fitting active tool round should compact successfully")
	var compacted: Array = result.get("messages", [])
	_expect(_tool_result_count(compacted, "call_a") == 1 and _tool_result_count(compacted, "call_b") == 1, "all current tool results must remain")
	_expect(compacted.any(func(message): return message.get("role") == "assistant" and message.has("tool_calls") and message.get("reasoning_content") == "provider continuation"), "the assistant tool batch and provider continuation must remain")


func _test_historical_tool_turn_compaction() -> void:
	var call := {"id": "old_call", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
	var messages := [
		{"role": "system", "content": "system"},
		{"role": "user", "content": "old tool turn " + "q".repeat(12000)},
		{"role": "assistant", "content": "", "tool_calls": [call]},
		{"role": "tool", "tool_call_id": "old_call", "content": "old result"},
		{"role": "assistant", "content": "old final"},
		{"role": "user", "content": "current"}
	]
	var result := ContextBudget.prepare(messages, _tools(), 4096)
	_expect(result.get("success", false), "a complete historical tool turn should be removable")
	var compacted: Array = result.get("messages", [])
	_expect(not compacted.any(func(message): return message.has("tool_calls") or message.get("role") == "tool"), "historical assistant calls and matching results should be removed together")
	_expect(_contains_content(compacted, "current"), "historical tool compaction must preserve the active turn")


func _test_repeated_compaction_notice() -> void:
	var messages := [
		{"role": "system", "content": "system"},
		{"role": "system", "content": ContextBudget.COMPACTION_NOTICE},
		{"role": "user", "content": "old " + "z".repeat(12000)},
		{"role": "assistant", "content": "old answer"},
		{"role": "user", "content": "current"}
	]
	var result := ContextBudget.prepare(messages, _tools(), 4096)
	_expect(result.get("success", false), "already compacted history should compact again when needed")
	_expect(_content_count(result.get("messages", []), ContextBudget.COMPACTION_NOTICE) == 1, "repeated compaction must not duplicate its notice")


func _test_oversized_active_turn_fails() -> void:
	var messages := [{"role": "system", "content": "system"}, {"role": "user", "content": "x".repeat(20000)}]
	var result := ContextBudget.prepare(messages, _tools(), 4096)
	_expect(not result.get("success", true), "an active turn larger than the safe input budget should fail")
	_expect(result.get("messages") == messages, "budget failure must not partially mutate history")


func _test_malformed_history_is_not_split() -> void:
	var messages := [
		{"role": "system", "content": "system"},
		{"role": "user", "content": "old " + "m".repeat(12000)},
		{"role": "assistant", "content": "", "tool_calls": [{"id": "missing", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]},
		{"role": "user", "content": "current"}
	]
	var result := ContextBudget.prepare(messages, _tools(), 4096)
	_expect(not result.get("success", true), "malformed historical tool protocol should fail rather than split a tool group")
	_expect(result.get("messages") == messages, "malformed history failure must preserve exact history")


func _tools() -> Array:
	return [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}}]


func _contains_content(messages: Array, text: String) -> bool:
	return messages.any(func(message): return str(message.get("content", "")).contains(text))


func _content_count(messages: Array, text: String) -> int:
	var count := 0
	for message in messages:
		if str(message.get("content", "")) == text:
			count += 1
	return count


func _tool_result_count(messages: Array, call_id: String) -> int:
	var count := 0
	for message in messages:
		if message.get("role") == "tool" and message.get("tool_call_id") == call_id:
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("context_budget_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("context_budget_test: ", failure)
	quit(1)
