@tool
extends RefCounted

const MAX_TASKS := 20
const MAX_CONTENT_CHARS := 240
const ALLOWED_STATUSES := ["pending", "in_progress", "completed", "blocked", "cancelled"]


static func validate_tasks(raw) -> Dictionary:
	if typeof(raw) != TYPE_ARRAY:
		return {"success": false, "error": "tasks must be an array."}
	if raw.size() > MAX_TASKS:
		return {"success": false, "error": "Task checklists are limited to %d items." % MAX_TASKS}
	var tasks: Array[Dictionary] = []
	var active_count := 0
	for index in range(raw.size()):
		var item = raw[index]
		if typeof(item) != TYPE_DICTIONARY:
			return {"success": false, "error": "Task %d must be an object." % (index + 1)}
		if typeof(item.get("content")) != TYPE_STRING:
			return {"success": false, "error": "Task %d content must be text." % (index + 1)}
		var content := str(item.get("content", "")).strip_edges()
		if content.is_empty():
			return {"success": false, "error": "Task %d content cannot be empty." % (index + 1)}
		if content.length() > MAX_CONTENT_CHARS:
			return {"success": false, "error": "Task %d exceeds the %d-character limit." % [index + 1, MAX_CONTENT_CHARS]}
		var status = item.get("status")
		if typeof(status) != TYPE_STRING or str(status) not in ALLOWED_STATUSES:
			return {"success": false, "error": "Task %d has an invalid status." % (index + 1)}
		if status == "in_progress":
			active_count += 1
			if active_count > 1:
				return {"success": false, "error": "Only one task can be in progress."}
		tasks.append({"content": content, "status": str(status)})
	return {"success": true, "tasks": tasks}


static func sanitize_tasks(raw) -> Array:
	var tasks: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return tasks
	var has_active := false
	for raw_item in raw.slice(0, MAX_TASKS):
		if typeof(raw_item) != TYPE_DICTIONARY or typeof(raw_item.get("content")) != TYPE_STRING:
			continue
		var content := str(raw_item.get("content", "")).strip_edges().left(MAX_CONTENT_CHARS)
		if content.is_empty():
			continue
		var status := str(raw_item.get("status", "pending"))
		if status not in ALLOWED_STATUSES:
			status = "pending"
		if status == "in_progress":
			if has_active:
				status = "pending"
			else:
				has_active = true
		tasks.append({"content": content, "status": status})
	return tasks
