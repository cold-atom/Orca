@tool
extends RefCounted

const MAX_LCS_CELLS := 400000
const CONTEXT_LINES := 3


static func create_diff(old_content: String, new_content: String) -> Dictionary:
	var old_lines := _split_lines(old_content)
	var new_lines := _split_lines(new_content)
	var operations := _lcs_operations(old_lines, new_lines)
	if old_content.ends_with("\n") != new_content.ends_with("\n"):
		if new_content.ends_with("\n"):
			operations.append(_operation("add", "\\ No newline at end of previous file", 0, maxi(1, new_lines.size())))
		else:
			operations.append(_operation("remove", "\\ No newline at end of proposed file", maxi(1, old_lines.size()), 0))
	var additions := 0
	var deletions := 0
	for operation in operations:
		if operation["type"] == "add":
			additions += 1
		elif operation["type"] == "remove":
			deletions += 1

	return {
		"operations": operations,
		"display_operations": _with_context(operations),
		"additions": additions,
		"deletions": deletions
	}


static func _split_lines(content: String) -> PackedStringArray:
	if content.is_empty():
		return PackedStringArray()
	var lines := content.split("\n")
	if content.ends_with("\n") and not lines.is_empty():
		lines.remove_at(lines.size() - 1)
	return lines


static func _lcs_operations(old_lines: PackedStringArray, new_lines: PackedStringArray) -> Array:
	var old_count := old_lines.size()
	var new_count := new_lines.size()
	if old_count * new_count > MAX_LCS_CELLS:
		return _fallback_operations(old_lines, new_lines)

	var table: Array = []
	for old_index in range(old_count + 1):
		var row := PackedInt32Array()
		row.resize(new_count + 1)
		table.append(row)

	for old_index in range(old_count - 1, -1, -1):
		for new_index in range(new_count - 1, -1, -1):
			if old_lines[old_index] == new_lines[new_index]:
				table[old_index][new_index] = table[old_index + 1][new_index + 1] + 1
			else:
				table[old_index][new_index] = maxi(table[old_index + 1][new_index], table[old_index][new_index + 1])

	var operations: Array = []
	var old_index := 0
	var new_index := 0
	var old_line_number := 1
	var new_line_number := 1
	while old_index < old_count or new_index < new_count:
		if old_index < old_count and new_index < new_count and old_lines[old_index] == new_lines[new_index]:
			operations.append(_operation("context", old_lines[old_index], old_line_number, new_line_number))
			old_index += 1
			new_index += 1
			old_line_number += 1
			new_line_number += 1
		elif new_index < new_count and (old_index == old_count or table[old_index][new_index + 1] >= table[old_index + 1][new_index]):
			operations.append(_operation("add", new_lines[new_index], 0, new_line_number))
			new_index += 1
			new_line_number += 1
		else:
			operations.append(_operation("remove", old_lines[old_index], old_line_number, 0))
			old_index += 1
			old_line_number += 1
	return operations


static func _fallback_operations(old_lines: PackedStringArray, new_lines: PackedStringArray) -> Array:
	var prefix := 0
	while prefix < old_lines.size() and prefix < new_lines.size() and old_lines[prefix] == new_lines[prefix]:
		prefix += 1
	var suffix := 0
	while suffix < old_lines.size() - prefix and suffix < new_lines.size() - prefix:
		if old_lines[old_lines.size() - suffix - 1] != new_lines[new_lines.size() - suffix - 1]:
			break
		suffix += 1

	var operations: Array = []
	for index in range(prefix):
		operations.append(_operation("context", old_lines[index], index + 1, index + 1))
	for index in range(prefix, old_lines.size() - suffix):
		operations.append(_operation("remove", old_lines[index], index + 1, 0))
	for index in range(prefix, new_lines.size() - suffix):
		operations.append(_operation("add", new_lines[index], 0, index + 1))
	for offset in range(suffix):
		var old_index := old_lines.size() - suffix + offset
		var new_index := new_lines.size() - suffix + offset
		operations.append(_operation("context", old_lines[old_index], old_index + 1, new_index + 1))
	return operations


static func _with_context(operations: Array) -> Array:
	var visible: Dictionary = {}
	for index in range(operations.size()):
		if operations[index]["type"] == "context":
			continue
		for nearby in range(maxi(0, index - CONTEXT_LINES), mini(operations.size(), index + CONTEXT_LINES + 1)):
			visible[nearby] = true

	var display: Array = []
	var previous_index := -2
	var indices := visible.keys()
	indices.sort()
	for index in indices:
		if index > previous_index + 1:
			display.append({"type": "separator", "text": "...", "old_line": 0, "new_line": 0})
		display.append(operations[index])
		previous_index = index
	return display


static func _operation(type: String, text: String, old_line: int, new_line: int) -> Dictionary:
	return {"type": type, "text": text, "old_line": old_line, "new_line": new_line}
