extends SceneTree

const ChatWindow = preload("res://addons/orca/scripts/chat_window.gd")
const AgentController = preload("res://addons/orca/scripts/agent_controller.gd")
const ChatWindowScene = preload("res://addons/orca/scenes/chat_window.tscn")
const TaskListPanel = preload("res://addons/orca/scripts/task_list_panel.gd")
const ChangeCard = preload("res://addons/orca/scripts/change_card.gd")
const InputMapChangeCard = preload("res://addons/orca/scripts/input_map_change_card.gd")
const MainSceneChangeCard = preload("res://addons/orca/scripts/main_scene_change_card.gd")
const ProjectSettingsChangeCard = preload("res://addons/orca/scripts/project_settings_change_card.gd")
const SceneChangeCard = preload("res://addons/orca/scripts/scene_change_card.gd")
const ModeSwitchCard = preload("res://addons/orca/scripts/mode_switch_card.gd")
const DiffUtils = preload("res://addons/orca/scripts/diff_utils.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

class FakeAgent:
	extends RefCounted
	var busy := true
	var cancellations := 0
	var mode_decisions: Array[Dictionary] = []
	var checkpointed := true

	func get_mode() -> int:
		return 1

	func is_busy() -> bool:
		return busy

	func queue_editor_scene_refresh() -> void:
		pass

	func cancel_current_request() -> void:
		cancellations += 1

	func resolve_work_mode_request(call_id: String, origin_turn_id: int, approved: bool) -> void:
		mode_decisions.append({"call_id": call_id, "turn_id": origin_turn_id, "approved": approved})

	func snapshot_session_state() -> Dictionary:
		return {"mode": get_mode(), "continuation": [], "usage": {}, "tasks": []}

	func last_failure_was_checkpointed() -> bool:
		return checkpointed


var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_block_parser()
	get_root().size = Vector2i(300, 900)
	var view = ChatWindowScene.instantiate()
	get_root().add_child(view)
	await process_frame
	await process_frame
	_test_animated_empty_logo(view)
	if view.agent_controller == null:
		view.agent_controller = FakeAgent.new()
	if view.task_list_panel == null:
		view.task_list_panel = TaskListPanel.new()
		get_root().add_child(view.task_list_panel)
	view._session = {}
	view._has_session_content = false
	view._clear_chat_feed()
	await process_frame
	_test_ui_scale_math()
	await _test_compact_composer(view)
	_test_active_composer_lifecycle(view)
	await _test_final_rendering(view)
	await _test_response_footer(view)
	await process_frame
	await process_frame
	_test_working_indicator(view)
	_test_turn_event_ownership(view)
	_test_request_budget_feedback(view)
	_test_work_mode_request_ui(view)
	await process_frame
	await _test_active_feed_follow(view)
	await process_frame
	_test_stream_finalization(view)
	await process_frame
	await process_frame
	_test_restoration_completion_rules(view)
	_test_interrupted_turn_resumability(view)
	await process_frame
	_test_live_tool_grouping(view)
	await process_frame
	await process_frame
	await _test_intelligence_tool_activity(view)
	await process_frame
	await _test_restored_tool_grouping(view)
	await process_frame
	_test_task_panel_integration(view)
	await process_frame
	await _test_game_operation_cards(view)
	await process_frame
	await _test_input_map_change_card(view)
	await process_frame
	await _test_main_scene_change_card(view)
	await process_frame
	await _test_project_settings_change_card(view)
	await process_frame
	await _test_scene_change_card(view)
	await process_frame
	await _test_add_node_change_card(view)
	await process_frame
	await _test_scene_operation_summaries(view)
	await process_frame
	await _test_script_trust_change_card(view)
	await process_frame
	await _test_expanded_diff_content()
	await process_frame
	_test_recovery_event_persistence(view)
	await process_frame
	view._session = {}
	view._has_session_content = false
	if view.task_list_panel != null and view.task_list_panel.get_parent() == get_root():
		view.task_list_panel.queue_free()
	view.queue_free()
	await process_frame
	_finish()


func _test_animated_empty_logo(view) -> void:
	var logo := view.get_node("MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState/Content/Logo") as TextureRect
	_expect(logo.texture is AtlasTexture, "the empty state should use the animated Orca sprite sheet")
	if logo.texture is AtlasTexture:
		_expect(logo.texture.region.size == Vector2(194, 144), "animated Orca frames should preserve the SVG aspect ratio")


func _test_block_parser() -> void:
	var prose := ChatWindow._split_final_message_blocks("Only **prose**")
	_expect(prose.size() == 1 and prose[0].get("type") == "text", "prose-only messages should remain one text block")
	var mixed := ChatWindow._split_final_message_blocks("Before\n```gdscript\nprint(\"[b] **literal** ✓\")\n```\nAfter")
	_expect(mixed.size() == 3, "prose and fenced code should retain source order")
	if mixed.size() == 3:
		_expect(mixed[0].get("text") == "Before", "text before code should be preserved")
		_expect(mixed[1].get("type") == "code", "fenced content should become a code block")
		_expect(mixed[1].get("language") == "gdscript", "fence language should be retained")
		_expect(mixed[1].get("text") == "print(\"[b] **literal** ✓\")", "code must not receive Markdown or BBCode conversion")
		_expect(mixed[2].get("text") == "After", "text after code should be preserved")
	var multiple := ChatWindow._split_final_message_blocks("```\none\n```\nmiddle\n```text\ntwo\n```")
	_expect(_count_blocks(multiple, "code") == 2, "multiple fenced blocks should be parsed independently")
	var crlf := ChatWindow._split_final_message_blocks("Before\r\n``` gd \r\npass\r\n```\r\nAfter")
	_expect(crlf.size() == 3 and crlf[1].get("language") == "gd", "CRLF fences and padded languages should normalize")
	var unmatched := ChatWindow._split_final_message_blocks("Before\n```gdscript\nprint(1)")
	_expect(unmatched.size() == 1 and unmatched[0].get("type") == "text", "unmatched fences should remain literal prose")
	_expect(unmatched[0].get("text") == "Before\n```gdscript\nprint(1)", "unmatched fence text should not be lost")


func _test_ui_scale_math() -> void:
	_expect(UiMetrics.scaled(10, 1.0) == 10.0, "100% UI metrics should preserve authored dimensions")
	_expect(UiMetrics.scaled(10, 1.25) == 13.0, "fractional editor scaling should round authored dimensions")
	_expect(UiMetrics.scaled_vector(Vector2(24, 28), 2.0) == Vector2(48, 56), "200% UI metrics should scale both dimensions once")


func _test_request_budget_feedback(view) -> void:
	var summary := {"context_tokens": 4088, "context_limit": 32768, "completed_requests": 5, "usage_complete": true, "request_budget": {"estimated_tokens": 38000, "context_limit": 32768, "input_budget": 24576, "output_reserve": 8192, "tool_reserve": 0, "status": "blocked", "active": false}}
	view._sync_session_usage(summary)
	_expect(view.context_label.text == "Request ~38.0k / 32.8k", "a blocked continuation must show its local estimate instead of the last completed 4.1k request")
	_expect(view.context_label.tooltip_text.contains("4088") or view.context_label.tooltip_text.contains("4.1k"), "last provider usage must remain separately labeled")
	_expect(view.context_label.tooltip_text.contains("24576") and view.context_label.tooltip_text.contains("8192"), "blocked feedback must explain input and response reserves")
	summary["request_budget"]["status"] = "prepared"
	summary["request_budget"]["active"] = true
	view._sync_session_usage(summary)
	_expect(view.context_label.text.begins_with("Request ~"), "active requests must use a clearly estimated metric")
	summary["request_budget"]["active"] = false
	view._sync_session_usage(summary)
	_expect(view.context_label.text == "Context 4.1k / 32.8k", "completed requests must retain provider-reported context without replacing billing usage")


func _test_compact_composer(view) -> void:
	view.prompt_input.text = ""
	view._sync_prompt_height()
	await process_frame
	var line_height: float = view.prompt_input.get_line_height()
	var style_height: float = view.prompt_input.get_theme_stylebox("normal").get_minimum_size().y
	var expected_minimum: float = ChatWindow.PROMPT_MIN_LINES * line_height + style_height
	_expect(is_equal_approx(view.prompt_input.custom_minimum_size.y, ceilf(expected_minimum)), "an empty composer should use the configured compact line count")
	_expect(view.prompt_input.custom_minimum_size.y < 110.0, "an empty composer must not retain the old fixed 110 px floor at 100% scale")
	var image_button := view.get_node("MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ImageButton") as BaseButton
	_expect(image_button.visible, "image attachment action should be discoverable in the composer")
	var actions := view.get_node("MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions") as HBoxContainer
	var actions_rect := actions.get_global_rect()
	for child in actions.get_children():
		if child is Control and child.visible:
			_expect(actions_rect.encloses(child.get_global_rect()), "visible composer actions should remain inside the narrow action row")
	view.prompt_input.text = "line\n".repeat(20)
	view._sync_prompt_height()
	var expected_maximum: float = minf(
		ChatWindow.PROMPT_MAX_LINES * line_height + style_height,
		maxf(expected_minimum, view.size.y * ChatWindow.PROMPT_MAX_DOCK_RATIO)
	)
	_expect(view.prompt_input.custom_minimum_size.y <= ceilf(expected_maximum), "a long prompt should remain bounded by line count and dock height")
	var expanded_height: float = view.prompt_input.custom_minimum_size.y
	view._clear_prompt_input()
	await process_frame
	_expect(view.prompt_input.text.is_empty(), "programmatic prompt clearing should remove submitted text")
	_expect(view.prompt_input.custom_minimum_size.y < expanded_height, "programmatic prompt clearing should shrink an expanded composer without another keystroke")
	_expect(is_equal_approx(view.prompt_input.custom_minimum_size.y, ceilf(expected_minimum)), "programmatic prompt clearing should restore the compact composer height")


func _test_final_rendering(view) -> void:
	view._clear_chat_feed()
	var source := "Before [color=red]literal[/color]\n```gdscript\nprint(\"**literal** [b] ✓\")\n```\nAfter"
	view._add_final_assistant_message("Orca[color=red]", source, Color.LIGHT_GREEN)
	var panel: Node = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	var editors := _collect_nodes(panel, "orca_code_editor")
	var copy_buttons := _collect_nodes(panel, "orca_copy_button")
	var language_labels := _collect_nodes(panel, "orca_code_language", Label)
	_expect(editors.size() == 1, "a finalized fence should create one CodeEdit")
	_expect(copy_buttons.size() == 1, "each code block should have one Copy action")
	_expect(language_labels.size() == 1 and language_labels[0].text == "GDScript", "GDScript fences should have a normalized language label")
	if editors.size() == 1:
		var editor: CodeEdit = editors[0]
		_expect(editor.text == "print(\"**literal** [b] ✓\")", "rendered code should exactly match parsed plain text")
		if Engine.is_editor_hint():
			_expect(editor.syntax_highlighter is GDScriptSyntaxHighlighter, "GDScript code should use the public syntax highlighter")
	var rich_labels := _collect_type(panel, RichTextLabel)
	var combined_bbcode := ""
	for label in rich_labels:
		combined_bbcode += label.text
	_expect(combined_bbcode.contains("[lb]color=red[rb]"), "model and sender BBCode should be escaped")

	var long_code := PackedStringArray()
	for index in range(40):
		long_code.append("var line_%d = \"%s\"" % [index, "x".repeat(400)])
	view._add_final_assistant_message("Orca", "```gdscript\n%s\n```" % "\n".join(long_code), Color.LIGHT_GREEN)
	await process_frame
	await process_frame
	var long_panel: Node = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	var long_editors := _collect_nodes(long_panel, "orca_code_editor")
	if long_editors.size() == 1:
		var editor: CodeEdit = long_editors[0]
		var style := editor.get_theme_stylebox("normal")
		var maximum_height := ChatWindow.CODE_MAX_VISIBLE_LINES * editor.get_line_height() + style.get_minimum_size().y + 1.0
		_expect(editor.custom_minimum_size.y <= maximum_height, "large code blocks should have bounded height")
	_expect(view.get_combined_minimum_size().x <= 300.0, "long code lines must not widen the minimum dock beyond 300 px")


func _test_stream_finalization(view) -> void:
	view._clear_chat_feed()
	view._session = {"events": []}
	view._on_message_stream_started()
	_expect(view._stream_label == null, "stream headers alone should not create an assistant card")
	view._on_message_stream_delta("Before\n``")
	var stream_label = view._stream_label
	var panel: Node = stream_label.get_parent()
	view._on_message_stream_delta("`gdscript\npri")
	view._on_message_stream_delta("nt(\"✓\")\n```")
	_expect(view._stream_label == stream_label, "streaming should keep one label instance")
	_expect(_collect_nodes(panel, "orca_code_editor").is_empty(), "partial streaming should not create code controls")
	view._finish_stream_before_activity()
	_expect(panel.get_parent() == view.chat_feed, "finalization should preserve the outer message card")
	var editors := _collect_nodes(panel, "orca_code_editor")
	_expect(editors.size() == 1 and editors[0].text == "print(\"✓\")", "tool-preface finalization should materialize completed code")
	var events: Array = view._session.get("events", [])
	_expect(not events.is_empty() and events[-1].get("completion") == "tool_preface", "tool-preface text should retain its completion marker")


func _test_response_footer(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	await process_frame
	var attribution := {"model": "deepseek-v4-pro", "mode": 0, "provider": "hidden", "reasoning": "hidden"}
	for source in ["Plain answer", "```gdscript\nprint(1)\n```"]:
		view._add_final_assistant_message("Orca", source, Color.LIGHT_GREEN, attribution)
		var panel: Control = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
		var footers := _collect_nodes(panel, "orca_response_footer")
		var models := _collect_nodes(panel, "orca_response_model", Label)
		var modes := _collect_nodes(panel, "orca_response_mode", Label)
		_expect(footers.size() == 1 and models.size() == 1 and modes.size() == 1, "plain and fenced-code answers must share one model/mode footer")
		_expect(models[0].text == "deepseek-v4-pro" and models[0].tooltip_text == models[0].text and modes[0].text == "Plan", "footers must show the full configured model and response mode only")
		_expect(modes[0].get_theme_color("font_color") == view._assistant_color_for_mode(0), "footer mode must use Orca's response-bound Plan accent")
		view._set_response_footer(panel, attribution)
		_expect(_collect_nodes(panel, "orca_response_footer").size() == 1, "reapplying attribution must replace rather than duplicate a footer")
		await process_frame
		await process_frame
		_expect(panel.get_combined_minimum_size().x <= 300.0, "model/mode attribution must not widen a narrow dock")
		_expect(not is_instance_valid(models[0]) or models[0].is_queued_for_deletion(), "replaced metadata controls should be released")
	view._add_final_assistant_message("Orca", "Legacy answer", Color.LIGHT_GREEN)
	var legacy: Node = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	_expect(_collect_nodes(legacy, "orca_response_footer").is_empty(), "missing historical attribution must not be guessed from current settings")
	view._add_final_assistant_message("Orca", "Long model", Color.LIGHT_GREEN, {"model": "namespace/" + "long-model-name-".repeat(30), "mode": 1})
	await process_frame
	await process_frame
	var long_panel: Control = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	var long_model: Label = _collect_nodes(long_panel, "orca_response_model", Label)[0]
	var long_mode: Label = _collect_nodes(long_panel, "orca_response_mode", Label)[0]
	_expect(long_panel.get_combined_minimum_size().x <= 300.0 and long_model.max_lines_visible == 2 and long_model.tooltip_text.length() > 400, "long full identifiers must remain bounded with complete hover text")
	_expect(long_mode.get_global_rect().end.x <= long_panel.get_global_rect().end.x, "the response mode must remain inside the card's right edge")

	view._clear_chat_feed()
	view._session = {"events": []}
	await process_frame
	view._on_turn_request_state_changed(91, true)
	view._on_turn_workflow_state_changed(91, "thinking", {"attribution": {"model": "model-A", "mode": 0}})
	view._on_turn_message_stream_started(91)
	view._on_turn_message_stream_delta(91, "Planning preface")
	view._finish_stream_before_activity()
	view._on_turn_workflow_state_changed(91, "thinking", {"follow_up": true, "attribution": {"model": "model-A", "mode": 1}})
	view._on_turn_message_received(91, "assistant", "Work answer", {"model": "model-A", "mode": 1})
	var events: Array = view._session["events"]
	_expect(events[0]["attribution"] == {"model": "model-A", "mode": 0} and events[0]["mode"] == 0 and events[1]["attribution"] == {"model": "model-A", "mode": 1}, "tool prefaces and final answers must preserve their generating request's mode")
	view._on_turn_request_state_changed(92, true)
	view._on_turn_workflow_state_changed(92, "thinking", {"attribution": {"model": "model-B", "mode": 0}})
	view._on_turn_message_stream_started(92)
	view._on_turn_message_stream_delta(92, "Partial answer")
	view._on_turn_error_occurred(92, "Synthetic footer failure")
	_expect(view._session["events"][-2].get("completion") == "incomplete" and view._session["events"][-2].get("attribution") == {"model": "model-B", "mode": 0}, "failed partial responses must retain attribution without being promoted to complete")
	view._on_turn_request_state_changed(93, true)
	view._on_turn_workflow_state_changed(93, "thinking", {"attribution": {"model": "model-C", "mode": 1}})
	view._on_turn_message_stream_started(93)
	view._on_turn_message_stream_delta(93, "Stopped portion")
	view._on_turn_request_cancelled(93)
	_expect(view._session["events"][-2].get("completion") == "cancelled" and view._session["events"][-2].get("attribution") == {"model": "model-C", "mode": 1}, "Stop must preserve attribution on visible partial text only")
	view._on_turn_request_state_changed(94, true)
	view._on_turn_workflow_state_changed(94, "thinking", {"attribution": {"model": "model-D", "mode": 0}})
	view._on_turn_message_received(93, "assistant", "Stale", {"model": "wrong-model", "mode": 1})
	_expect(view._response_attribution == {"model": "model-D", "mode": 0}, "stale terminal metadata must not overwrite a newer turn")
	view._on_turn_message_stream_started(94)
	view._on_turn_request_cancelled(94)
	view._clear_chat_feed()
	await process_frame
	for event in events.slice(0, 2):
		view._render_session_event(event)
	var restored_models := _collect_nodes(view.chat_feed, "orca_response_model", Label)
	var restored_modes := _collect_nodes(view.chat_feed, "orca_response_mode", Label)
	_expect(restored_models.size() == 2 and restored_models[0].text == "model-A" and restored_modes[0].text == "Plan" and restored_modes[1].text == "Work", "History restoration must render per-answer model/mode instead of current selection")
	view._clear_chat_feed()
	await process_frame


func _test_working_indicator(view) -> void:
	view._clear_chat_feed()
	view._session = {"events": []}
	view._show_working_indicator("Thinking")
	var indicators := _collect_nodes(view.chat_feed, "orca_working_indicator")
	var squares := _collect_nodes(view.chat_feed, "orca_working_square", Panel)
	var statuses := _collect_nodes(view.chat_feed, "orca_working_status", Label)
	_expect(indicators.size() == 1, "an active request should show one transient working indicator")
	_expect(squares.size() == ChatWindow.WORKING_SQUARE_COUNT, "the working indicator should contain five square cells")
	_expect(statuses.size() == 1 and statuses[0].text == "Thinking", "the working indicator should describe the current phase")
	var first_scale: Vector2 = squares[0].scale if not squares.is_empty() else Vector2.ZERO
	view._advance_working_animation()
	_expect(not squares.is_empty() and squares[0].scale != first_scale, "the square tide should advance through visibly distinct frames")
	view._on_message_stream_started()
	_expect(view._stream_label == null, "SSE headers must not create an empty Orca response card")
	_expect(view._transient_card != null and is_instance_valid(view._transient_card), "the working indicator should remain until actual response content arrives")
	view._on_message_stream_delta("First token")
	_expect(view._transient_card == null, "the first non-empty response token should remove the working indicator")
	_expect(view._stream_label != null and view._stream_content == "First token", "the first response token should begin one streaming assistant card")
	view._finish_stream_before_activity()
	view._on_workflow_state_changed("thinking", {"follow_up": true})
	_expect(view._working_status_label != null and view._working_status_label.text == "Preparing response", "tool follow-ups should return to an explicit preparing state")
	view._on_workflow_state_changed("finalizing", {"trigger_reason": "no_progress"})
	_expect(view._working_status_label != null and view._working_status_label.text == "Finalizing safely", "safe no-tools finalization should have a distinct working state")
	view.prompt_input.text = "Retained follow-up draft"
	view._set_request_active(true)
	_expect(view.prompt_input.text == "Retained follow-up draft" and view.send_button.tooltip_text.contains("draft text is kept"), "active Stop behavior should explicitly retain a typed draft")
	view._on_workflow_state_changed("idle", {})
	_expect(view._transient_card == null and view._working_timer == null, "idle transitions should stop and release the working animation")
	view._show_working_indicator("Finalizing safely")
	view._on_message_stream_started()
	view._on_agent_message_received("assistant", "")
	_expect(view._transient_card == null and view._stream_label == null, "an empty terminal response should always remove the working indicator and empty stream state")
	view.prompt_input.text = ""
	view._set_request_active(false)
	_expect(view.get_combined_minimum_size().x <= 300.0, "the working indicator must not widen the minimum dock beyond 300 px")


func _test_active_composer_lifecycle(view) -> void:
	var real_agent = view.agent_controller
	var fake_agent := FakeAgent.new()
	view.agent_controller = fake_agent
	view._session = {"events": [], "clean": false, "resumable": true}
	view._session_resumable = true
	view._turn_had_tools = false
	view.prompt_input.editable = true
	view.prompt_input.text = "Draft while Orca works"
	view._set_request_active(true)
	var enter := InputEventKey.new()
	enter.pressed = true
	enter.keycode = KEY_ENTER
	view._on_prompt_gui_input(enter)
	_expect(fake_agent.cancellations == 0 and view.prompt_input.text == "Draft while Orca works" and not view.get_viewport().is_input_handled(), "plain Enter during an active request must remain unhandled composer input rather than being swallowed, submitted, or stopped")
	var stop_handler := Callable(view, "_on_send_button_pressed")
	if not view.send_button.pressed.is_connected(stop_handler):
		view.send_button.pressed.connect(stop_handler)
	view.send_button.emit_signal("pressed")
	_expect(fake_agent.cancellations == 1 and view.prompt_input.text == "Draft while Orca works", "the actual Stop button path should cancel once without clearing the draft (cancellations: %d)" % fake_agent.cancellations)

	view._active_turn_id = 31
	view._on_turn_message_received(31, "assistant", "Completed")
	_expect(view.prompt_input.text == "Draft while Orca works" and not view._request_active and not view.send_button.disabled, "matching completion should preserve the active-turn draft and restore Send")
	view._session = {"events": [], "clean": false, "resumable": true}
	view._active_turn_id = 32
	view._set_request_active(true)
	view._on_turn_error_occurred(32, "Synthetic failure")
	_expect(view.prompt_input.text == "Draft while Orca works" and not view._request_active and not view.send_button.disabled, "matching failure should preserve the active-turn draft and restore Send")
	view._session = {"events": [], "clean": false, "resumable": true}
	view._active_turn_id = 33
	view._set_request_active(true)
	view._on_turn_request_cancelled(33)
	_expect(view.prompt_input.text == "Draft while Orca works" and not view._request_active and not view.send_button.disabled, "matching cancellation should preserve the active-turn draft and restore Send")
	view.agent_controller = real_agent


func _test_turn_event_ownership(view) -> void:
	view._clear_chat_feed()
	view._session = {"events": [], "clean": false}
	view._active_turn_id = 22
	view.prompt_input.text = "Newer turn draft"
	view._set_request_active(true)
	view._show_working_indicator("Thinking")
	var child_count: int = view.chat_feed.get_child_count()
	var stop_texture: Texture2D = view.send_icon_view.texture
	var stop_tooltip: String = view.send_button.tooltip_text
	view._on_turn_message_stream_started(21)
	view._on_turn_message_stream_delta(21, "stale")
	view._on_turn_workflow_state_changed(21, "idle", {})
	view._on_turn_tool_execution_started(21, "stale_call", "read_file", {})
	view._on_turn_edit_proposed(21, _scroll_test_proposal("stale_change", "res://stale.gd"))
	view._on_turn_request_state_changed(21, false)
	view._on_turn_message_received(21, "assistant", "stale completion")
	view._on_turn_error_occurred(21, "stale error")
	view._on_turn_request_cancelled(21)
	_expect(view._active_turn_id == 22 and view._request_active, "stale terminal and state events must not release the active newer turn")
	_expect(view._stream_content.is_empty() and view.chat_feed.get_child_count() == child_count, "stale stream, tool, edit, and terminal events must not mutate cards")
	_expect(view._session.get("events", []).is_empty() and not view._session.get("clean", false), "stale events must not mutate persisted session state")
	_expect(view.prompt_input.text == "Newer turn draft" and view.prompt_input.editable, "stale events must not alter the newer turn draft or composer editability")
	_expect(not view.send_button.disabled and view.send_icon_view.texture == stop_texture and view.send_button.tooltip_text == stop_tooltip, "stale events must not alter the newer turn Stop state")
	view._on_turn_request_state_changed(22, false)
	view._on_turn_request_state_changed(23, true)
	view._on_turn_message_received(22, "assistant", "old terminal after reentry")
	view._on_turn_request_cancelled(22)
	_expect(view._active_turn_id == 23 and view._request_active, "old terminal UI events must not clear reentrant new-turn ownership")
	view._on_turn_request_cancelled(23)
	_expect(view._active_turn_id == 0 and not view._request_active, "the matching cancellation should release the active UI turn")


func _test_work_mode_request_ui(view) -> void:
	var real_agent = view.agent_controller
	var fake_agent := FakeAgent.new()
	view.agent_controller = fake_agent
	view._clear_chat_feed()
	view._session = {"events": [], "clean": false, "resumable": true}
	view._active_turn_id = 44
	view._set_request_active(true)
	view._on_turn_work_mode_requested(43, {"call_id": "stale_mode", "reason": "stale"})
	_expect(_collect_type(view.chat_feed, ModeSwitchCard).is_empty(), "stale mode requests must not create decision UI")
	view._on_tool_execution_started("mode_ui", AgentController.WORK_MODE_REQUEST_TOOL, {"reason": "private reason"})
	view._on_turn_work_mode_requested(44, {"call_id": "mode_ui", "reason": "Implementing the requested change requires reviewed project edits."})
	var cards := _collect_type(view.chat_feed, ModeSwitchCard)
	_expect(cards.size() == 1 and view._session.get("events", []).is_empty(), "a matching mode request should show one memory-only decision card")
	if cards.size() == 1:
		var switch_buttons := _collect_type(cards[0], Button).filter(func(button): return button.text == "Switch to Work")
		_expect(switch_buttons.size() == 1 and cards[0].get_combined_minimum_size().x <= 300.0, "the explicit Work action should fit the narrow dock")
		if switch_buttons.size() == 1:
			switch_buttons[0].pressed.emit()
	_expect(fake_agent.mode_decisions == [{"call_id": "mode_ui", "turn_id": 44, "approved": true}], "the card should send one exact turn-bound approval")
	view._on_turn_tool_execution_completed(44, "mode_ui", AgentController.WORK_MODE_REQUEST_TOOL, {"success": true, "content": "The user approved Work mode.", "outcome": "completed", "data": {}}, 5)
	var persisted := JSON.stringify(view._session.get("events", []))
	_expect(view._session.get("events", []).size() == 1 and persisted.contains("Switched to Work mode") and not persisted.contains("reviewed project edits"), "resolved mode activity should persist without the model-supplied reason")
	view._session = {"events": [], "clean": false, "resumable": true}
	view._session_resumable = true
	view.prompt_input.editable = true
	view._active_turn_id = 45
	view._set_request_active(true)
	view._on_tool_execution_started("mode_cancel_ui", AgentController.WORK_MODE_REQUEST_TOOL, {"reason": "private"})
	view._on_turn_work_mode_requested(45, {"call_id": "mode_cancel_ui", "reason": "Work is needed."})
	view._on_turn_tool_execution_completed(45, "mode_cancel_ui", AgentController.WORK_MODE_REQUEST_TOOL, {"success": false, "content": "The Work mode request was cancelled.", "outcome": "cancelled", "data": {}}, 3)
	view._on_turn_request_cancelled(45)
	_expect(view._session_resumable and view.prompt_input.editable, "stopping a side-effect-free mode decision should leave the Plan conversation usable")
	view._active_turn_id = 0
	view._set_request_active(false)
	view._turn_had_tools = false
	view._turn_had_mode_request = false
	view.agent_controller = real_agent


func _test_active_feed_follow(view) -> void:
	view._clear_chat_feed()
	view._session = {"events": []}
	view._change_cards.clear()
	for index in range(14):
		view._add_message("Orca", "Earlier message %d\n%s" % [index, "content ".repeat(10)], Color.LIGHT_GREEN, "assistant")
	await _wait_frames(6)

	var late_card := PanelContainer.new()
	late_card.custom_minimum_size = Vector2(0, 60)
	view.chat_feed.add_child(late_card)
	view._request_active = true
	view._scroll_to_bottom()
	await process_frame
	late_card.custom_minimum_size.y = 420
	await _wait_frames(6)
	_expect(_scroll_is_at_bottom(view.chat_scroll), "active turns should remain at the latest card after delayed layout growth")

	view._request_active = false
	view._on_edit_proposed(_scroll_test_proposal("scroll_change_1", "res://first.gd"))
	await _wait_frames(6)
	_expect(_scroll_is_at_bottom(view.chat_scroll), "a pending review should be brought into view after its final layout")
	view._on_edit_resolved("scroll_change_1", "applied", "Applied first change")
	view._request_active = true
	view._on_edit_proposed(_scroll_test_proposal("scroll_change_2", "res://second.gd"))
	await _wait_frames(6)
	_expect(_scroll_is_at_bottom(view.chat_scroll), "the next sequential review should automatically replace the previous review as the visible latest activity")
	view._request_active = false


func _scroll_test_proposal(change_id: String, filepath: String) -> Dictionary:
	return {
		"id": change_id,
		"kind": "file_patch",
		"filepath": filepath,
		"status": "pending",
		"existed": true,
		"old_content": "old\n",
		"new_content": "new\n",
		"diff": {
			"additions": 1,
			"deletions": 1,
			"display_operations": [
				{"type": "remove", "old_line": 1, "new_line": 0, "text": "old"},
				{"type": "add", "old_line": 0, "new_line": 1, "text": "new"}
			]
		},
		"validation": {"valid": true, "message": "Passed"}
	}


func _scroll_is_at_bottom(scroll: ScrollContainer) -> bool:
	var bar := scroll.get_v_scroll_bar()
	return bar.value >= bar.max_value - bar.page - 1.0


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame


func _test_restoration_completion_rules(view) -> void:
	view._clear_chat_feed()
	var text := "Before\n```gdscript\npass\n```"
	view._render_session_event({"type": "message", "sender": "Orca", "text": text, "kind": "assistant", "mode": 1, "completion": "complete"})
	var complete_panel: Node = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	_expect(_collect_nodes(complete_panel, "orca_code_editor").size() == 1, "completed restored messages should render code blocks")
	view._render_session_event({"type": "message", "sender": "Orca (incomplete)", "text": text, "kind": "assistant", "mode": 1, "completion": "incomplete"})
	var incomplete_panel: Node = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	_expect(_collect_nodes(incomplete_panel, "orca_code_editor").is_empty(), "incomplete restored messages should remain literal text")


func _test_interrupted_turn_resumability(view) -> void:
	view._session = {"resumable": false}
	view._set_interrupted_turn_resumability(true)
	_expect(view._session_resumable and not view._session_resume_tainted, "a validated recovery checkpoint should keep the conversation resumable")
	_expect(view.prompt_input.editable and view.prompt_input.placeholder_text.contains("recovery checkpoint"), "recoverable interruption should keep the composer available with recovery guidance")
	view._set_interrupted_turn_resumability(false)
	_expect(not view._session_resumable and view._session_resume_tainted, "an unsafe interrupted tool turn should remain tainted")
	_expect(not view.prompt_input.editable and view.prompt_input.placeholder_text.contains("Start a new chat"), "unsafe interruption should keep the composer locked")


func _test_live_tool_grouping(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	view._on_tool_execution_started("read_1", "read_file", {"filepath": "res://player.gd", "start_line": 4})
	view._on_tool_execution_completed("read_1", "read_file", {"content": "read", "outcome": "completed", "data": {"open_path": "res://player.gd", "open_line": 4}}, 100)
	view._on_tool_execution_started("search_1", "search_files", {"query": "Player", "path": "res://"})
	view._on_tool_execution_completed("search_1", "search_files", {"content": "found", "outcome": "completed", "data": {"open_path": "res://player.gd", "open_line": 8, "open_column": 2}}, 200)
	view._on_tool_execution_started("settings_1", "inspect_project_settings", {"setting_path": "application/run/main_scene"})
	view._on_tool_execution_completed("settings_1", "inspect_project_settings", {"content": "sensitive raw setting output", "outcome": "completed", "data": {"open_path": "res://project.godot", "open_line": 1}}, 30)
	var groups := _collect_nodes(view.chat_feed, "orca_tool_group")
	_expect(groups.size() == 1 and groups[0].call_count() == 3, "consecutive read-only calls should share one live group")
	view._add_message("Orca", "Visible boundary", Color.LIGHT_GREEN, "assistant")
	view._on_tool_execution_started("diagnostics_1", "get_diagnostics", {})
	view._on_tool_execution_completed("diagnostics_1", "get_diagnostics", {"content": "none", "outcome": "completed", "data": {}}, 50)
	groups = _collect_nodes(view.chat_feed, "orca_tool_group")
	_expect(groups.size() == 2 and groups[1].call_count() == 1, "a visible message should close the previous group")
	view._on_tool_execution_started("patch_1", "apply_patch", {"filepath": "res://player.gd"})
	var latest: Node = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	_expect(not latest.has_meta("orca_tool_group"), "apply_patch activity must remain standalone")
	view._on_tool_execution_completed("patch_1", "apply_patch", {"content": "no change", "outcome": "completed", "data": {}}, 25)
	var events: Array = view._session.get("events", [])
	_expect(events.size() == 5, "grouping must keep persisted tool events flat and independent")
	_expect(events[1].get("arguments", {}).get("query") == "Player", "safe search targets should persist for restoration")
	_expect(events[1].get("open_path") == "res://player.gd", "safe navigation metadata should persist without raw output")
	_expect(events[2].get("arguments", {}).get("setting_path") == "application/run/main_scene", "safe explicit setting paths should persist for restoration")
	_expect(not JSON.stringify(events[2]).contains("sensitive raw setting output"), "raw project settings output must not persist")


func _test_restored_tool_grouping(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	await process_frame
	view._render_session_event({"type": "tool", "id": "r1", "name": "read_file", "arguments": {"filepath": "res://one.gd"}, "outcome": "completed", "summary": "Completed successfully.", "duration_ms": 10})
	view._render_session_event({"type": "tool", "id": "s1", "name": "search_files", "arguments": {"query": "Node"}, "outcome": "completed", "summary": "Completed successfully.", "duration_ms": 20})
	view._render_session_event({"type": "tool", "id": "ps1", "name": "inspect_project_settings", "arguments": {"setting_path": "application/run/main_scene"}, "outcome": "completed", "summary": "Completed successfully.", "duration_ms": 15, "open_path": "res://project.godot"})
	view._render_session_event({"type": "message", "sender": "Orca", "text": "Boundary", "kind": "assistant", "mode": 1, "completion": "complete"})
	view._render_session_event({"type": "tool", "id": "d1", "name": "get_diagnostics", "arguments": {}, "outcome": "running", "summary": "Running", "duration_ms": 0})
	view._render_session_event({"type": "tool", "id": "p1", "name": "apply_patch", "arguments": {"filepath": "res://one.gd"}, "outcome": "completed", "summary": "Completed successfully.", "duration_ms": 5})
	view._close_active_tool_group()
	var groups := _collect_nodes(view.chat_feed, "orca_tool_group")
	_expect(groups.size() == 2, "restoration should derive groups from flat consecutive events")
	if groups.size() == 2:
		_expect(groups[0].call_count() == 3, "the first restored group should contain all consecutive reads")
		_expect(groups[1].call_count() == 1 and groups[1].aggregate_outcome() == "interrupted", "restored running activity should become interrupted")
	var last: Node = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	_expect(not last.has_meta("orca_tool_group"), "restored apply_patch activity must remain standalone")


func _test_intelligence_tool_activity(view) -> void:
	view._session = {"events": []}
	var wire_query: Dictionary = JSON.parse_string('{"scope":"scene","max_nodes":2,"max_depth":1}')
	_expect(view._safe_tool_arguments(wire_query, "inspect_editor_scene") == {"scope": "scene", "max_nodes": 2, "max_depth": 1}, "live activity must retain normalized integral limits from provider JSON")
	view._clear_chat_feed()
	await process_frame
	view._on_tool_execution_started("skill_1", "read_project_skill", {"name": "Godot Gameplay", "body": "private skill body", "sha256": "private hash"})
	view._on_tool_execution_completed("skill_1", "read_project_skill", {"content": "private skill body", "outcome": "completed", "data": {"body": "private skill body", "sha256": "private hash"}}, 4)
	view._on_tool_execution_started("api_1", "inspect_godot_api", {"class_name": "Node", "member_name": "add_child", "member_kind": "method", "include_inherited": true, "report": "private report"})
	view._on_tool_execution_completed("api_1", "inspect_godot_api", {"content": "private API report", "outcome": "completed", "data": {"help_topic": "class_method:Node:add_child", "report": "private report"}}, 5)
	view._on_tool_execution_started("function_1", "read_gdscript_function", {"filepath": "res://player.gd", "function_name": "move", "start_line_hint": 8, "include_documentation": false, "disk_sha256": "private hash"})
	view._on_tool_execution_completed("function_1", "read_gdscript_function", {"content": "private function body", "outcome": "completed", "data": {"open_path": "res://player.gd", "open_line": 9, "disk_sha256": "private hash"}}, 6)
	view._on_tool_execution_started("deps_1", "discover_dependencies", {"filepath": "res://main.tscn", "direction": "reverse", "max_depth": 3, "max_results": 50, "graph": "private graph"})
	view._on_tool_execution_completed("deps_1", "discover_dependencies", {"content": "private dependency graph", "outcome": "completed", "data": {"graph": "private graph"}}, 7)
	view._on_tool_execution_started("live_1", "inspect_editor_scene", {"scope": "subtree", "node_path": "Menu/Panel", "scene_path": "res://menu.tscn", "max_depth": 2, "nodes": ["private live scene"], "base_hash": "private hash"})
	view._on_tool_execution_completed("live_1", "inspect_editor_scene", {"content": "private live scene", "outcome": "completed", "data": {"source": "editor_scene", "returned_node_count": 3, "unsaved_changes": true, "truncated": true, "nodes": ["private live scene"]}}, 8)
	var navigation_query: Dictionary = JSON.parse_string('{"query":"health","kind":"member","path":"res://scripts","max_results":20,"source":"private source index"}')
	view._on_tool_execution_started("symbols", "find_project_symbols", navigation_query)
	view._on_tool_execution_completed("symbols", "find_project_symbols", {"content": "private source index", "outcome": "completed", "data": {"returned_match_count": 2, "truncation": {"truncated": true}, "matches": [{"filepath": "res://player.gd", "line": 3, "column": 5, "preview": "private source index"}]}}, 9)
	view._on_tool_execution_started("references", "find_symbol_references", {"symbol": "health", "include_declarations": false, "source": "private source index"})
	view._on_tool_execution_completed("references", "find_symbol_references", {"content": "private source index", "outcome": "completed", "data": {"returned_match_count": 0}}, 10)
	var groups := _collect_nodes(view.chat_feed, "orca_tool_group")
	_expect(groups.size() == 1 and groups[0].call_count() == 7, "intelligence, live editor and code-navigation reads should join consecutive activity groups")
	var events: Array = view._session.get("events", [])
	var persisted := JSON.stringify(events)
	_expect(events.size() == 7 and events[0].get("arguments") == {"name": "Godot Gameplay"}, "skill activity should persist only its bounded name")
	_expect(events[1].get("arguments", {}).get("class_name") == "Node" and events[1].get("help_topic") == "class_method:Node:add_child", "API activity should persist its safe query and help topic")
	_expect(events[2].get("arguments", {}).get("function_name") == "move" and events[2].get("open_path") == "res://player.gd", "function activity should retain bounded query and file navigation metadata")
	_expect(events[3].get("arguments", {}).get("direction") == "reverse" and events[3].get("arguments", {}).get("max_results") == 50, "dependency activity should retain only its bounded query controls")
	_expect(not persisted.contains("private skill body") and not persisted.contains("private API report") and not persisted.contains("private function body") and not persisted.contains("private dependency graph") and not persisted.contains("private hash") and not persisted.contains("private report"), "intelligence activity must redact bodies, reports, graphs, and hashes")
	_expect(not persisted.contains("private live scene") and events[4].get("arguments") == {"scope": "subtree", "node_path": "Menu/Panel", "scene_path": "res://menu.tscn", "max_depth": 2}, "live inspection must persist only bounded query controls, never nodes or snapshot values")
	_expect(str(events[4].get("summary", "")).contains("Historical") and str(events[4].get("summary", "")).contains("unsaved") and str(events[4].get("summary", "")).contains("truncated"), "restorable live activity should honestly identify historical dirty/truncated inspection")
	_expect(events[5]["arguments"] == {"query": "health", "kind": "member", "path": "res://scripts", "max_results": 20} and events[6]["arguments"] == {"symbol": "health", "include_declarations": false}, "navigation activity must retain only bounded query metadata, including provider JSON limits")
	_expect(not persisted.contains("private source index") and str(events[5]["summary"]).contains("Historical") and str(events[5]["summary"]).contains("incomplete"), "navigation snapshots must be redacted and historical incomplete scans labeled honestly")
	var live_card = groups[0].get_card("live_1")
	_expect(live_card._header_button.text.contains("Inspect live scene") and live_card._header_button.text.contains("Menu/Panel") and not live_card._open_button.visible, "live cards need scope labels without reopening or saving an edited scene")
	var api_card = groups[0].get_card("api_1")
	_expect(api_card != null and api_card._help_button.visible, "live API execution metadata should show Open Docs")
	groups[0].set_expanded(true)
	await process_frame
	_expect(groups[0].get_combined_minimum_size().x <= 300.0, "intelligence activity must remain usable at narrow dock widths")

	view._clear_chat_feed()
	await process_frame
	view._render_session_event(events[1])
	view._close_active_tool_group()
	var restored_groups := _collect_nodes(view.chat_feed, "orca_tool_group")
	var restored_card = restored_groups[0].get_card("api_1") if restored_groups.size() == 1 else null
	_expect(restored_card != null and restored_card._help_button.visible, "restored API activity should reconstruct Open Docs metadata")
	view._render_session_event(events[4])
	var restored_live = restored_groups[0].get_card("live_1") if restored_groups.size() == 1 else null
	# The API group was closed above, so the historical live read starts a new group.
	var all_restored := _collect_nodes(view.chat_feed, "orca_tool_group")
	if all_restored.size() == 2:
		restored_live = all_restored[1].get_card("live_1")
	_expect(restored_live != null and restored_live._details.text.contains("Historical") and not restored_live._open_button.visible, "restored snapshots must be historical summaries without actionable editor identity")
	view._render_session_event(events[5])
	var restored_navigation = _collect_nodes(view.chat_feed, "orca_tool_group")[-1].get_card("symbols")
	_expect(restored_navigation != null and restored_navigation._match_list.get_child_count() == 0 and restored_navigation._details.text.contains("Historical"), "restored code navigation must show only historical summaries, never stale result rows")
	view._on_help_requested("https://example.invalid/docs")


func _test_task_panel_integration(view) -> void:
	view._session = {"events": []}
	var tasks := [{"content": "Inspect", "status": "completed"}, {"content": "Implement", "status": "in_progress"}]
	view._on_tasks_changed(tasks)
	_expect(view._session.get("tasks") == tasks, "live task changes should update session state")
	_expect(view.task_list_panel.get_tasks() == tasks, "live task changes should update the persistent panel")
	view._on_tool_execution_started("task_failure", "update_tasks", {"tasks": [{"content": "invalid", "status": "invalid"}]})
	view._on_tool_execution_completed("task_failure", "update_tasks", {"success": false, "content": "Error: invalid status", "outcome": "failed", "data": {}}, 5)
	_expect(view.task_list_panel.get_tasks() == tasks, "failed task updates must preserve the displayed checklist")
	var events: Array = view._session.get("events", [])
	_expect(events.size() == 1 and events[0].get("name") == "update_tasks", "failed task updates should remain visible as bounded activity")
	_expect(events[0].get("arguments", {}).is_empty(), "raw task payloads must not be persisted in activity events")


func _test_game_operation_cards(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	await process_frame
	view._on_tool_execution_started("run_1", "run_current_scene", {"verification": {"kind": "clean_startup", "claim": "must-not-persist", "required_stdout": ["private-marker"]}})
	view._on_tool_execution_completed("run_1", "run_current_scene", {"success": true, "content": "Started with private PID 123 and output secret", "outcome": "completed", "data": {"state": "running", "scene_path": "res://main.tscn"}}, 8)
	var latest: Node = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	_expect(not latest.has_meta("orca_tool_group"), "run operations should remain standalone external-state boundaries")
	var buttons := _collect_type(latest, Button)
	_expect(buttons.any(func(button): return button.text.contains("Run current scene")), "run activity should use a readable operation label")
	view._on_tool_execution_started("diagnostics_after_run", "get_diagnostics", {})
	view._on_tool_execution_completed("diagnostics_after_run", "get_diagnostics", {"success": true, "content": "private runtime output", "outcome": "completed", "data": {"open_path": "res://main.gd", "open_line": 2}}, 10)
	view._on_tool_execution_started("observe_run", "observe_game_run", {"run_id": 9, "after_sequence": 2})
	view._on_tool_execution_completed("observe_run", "observe_game_run", {"success": true, "content": "private observation", "outcome": "completed", "data": {"run_id": 9, "sequence": 3}}, 4)
	var groups := _collect_nodes(view.chat_feed, "orca_tool_group")
	_expect(groups.size() == 1 and groups[0].call_count() == 2, "diagnostics and run observation should remain grouped reads after a standalone run boundary")
	view._on_tool_execution_started("verify_run", "verify_game_run", {"run_id": 9})
	view._on_tool_execution_completed("verify_run", "verify_game_run", {"success": true, "content": "private verification evidence", "outcome": "completed", "data": {"status": "passed"}}, 3)
	latest = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
	_expect(not latest.has_meta("orca_tool_group"), "verification should remain a standalone evidence boundary")
	var events: Array = view._session.get("events", [])
	var persisted := JSON.stringify(events)
	_expect(events.size() == 4 and not persisted.contains("private PID") and not persisted.contains("private-marker") and not persisted.contains("must-not-persist") and not persisted.contains("private runtime output") and not persisted.contains("private observation") and not persisted.contains("private verification evidence") and not persisted.contains("\"run_id\""), "run, observation, and verification events must not persist identities, criteria, markers, or raw evidence")
	_expect(events[3].get("summary") == "Verification passed.", "persisted verification activity should retain the verdict instead of claiming generic success")
	view._on_workflow_state_changed("observing", {"run_id": 9})
	_expect(view._transient_card != null and is_instance_valid(view._transient_card), "bounded observation should show a transient workflow state")
	view._on_workflow_state_changed("assessment_ready", {"run_id": 9})
	_expect(view._transient_card != null and is_instance_valid(view._transient_card), "assessment-ready transition should replace the observation status")


func _test_input_map_change_card(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	view._on_tool_execution_started("input_change", "propose_input_map_changes", {"base_hash": "secret-hash", "changes": [{"operation": "upsert", "action": "jump", "events": [{"type": "key", "keycode": KEY_SPACE}]}]})
	view._on_edit_proposed({
		"id": "input_change",
		"kind": "input_map",
		"filepath": "res://project.godot",
		"status": "pending",
		"old_hash": "old",
		"new_hash": "new",
		"action_names": ["jump"],
		"review": [{"operation": "add", "action": "jump", "before": null, "after": {"deadzone": 0.5, "events": [{"type": "key", "keycode": KEY_SPACE, "physical_keycode": 0}]}}],
		"validation": {"valid": true, "message": "Passed"}
	})
	await process_frame
	var cards := _collect_nodes(view.chat_feed, "orca_input_map_change_card")
	_expect(cards.size() == 1, "Input Map proposals should use the dedicated structured review card")
	if cards.size() == 1:
		_expect(cards[0].get_combined_minimum_size().x <= 300.0, "Input Map review cards should remain within the 300 px dock width")
		var rendered: String = cards[0]._format_action({"deadzone": 0.5, "events": [{"type": "key", "keycode": KEY_K, "physical_keycode": KEY_P, "unicode": 65, "ctrl": true, "alt": false, "shift": true, "meta": false, "device": 2}]})
		_expect(rendered.contains("key=") and rendered.contains("physical=") and rendered.contains("unicode=U+0041") and rendered.contains("modifiers=ctrl+shift") and rendered.contains("device=2"), "structured review must show every behaviorally significant key field")
	var events: Array = view._session.get("events", [])
	_expect(events.size() == 2 and events[1].get("kind") == "input_map", "structured proposals should persist a typed non-actionable change summary")
	_expect(events[1].get("summary") == "Input Map: jump", "Input Map change summaries should retain bounded action labels")
	_expect(not JSON.stringify(events).contains("secret-hash") and not events[1].has("review"), "proposal hashes from tool arguments and structured event payloads must not persist")
	view._on_edit_resolved("input_change", "rejected", "Rejected")
	_expect(events[1].get("status") == "rejected" or view._session.get("events", [])[1].get("status") == "rejected", "structured review resolution should update the persisted status")


func _test_main_scene_change_card(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	view._on_tool_execution_started("main_change", "propose_main_scene_change", {"base_hash": "must-not-persist", "scene_path": "res://scenes/main.tscn"})
	view._on_edit_proposed({
		"id": "main_change",
		"kind": "main_scene",
		"filepath": "res://project.godot",
		"status": "pending",
		"old_scene_path": "res://old.tscn",
		"new_scene_path": "res://scenes/main.tscn",
		"validation": {"valid": true, "message": "Passed"}
	})
	await process_frame
	var cards := _collect_nodes(view.chat_feed, "orca_main_scene_change_card")
	_expect(cards.size() == 1, "main scene proposals should use the dedicated structured review card")
	if cards.size() == 1:
		_expect(cards[0].get_combined_minimum_size().x <= 300.0, "main scene review cards should remain within the 300 px dock width")
	var events: Array = view._session.get("events", [])
	_expect(events.size() == 2 and events[1].get("kind") == "main_scene", "main scene proposals should persist a typed non-actionable summary")
	_expect(events[1].get("summary") == "Main scene: res://scenes/main.tscn", "main scene summaries should retain the proposed canonical path")
	_expect(not JSON.stringify(events).contains("must-not-persist") and not events[1].has("old_hash"), "main scene activity must not persist proposal hashes or private state")


func _test_project_settings_change_card(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	view._on_tool_execution_started("settings_change", "propose_project_settings_changes", {"base_hash": "must-not-persist", "changes": [{"setting_path": "display/window/size/viewport_width", "value": 1920}]})
	view._on_edit_proposed({
		"id": "settings_change",
		"kind": "project_settings",
		"filepath": "res://project.godot",
		"status": "pending",
		"review": [{"setting_path": "display/window/size/viewport_width", "label": "Viewport width", "type": "int", "before": 1152, "after": 1920}],
		"validation": {"valid": true, "message": "Passed"}
	})
	await process_frame
	var cards := _collect_nodes(view.chat_feed, "orca_project_settings_change_card")
	_expect(cards.size() == 1, "allowlisted ProjectSettings proposals should use the dedicated structured review card")
	if cards.size() == 1:
		_expect(cards[0].get_combined_minimum_size().x <= 300.0, "ProjectSettings review cards should remain within the 300 px dock width")
	var events: Array = view._session.get("events", [])
	_expect(events.size() == 2 and events[1].get("kind") == "project_settings", "ProjectSettings proposals should persist a typed non-actionable summary")
	_expect(events[1].get("summary") == "Project settings: Viewport width", "ProjectSettings summaries should retain bounded labels")
	_expect(not JSON.stringify(events).contains("must-not-persist") and not JSON.stringify(events).contains("1920"), "ProjectSettings activity must not persist hashes or values")


func _test_scene_change_card(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	view._on_tool_execution_started("scene_change", "propose_scene_changes", {"scene_path": "res://scenes/world.tscn", "base_hash": "", "operations": [{"operation": "create_scene", "root_type": "Node2D", "root_name": "World"}]})
	view._on_edit_proposed({
		"id": "scene_change",
		"kind": "scene",
		"filepath": "res://scenes/world.tscn",
		"status": "pending",
		"scene_summary": {"node_count": 1, "root_type": "Node2D", "root_name": "World"},
		"validation": {"valid": true, "message": "Packed and reloaded"}
	})
	await process_frame
	var cards := _collect_nodes(view.chat_feed, "orca_scene_change_card")
	_expect(cards.size() == 1, "structured scene proposals should use the dedicated review card")
	if cards.size() == 1:
		_expect(cards[0].get_combined_minimum_size().x <= 300.0, "scene review cards should remain within the 300 px dock width")
		var details := _collect_nodes(cards[0], "orca_scene_change_details", Label)
		_expect(details.size() == 1 and details[0].text.contains("Node2D") and details[0].text.contains("World"), "scene review should show the resulting root type and name")
	var events: Array = view._session.get("events", [])
	_expect(events.size() == 2 and events[1].get("kind") == "scene", "scene proposals should persist a typed non-actionable summary")
	_expect(events[1].get("summary") == "Create scene: res://scenes/world.tscn - Node2D \"World\"", "scene summary should retain the target and root identity")
	_expect(not JSON.stringify(events).contains("create_scene") and not events[1].has("scene_summary"), "scene activity must not persist operation payloads or structured proposal internals")


func _test_add_node_change_card(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	view._on_tool_execution_started("add_node_change", "propose_scene_changes", {"scene_path": "res://scenes/world.tscn", "base_hash": "must-not-persist", "operations": [{"operation": "add_node", "parent_path": "./Container", "node_type": "Node2D", "node_name": "SpawnPoint"}]})
	view._on_edit_proposed({
		"id": "add_node_change",
		"kind": "scene",
		"filepath": "res://scenes/world.tscn",
		"status": "pending",
		"scene_summary": {"operation": "add_node", "before_node_count": 3, "after_node_count": 4, "root_type": "Node2D", "root_name": "World", "added_node": {"path": "./Container/SpawnPoint", "parent_path": "./Container", "type": "Node2D", "name": "SpawnPoint", "owner_path": ".", "sibling_index": -1, "serialized_property_count": 0}},
		"validation": {"valid": true, "message": "Packed and reloaded"}
	})
	await process_frame
	var cards := _collect_nodes(view.chat_feed, "orca_scene_change_card")
	_expect(cards.size() == 1, "add_node should reuse the structured scene review card")
	if cards.size() == 1:
		var details := _collect_nodes(cards[0], "orca_scene_change_details", Label)
		_expect(details.size() == 1 and details[0].text.contains("./Container") and details[0].text.contains("SpawnPoint") and details[0].text.contains("4 nodes"), "add_node review should show parent, node, and resulting count")
	var events: Array = view._session.get("events", [])
	_expect(events.size() == 2 and events[1].get("summary") == "Add node: res://scenes/world.tscn - Node2D \"SpawnPoint\" at ./Container", "add_node should persist a bounded hierarchy summary")
	_expect(not JSON.stringify(events).contains("must-not-persist") and not JSON.stringify(events).contains("parent_path"), "add_node persistence should exclude hashes and authoritative operations")


func _test_scene_operation_summaries(view) -> void:
	var filepath := "res://scenes/world.tscn"
	var cases := [
		[{"operation": "set_property", "node_path": "./Player", "property_name": "position", "before": {"type": "Vector2", "x": 0, "y": 0}, "after": {"type": "Vector2", "x": 10, "y": 20}}, "Set property:"],
		[{"operation": "rename_node", "old_path": "./Old", "new_path": "./New", "new_name": "New"}, "Rename node:"],
		[{"operation": "remove_node", "removed_node": {"path": "./Old"}}, "Remove node:"],
		[{"operation": "reparent_node", "old_path": "./A/Leaf", "new_parent_path": "./B"}, "Reparent node:"],
		[{"operation": "instantiate_child_scene", "instance": {"scene_path": "res://enemy.tscn", "parent_path": "./Enemies"}}, "Instantiate scene:"],
		[{"operation": "connect_signal", "connection": {"source": "./Timer", "signal": "timeout", "target": ".", "method": "queue_free", "flags": Object.CONNECT_PERSIST | Object.CONNECT_DEFERRED}}, "Connect signal:"],
		[{"operation": "disconnect_signal", "connection": {"source": "./Timer", "signal": "timeout", "target": ".", "method": "queue_free"}}, "Disconnect signal:"]
	]
	for item in cases:
		var summary: String = view._proposal_summary({"kind": "scene", "filepath": filepath, "scene_summary": item[0]})
		_expect(summary.begins_with(item[1]), "scene operation should have a bounded typed summary: " + str(item[0].get("operation", "")))
		_expect(summary.length() <= 512, "scene operation summaries should remain bounded")
	var property_id := "property_change"
	view._session = {"events": []}
	view._clear_chat_feed()
	view._on_tool_execution_started(property_id, "propose_scene_changes", {"scene_path": filepath, "base_hash": "private", "operations": [{"operation": "set_property", "value": {"type": "Vector2", "x": 10, "y": 20}}]})
	view._on_edit_proposed({"id": property_id, "kind": "scene", "filepath": filepath, "status": "pending", "scene_summary": cases[0][0], "validation": {"valid": true, "message": "Passed"}})
	await process_frame
	var cards := _collect_nodes(view.chat_feed, "orca_scene_change_card")
	var details := _collect_nodes(cards[0], "orca_scene_change_details", Label) if cards.size() == 1 else []
	_expect(details.size() == 1 and details[0].text.contains("position") and details[0].text.contains("Proposed"), "typed property review should show previous and proposed values")
	var persisted := JSON.stringify(view._session.get("events", []))
	_expect(not persisted.contains("private") and not persisted.contains("\"x\":10"), "typed property values and hashes must not persist in session events")


func _test_script_trust_change_card(view) -> void:
	view._session = {"events": []}
	view._clear_chat_feed()
	var change_id := "script_trust_change"
	var filepath := "res://scenes/actor.tscn"
	var script_path := "res://scripts/actor.gd"
	view._on_tool_execution_started(change_id, "propose_scene_changes", {"scene_path": filepath, "base_hash": "private-scene-hash", "operations": [{"operation": "attach_script", "node_path": ".", "script_path": script_path, "script_hash": "private-script-hash"}]})
	view._on_edit_proposed({
		"id": change_id, "kind": "scene", "approval_stage": "script_trust", "filepath": filepath, "status": "pending",
		"scene_summary": {"operation": "attach_script", "node_path": ".", "script_path": script_path, "trust_review": true},
		"validation": {"valid": true, "message": "Approval may execute script initialization."}
	})
	await process_frame
	var cards := _collect_nodes(view.chat_feed, "orca_scene_change_card")
	var details := _collect_nodes(cards[0], "orca_scene_change_details", Label) if cards.size() == 1 else []
	var buttons := _collect_type(cards[0], Button) if cards.size() == 1 else []
	var has_trust_button := buttons.any(func(button): return button.text == "Trust and Prepare")
	_expect(cards.size() == 1 and details.size() == 1 and details[0].text.contains("compile, load, and instantiate"), "script trust stage should show a prominent execution warning in one scene card")
	_expect(has_trust_button, "script trust stage should use an explicit Trust and Prepare action")
	view._on_edit_proposed({
		"id": change_id, "kind": "scene", "approval_stage": "candidate", "filepath": filepath, "status": "pending",
		"scene_summary": {"operation": "attach_script", "node_path": ".", "node_type": "Node2D", "script_base": "Node2D", "before_script": "", "after_script": script_path},
		"validation": {"valid": true, "message": "Trusted script loaded and candidate revalidated."}
	})
	await process_frame
	cards = _collect_nodes(view.chat_feed, "orca_scene_change_card")
	details = _collect_nodes(cards[0], "orca_scene_change_details", Label) if cards.size() == 1 else []
	buttons = _collect_type(cards[0], Button) if cards.size() == 1 else []
	var has_apply_button := buttons.any(func(button): return button.text == "Apply")
	_expect(cards.size() == 1 and details.size() == 1 and details[0].text.contains("Proposed") and details[0].text.contains(script_path), "candidate stage should reuse the same card and show the exact attachment transition")
	_expect(has_apply_button, "candidate stage should restore the normal Apply action")
	var events: Array = view._session.get("events", [])
	_expect(events.size() == 2 and events[1].get("summary") == "Attach script: %s - %s at ." % [filepath, script_path], "two-stage script review should update one persisted change event")
	var persisted := JSON.stringify(events)
	_expect(not persisted.contains("private-scene-hash") and not persisted.contains("private-script-hash") and not persisted.contains("trust_binding"), "script trust activity must not persist hashes or private trust state")


func _test_expanded_diff_content() -> void:
	var old_lines := PackedStringArray()
	for line in range(1, 36):
		old_lines.append("line %d" % line)
	var new_lines := old_lines.slice(0, 28)
	var old_content := "\n".join(old_lines) + "\n"
	var new_content := "\n".join(new_lines) + "\n"
	var card := ChangeCard.new()
	get_root().add_child(card)
	await process_frame
	card.configure({
		"id": "expanded_diff",
		"kind": "file_patch",
		"filepath": "res://main.tscn",
		"old_content": old_content,
		"new_content": new_content,
		"diff": DiffUtils.create_diff(old_content, new_content),
		"validation": {"valid": true, "message": "Passed"},
		"existed": true,
		"status": "pending"
	})
	card._show_expanded_diff()
	await process_frame
	var editors := _collect_type(card, CodeEdit)
	_expect(editors.size() == 2, "expanded diff should create previous and proposed code panes")
	if editors.size() == 2:
		_expect(editors[0].text == old_content, "expanded diff previous pane should retain exact old content")
		_expect(editors[1].text == new_content, "expanded diff proposed pane should retain exact new content")
	var dialogs := _collect_type(card, Window)
	var apply_visibility := []
	card.action_requested.connect(func(_id: String, action: String):
		if action == "apply" and not dialogs.is_empty():
			apply_visibility.append(dialogs[0].visible)
	)
	var expanded_buttons := _collect_type(dialogs[0], Button) if not dialogs.is_empty() else []
	var apply_buttons := expanded_buttons.filter(func(button): return button.text == "Apply")
	if not apply_buttons.is_empty():
		apply_buttons[0].pressed.emit()
	_expect(apply_visibility == [false], "expanded diff should release exclusive ownership before emitting Apply")
	await process_frame
	card._show_expanded_diff()
	await process_frame
	dialogs = _collect_type(card, Window)
	var reject_visibility := []
	card.action_requested.connect(func(_id: String, action: String):
		if action == "reject" and not dialogs.is_empty():
			reject_visibility.append(dialogs[0].visible)
	)
	expanded_buttons = _collect_type(dialogs[0], Button) if not dialogs.is_empty() else []
	var reject_buttons := expanded_buttons.filter(func(button): return button.text == "Reject")
	if not reject_buttons.is_empty():
		reject_buttons[0].pressed.emit()
	_expect(reject_visibility == [false], "expanded diff should release exclusive ownership before emitting Reject")
	await process_frame
	var reviewed_diff := card._diff_label.text
	var automatic := card._proposal.duplicate(true)
	automatic["_auto_apply"] = true
	card.configure(automatic)
	_expect(card._diff_label.visible and card._diff_label.text == reviewed_diff and card._status_label.text == "Applying", "automatic application must keep the exact manual inline review while applying")
	card._show_expanded_diff()
	await process_frame
	dialogs = _collect_type(card, Window)
	expanded_buttons = _collect_type(dialogs[0], Button) if not dialogs.is_empty() else []
	_expect(expanded_buttons.filter(func(button): return button.text in ["Apply", "Reject"]).is_empty(), "expanded automatic review must not expose duplicate approval actions while applying")
	if not dialogs.is_empty(): card._dismiss_expanded_diff(dialogs[0])
	await process_frame
	card.set_status("applied", "Applied automatically.")
	_expect(card._diff_label.visible and card._revert_button.visible and card._status_label.text == "Applied", "completed automatic review retains the same diff and guarded Revert")
	card.set_status("applied_recovery", "Cleanup required: applied with a retained backup.")
	_expect(card._revert_button.visible, "a committed file patch with cleanup required should retain its guarded Revert action")
	card.set_status("apply_recovery_required", "Recovery required: destination state is uncertain.")
	_expect(not card._revert_button.visible, "an uncertain file-patch apply must not offer unsafe Revert")
	card.queue_free()


func _test_recovery_event_persistence(view) -> void:
	view._session = {"events": [
		{"type": "change", "id": "recovery_change", "filepath": "res://main.gd", "status": "pending"},
		{"type": "tool", "id": "recovery_tool", "name": "apply_patch", "outcome": "running", "summary": "Running", "duration_ms": 0},
	]}
	view._tool_event_indices = {"recovery_tool": 1}
	var absolute_backup := ProjectSettings.globalize_path("res://main.gd.orca_backup_123")
	view._update_change_event("recovery_change", "apply_recovery_required", "Recovery required: Recovery copy: " + absolute_backup)
	var change_event: Dictionary = view._session.get("events", [])[0]
	_expect(change_event.get("status") == "apply_recovery_required", "uncertain mutation status should persist distinctly")
	_expect(str(change_event.get("resolution_message", "")).contains("res://main.gd.orca_backup_123") and not str(change_event.get("resolution_message", "")).contains(ProjectSettings.globalize_path("res://").trim_suffix("/")), "persisted recovery guidance should retain a project-relative recovery copy without the absolute project path")
	view._update_tool_event("recovery_tool", {"outcome": "apply_recovery_required", "data": {}}, 1)
	var tool_event: Dictionary = view._session.get("events", [])[1]
	_expect(tool_event.get("summary") == "Recovery required. See the associated change record.", "uncertain mutation activity must not persist as completed successfully")
	view._session["events"][1]["name"] = "inspect_scene"
	view._update_tool_event("recovery_tool", {"outcome": "failed", "data": {}}, 1)
	_expect(view._session["events"][1].get("summary") == "Tool did not complete.", "ordinary read failures must not claim that a file recovery/change record exists")

	for card_script in [InputMapChangeCard, MainSceneChangeCard, ProjectSettingsChangeCard, SceneChangeCard]:
		var structured_card = card_script.new()
		get_root().add_child(structured_card)
		await process_frame
		structured_card.configure({"id": "structured_recovery", "filepath": "res://fixture.tscn", "review": [], "scene_summary": {}, "validation": {"valid": true, "message": "Passed"}, "status": "pending"})
		structured_card.set_status("applied_recovery", "Cleanup required: retained backup.")
		_expect(structured_card._revert_button.visible, "committed structured cleanup warnings should retain guarded Revert")
		structured_card.set_status("apply_recovery_required", "Recovery required: destination state is uncertain.")
		_expect(not structured_card._revert_button.visible, "uncertain structured applies must hide Revert")
		_expect(structured_card._validation_label.text.contains("destination state is uncertain"), "structured cards should surface recovery-required details")
		structured_card.set_status("revert_recovery_required", "Recovery required: revert state is uncertain.")
		_expect(not structured_card._revert_button.visible, "uncertain structured reverts must hide Revert")
		structured_card.queue_free()


func _count_blocks(blocks: Array, type: String) -> int:
	var count := 0
	for block in blocks:
		if block.get("type") == type:
			count += 1
	return count


func _collect_nodes(root: Node, meta_name: String, required_type = null) -> Array:
	var result := []
	if root.has_meta(meta_name) and (required_type == null or is_instance_of(root, required_type)):
		result.append(root)
	for child in root.get_children():
		result.append_array(_collect_nodes(child, meta_name, required_type))
	return result


func _collect_type(root: Node, type) -> Array:
	var result := []
	if is_instance_of(root, type):
		result.append(root)
	for child in root.get_children():
		result.append_array(_collect_type(child, type))
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("chat_window_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("chat_window_test: ", failure)
	quit(1)
