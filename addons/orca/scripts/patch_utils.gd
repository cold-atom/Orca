@tool
extends RefCounted


static func apply_line_edits(content: String, edits: Array) -> Dictionary:
	if edits.is_empty():
		return {"success": false, "error": "At least one line edit is required."}
	var offsets := _line_offsets(content)
	var logical_line_count := 0 if content.is_empty() else offsets.size()
	var normalized: Array[Dictionary] = []
	for raw_edit in edits:
		if typeof(raw_edit) != TYPE_DICTIONARY:
			return {"success": false, "error": "Every edit must be an object."}
		var start_line := int(raw_edit.get("start_line", 0))
		var end_line := int(raw_edit.get("end_line", -1))
		var replacement := str(raw_edit.get("replacement", ""))
		if start_line < 1 or start_line > logical_line_count + 1:
			return {"success": false, "error": "start_line %d is outside the file." % start_line}
		if end_line < start_line - 1 or end_line > logical_line_count:
			return {"success": false, "error": "end_line %d is invalid for start_line %d." % [end_line, start_line]}
		normalized.append({"start_line": start_line, "end_line": end_line, "replacement": replacement})

	normalized.sort_custom(func(a, b): return a["start_line"] < b["start_line"])
	var previous_end := 0
	var previous_start := 0
	for edit in normalized:
		if edit["start_line"] <= previous_end or edit["start_line"] == previous_start:
			return {"success": false, "error": "Line edits overlap or are out of order."}
		previous_start = edit["start_line"]
		previous_end = maxi(previous_end, edit["end_line"])

	var result := content
	var line_separator := "\r\n" if content.contains("\r\n") else "\n"
	for index in range(normalized.size() - 1, -1, -1):
		var edit: Dictionary = normalized[index]
		var start_offset := _offset_for_line(offsets, edit["start_line"], content.length())
		var end_offset := start_offset
		if edit["end_line"] >= edit["start_line"]:
			end_offset = _offset_for_line(offsets, edit["end_line"] + 1, content.length())
		var replacement: String = edit["replacement"].replace("\r\n", "\n")
		if line_separator == "\r\n":
			replacement = replacement.replace("\n", "\r\n")
		var removed_text := content.substr(start_offset, end_offset - start_offset)
		var needs_line_boundary := end_offset < content.length() or removed_text.ends_with("\n")
		if start_offset == content.length() and edit["end_line"] < edit["start_line"] and not content.is_empty() and not replacement.is_empty() and not content.ends_with(line_separator):
			replacement = line_separator + replacement
		if needs_line_boundary and not replacement.is_empty() and not replacement.ends_with(line_separator):
			replacement += line_separator
		result = result.substr(0, start_offset) + replacement + result.substr(end_offset)
	return {"success": true, "content": result}


static func _line_offsets(content: String) -> PackedInt32Array:
	var offsets := PackedInt32Array([0])
	var search_from := 0
	while true:
		var newline := content.find("\n", search_from)
		if newline == -1:
			break
		if newline + 1 < content.length():
			offsets.append(newline + 1)
		search_from = newline + 1
	return offsets


static func _offset_for_line(offsets: PackedInt32Array, line: int, content_length: int) -> int:
	if line <= offsets.size():
		return offsets[line - 1]
	return content_length
