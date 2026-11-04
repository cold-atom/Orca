@tool
extends RefCounted

const Tools = preload("res://addons/orca/scripts/tools.gd")
const MAX_RECORDS := 64
const MAX_SOURCE_BYTES := 256 * 1024
const MAX_SOURCE_LINES := 8000
const MAX_JOURNAL_BYTES := 4 * 1024 * 1024
const STATES := ["prepared", "applied", "applied_recovery", "failed", "apply_recovery_required", "reverting", "reverted", "reverted_recovery", "revert_failed", "revert_recovery_required"]
const FIELDS := ["version", "id", "filepath", "old_content", "new_content", "old_hash", "new_hash", "existed", "status", "additions", "deletions"]


static func eligible(proposal: Dictionary) -> bool:
	if proposal.get("kind") != "file_patch" or proposal.get("tool_name") != "apply_patch":
		return false
	var path := str(proposal.get("filepath", ""))
	if not path.begins_with("res://") or path.get_extension() != "gd" or path.begins_with("res://addons/"):
		return false
	if not Tools._validate_path(path, true).is_empty() or path != Tools._canonical_project_path(path):
		return false
	for field in ["old_content", "new_content"]:
		if typeof(proposal.get(field)) != TYPE_STRING or not _bounded_source(proposal[field]):
			return false
	return true


static func prepare(proposal: Dictionary) -> Dictionary:
	if not eligible(proposal):
		return {}
	var record := {
		"version": 1,
		"id": "script_change_%s" % Crypto.new().generate_random_bytes(16).hex_encode(),
		"filepath": proposal["filepath"],
		"old_content": proposal["old_content"],
		"new_content": proposal["new_content"],
		"old_hash": proposal["old_hash"],
		"new_hash": proposal["new_hash"],
		"existed": proposal["existed"],
		"status": "prepared",
		"additions": proposal.get("diff", {}).get("additions", 0),
		"deletions": proposal.get("diff", {}).get("deletions", 0)
	}
	return record if validate_record(record).is_empty() else {}


static func validate_record(raw) -> String:
	if typeof(raw) != TYPE_DICTIONARY or raw.size() != FIELDS.size():
		return "Invalid script-change checkpoint fields."
	for field in FIELDS:
		if not raw.has(field):
			return "Missing script-change checkpoint field."
	if not _integer(raw["version"], 1, 1) or typeof(raw["existed"]) != TYPE_BOOL:
		return "Invalid script-change checkpoint version or existence."
	if typeof(raw["id"]) != TYPE_STRING or not _valid_id(raw["id"]):
		return "Invalid script-change checkpoint identity."
	if typeof(raw["status"]) != TYPE_STRING or raw["status"] not in STATES:
		return "Invalid script-change checkpoint state."
	for field in ["filepath", "old_content", "new_content", "old_hash", "new_hash"]:
		if typeof(raw[field]) != TYPE_STRING:
			return "Invalid script-change checkpoint content type."
	var path: String = raw["filepath"]
	# Validation is lexical here: historical checkpoints survive moved/deleted
	# files. Live path/symlink and editor checks are repeated before recovery.
	if path.length() > 512 or not path.begins_with("res://") or path.get_extension() != "gd" or path.begins_with("res://addons/") or path != Tools._canonical_project_path(path) or path.begins_with("res://.orca-update/"):
		return "Invalid script-change checkpoint project path."
	for field in ["old_content", "new_content"]:
		if not _bounded_source(raw[field]):
			return "Script-change checkpoint source exceeds its bounds."
	if raw["old_content"].sha256_text() != raw["old_hash"] or raw["new_content"].sha256_text() != raw["new_hash"] or (not raw["existed"] and not raw["old_content"].is_empty()):
		return "Script-change checkpoint hashes do not match its source."
	for field in ["additions", "deletions"]:
		if not _integer(raw[field], 0, MAX_SOURCE_LINES * 2 + 2):
			return "Invalid script-change checkpoint line counts."
	return ""


static func validate_records(raw) -> String:
	if typeof(raw) != TYPE_ARRAY or raw.size() > MAX_RECORDS:
		return "Script-change recovery is limited to 64 checkpoints per conversation. Start a new session."
	var ids := {}
	for record in raw:
		var error := validate_record(record)
		if not error.is_empty():
			return error
		if ids.has(record["id"]):
			return "Duplicate script-change checkpoint identity."
		ids[record["id"]] = true
	if JSON.stringify(raw, "  ").to_utf8_buffer().size() > MAX_JOURNAL_BYTES:
		return "Script-change recovery has reached its 4 MiB limit. Start a new session."
	return ""


static func proposal_for_recovery(record: Dictionary) -> Dictionary:
	if not validate_record(record).is_empty():
		return {}
	var proposal := record.duplicate(true)
	proposal["kind"] = "file_patch"
	proposal["tool_name"] = "apply_patch"
	proposal["_checkpoint_id"] = record["id"]
	proposal["_auto_apply"] = true
	proposal["_lazy_diff"] = true
	proposal["diff"] = {"additions": int(record["additions"]), "deletions": int(record["deletions"])}
	proposal["validation"] = {"message": "Saved automatic-edit checkpoint"}
	proposal["exact_applied_state"] = record["status"] in ["applied", "applied_recovery", "revert_failed"]
	if record["status"] in ["prepared", "reverting", "apply_recovery_required", "revert_recovery_required"]:
		proposal["status"] = "interrupted"
	return proposal


static func inspect_current(record: Dictionary) -> Dictionary:
	var error := validate_record(record)
	if error.is_empty():
		error = Tools._validate_path(record["filepath"], true)
	if not error.is_empty():
		return {"state": "conflict", "error": error}
	var exists := FileAccess.file_exists(record["filepath"])
	if not exists:
		return {"state": "original" if not record["existed"] else "conflict", "error": "The checkpoint's file is missing."}
	var file := FileAccess.open(record["filepath"], FileAccess.READ)
	if file == null or file.get_length() > MAX_SOURCE_BYTES:
		return {"state": "conflict", "error": "The current file is unavailable or exceeds the checkpoint read limit."}
	var content := file.get_buffer(file.get_length())
	if content == record["new_content"].to_utf8_buffer():
		return {"state": "applied"}
	if record["existed"] and content == record["old_content"].to_utf8_buffer():
		return {"state": "original"}
	return {"state": "conflict", "error": "The file differs from both checkpoint versions. Newer work has been preserved."}


static func _bounded_source(source: String) -> bool:
	if source.length() > MAX_SOURCE_BYTES:
		return false
	var bytes := source.to_utf8_buffer()
	var lines := source.count("\n") + (1 if not source.is_empty() and not source.ends_with("\n") else 0)
	return bytes.size() <= MAX_SOURCE_BYTES and not bytes.has(0) and lines <= MAX_SOURCE_LINES


static func _integer(value, minimum: int, maximum: int) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and float(value) == floorf(float(value)) and float(value) >= minimum and float(value) <= maximum


static func _valid_id(id: String) -> bool:
	if not id.begins_with("script_change_") or id.length() != 46:
		return false
	for character in id.trim_prefix("script_change_"):
		if character not in "0123456789abcdef":
			return false
	return true
