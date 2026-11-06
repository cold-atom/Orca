@tool
extends RefCounted

## Local, editor-wide scheduling only. No account, project, conversation or
## rating data is collected; accepted turns count regardless of their outcome.
const Config = preload("res://addons/orca/scripts/config.gd")
const SETTING := "orca/community/support_reminder_v1"
const DAY_SECONDS := 86400
const FIRST_DELAY := 7 * DAY_SECONDS
const REMINDER_DELAY := 60 * DAY_SECONDS
const MIN_TURNS := 10
const MIN_ACTIVE_DAYS := 3
const MAX_SHOWS := 2
const MAX_TIMESTAMP := 4102444800 # 2100-01-01; reject unbounded/malformed preferences.


static func initial_state() -> Dictionary:
	return {"version": 1, "first_use": 0, "last_use": 0, "turns": 0, "active_days": 0, "shows": 0, "last_shown": 0, "stopped": false}


static func valid_state(value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY or value.size() != 8 or typeof(value.get("version")) != TYPE_INT or value["version"] != 1 or typeof(value.get("stopped")) != TYPE_BOOL:
		return false
	for key in ["first_use", "last_use", "last_shown", "turns", "active_days", "shows"]:
		if typeof(value.get(key)) != TYPE_INT or value[key] < 0 or value[key] > MAX_TIMESTAMP:
			return false
	if value["turns"] > MIN_TURNS or value["active_days"] > MIN_ACTIVE_DAYS or value["shows"] > MAX_SHOWS:
		return false
	if value["first_use"] > value["last_use"] or (value["first_use"] == 0) != (value["turns"] == 0) or (value["turns"] == 0) != (value["active_days"] == 0):
		return false
	return (value["shows"] == 0) == (value["last_shown"] == 0)


static func due(value: Dictionary, now: int) -> bool:
	if not valid_state(value) or now <= 0 or now > MAX_TIMESTAMP or value["stopped"] or value["shows"] >= MAX_SHOWS:
		return false
	if value["turns"] < MIN_TURNS or value["active_days"] < MIN_ACTIVE_DAYS or now < value["last_use"] or now - value["first_use"] < FIRST_DELAY:
		return false
	return value["shows"] == 0 or (now - value["last_shown"] >= REMINDER_DELAY and value["last_use"] > value["last_shown"])


func state() -> Dictionary:
	var settings := Config._get_editor_settings()
	if settings != null and not settings.has_setting(SETTING):
		return initial_state()
	var value = settings.get_setting(SETTING) if settings != null else null
	if valid_state(value):
		return value.duplicate(true)
	# A damaged/future preference must not erase a previous opt-out or nag again.
	return initial_state().merged({"stopped": true}, true)


func record_use(now: int) -> void:
	var value := state()
	if value["stopped"] or value["shows"] >= MAX_SHOWS or now <= 0 or now > MAX_TIMESTAMP or now < value["last_use"]:
		return
	if value["first_use"] == 0:
		value["first_use"] = now
	if value["last_use"] == 0 or int(value["last_use"] / float(DAY_SECONDS)) != int(now / float(DAY_SECONDS)):
		value["active_days"] = mini(MIN_ACTIVE_DAYS, value["active_days"] + 1)
	value["last_use"] = now
	value["turns"] = mini(MIN_TURNS, value["turns"] + 1)
	_save(value)


func mark_shown(now: int) -> bool:
	var value := state() # Fresh preference prevents another loaded dock repeating it.
	if not due(value, now):
		return false
	value["shows"] += 1
	value["last_shown"] = now
	return _save(value)


func stop() -> void:
	var value := state()
	value["stopped"] = true
	_save(value)


func _save(value: Dictionary) -> bool:
	var settings := Config._get_editor_settings()
	if settings == null or not valid_state(value):
		return false
	settings.set_setting(SETTING, value)
	return settings.get_setting(SETTING) == value
