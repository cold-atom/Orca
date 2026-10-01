class_name ToolLoopGuard
extends RefCounted

const IDENTICAL_CALL_RESULT_THRESHOLD := 3
const ALTERNATING_CYCLE_LENGTH := 6
const IDENTICAL_ROUND_THRESHOLD := 3
const NO_PROGRESS_ROUND_THRESHOLD := 4

const REASON_IDENTICAL_CALL_RESULT := "identical_call_result"
const REASON_ALTERNATING_CALL_CYCLE := "alternating_call_cycle"
const REASON_IDENTICAL_ROUND := "identical_round"
const REASON_NO_PROGRESS := "no_progress"

var _call_fingerprints := PackedStringArray()
var _round_fingerprints := PackedStringArray()
var _last_progress_epoch := 0
var _has_progress_epoch := false
var _no_progress_rounds := 0
var _trigger := {}


func _init() -> void:
	reset()


func reset() -> void:
	_call_fingerprints.clear()
	_round_fingerprints.clear()
	_last_progress_epoch = 0
	_has_progress_epoch = false
	_no_progress_rounds = 0
	_trigger = {}


func record_round(calls: Array, progress_epoch: int) -> Dictionary:
	if not _trigger.is_empty():
		return _trigger.duplicate(true)

	var round_calls := PackedStringArray()
	var call_trigger := {}
	for call_value in calls:
		var call: Dictionary = call_value if call_value is Dictionary else {}
		var call_fingerprint := fingerprint({
			"arguments": fingerprint(call.get("arguments")),
			"name": fingerprint(call.get("name", "")),
			"outcome": fingerprint(call.get("outcome")),
			"progress_epoch": progress_epoch,
			"result": fingerprint(call.get("result")),
		})
		_call_fingerprints.append(call_fingerprint)
		round_calls.append(call_fingerprint)
		if call_trigger.is_empty():
			call_trigger = _detect_call_loop()

	var round_fingerprint := fingerprint({
		"calls": Array(round_calls),
		"progress_epoch": progress_epoch,
	})
	_round_fingerprints.append(round_fingerprint)
	var round_trigger := _detect_round_loop()
	var progress_trigger := _record_progress(progress_epoch)

	if not call_trigger.is_empty():
		_trigger = call_trigger
	elif not round_trigger.is_empty():
		_trigger = round_trigger
	elif not progress_trigger.is_empty():
		_trigger = progress_trigger

	if _trigger.is_empty():
		return {"triggered": false, "reason": ""}
	return _trigger.duplicate(true)


static func fingerprint(value: Variant) -> String:
	return _canonicalize(value).sha256_text()


func _detect_call_loop() -> Dictionary:
	var call_count := _call_fingerprints.size()
	if call_count >= IDENTICAL_CALL_RESULT_THRESHOLD:
		var latest := _call_fingerprints[call_count - 1]
		var identical := true
		for offset in range(2, IDENTICAL_CALL_RESULT_THRESHOLD + 1):
			if _call_fingerprints[call_count - offset] != latest:
				identical = false
				break
		if identical:
			return _make_trigger(REASON_IDENTICAL_CALL_RESULT, IDENTICAL_CALL_RESULT_THRESHOLD)

	if call_count >= ALTERNATING_CYCLE_LENGTH:
		var start := call_count - ALTERNATING_CYCLE_LENGTH
		var first := _call_fingerprints[start]
		var second := _call_fingerprints[start + 1]
		if first != second \
				and first == _call_fingerprints[start + 2] \
				and first == _call_fingerprints[start + 4] \
				and second == _call_fingerprints[start + 3] \
				and second == _call_fingerprints[start + 5]:
			return _make_trigger(REASON_ALTERNATING_CALL_CYCLE, ALTERNATING_CYCLE_LENGTH)
	return {}


func _detect_round_loop() -> Dictionary:
	var round_count := _round_fingerprints.size()
	if round_count < IDENTICAL_ROUND_THRESHOLD:
		return {}
	var latest := _round_fingerprints[round_count - 1]
	for offset in range(2, IDENTICAL_ROUND_THRESHOLD + 1):
		if _round_fingerprints[round_count - offset] != latest:
			return {}
	return _make_trigger(REASON_IDENTICAL_ROUND, IDENTICAL_ROUND_THRESHOLD)


func _record_progress(progress_epoch: int) -> Dictionary:
	if not _has_progress_epoch:
		_has_progress_epoch = true
		_last_progress_epoch = progress_epoch
		_no_progress_rounds = 1
	elif progress_epoch != _last_progress_epoch:
		_last_progress_epoch = progress_epoch
		_no_progress_rounds = 0
	else:
		_no_progress_rounds += 1
	if _no_progress_rounds >= NO_PROGRESS_ROUND_THRESHOLD:
		return _make_trigger(REASON_NO_PROGRESS, NO_PROGRESS_ROUND_THRESHOLD)
	return {}


func _make_trigger(reason: String, threshold: int) -> Dictionary:
	return {
		"triggered": true,
		"reason": reason,
		"threshold": threshold,
	}


static func _canonicalize(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "bool:1" if value else "bool:0"
		TYPE_INT:
			return "int:" + str(value)
		TYPE_FLOAT:
			return "float:" + JSON.stringify(value)
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			return "string:" + JSON.stringify(str(value))
		TYPE_ARRAY:
			var items := PackedStringArray()
			for item in value:
				items.append(_canonicalize(item))
			return "array:[" + ",".join(items) + "]"
		TYPE_DICTIONARY:
			var entries := PackedStringArray()
			for key in value:
				entries.append(_canonicalize(key) + ":" + _canonicalize(value[key]))
			entries.sort()
			return "dictionary:{" + ",".join(entries) + "}"
		_:
			return "variant:" + type_string(typeof(value)) + ":" + JSON.stringify(var_to_str(value))
