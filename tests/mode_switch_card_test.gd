extends SceneTree

const ModeSwitchCard = preload("res://addons/orca/scripts/mode_switch_card.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	get_root().size = Vector2i(300, 600)
	var card := ModeSwitchCard.new()
	get_root().add_child(card)
	await process_frame
	card.configure({"call_id": "mode_card", "reason": "Implementing this request requires reviewed project changes."}, 17)
	var decisions: Array[Dictionary] = []
	card.decision_requested.connect(func(call_id: String, turn_id: int, approved: bool): decisions.append({"call_id": call_id, "turn_id": turn_id, "approved": approved}))
	var switch_button := _button_named(card, "Switch to Work")
	var stay_button := _button_named(card, "Stay in Plan")
	_expect(switch_button != null and stay_button != null, "the card should use explicit Work and Plan actions")
	_expect(card.get_combined_minimum_size().x <= 300.0, "the card should fit the minimum dock width")
	if switch_button != null:
		switch_button.pressed.emit()
		switch_button.pressed.emit()
	_expect(decisions == [{"call_id": "mode_card", "turn_id": 17, "approved": true}], "a decision should emit once with exact call and turn ownership")
	card.complete({"success": true, "outcome": "completed", "content": "The user approved Work mode."}, 4)
	_expect(not switch_button.visible and not stay_button.visible, "a resolved card should remove actionable controls")
	card.queue_free()
	await process_frame
	_finish()


func _button_named(root: Node, text: String) -> Button:
	for child in _collect_buttons(root):
		if child.text == text:
			return child
	return null


func _collect_buttons(root: Node) -> Array[Button]:
	var result: Array[Button] = []
	for child in root.get_children():
		if child is Button:
			result.append(child)
		result.append_array(_collect_buttons(child))
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("mode_switch_card_test: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("mode_switch_card_test: " + failure)
	quit(1)
