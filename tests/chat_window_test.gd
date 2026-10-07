extends SceneTree

const ChatWindow = preload("res://addons/orca/scripts/chat_window.gd")
const ChatWindowScene = preload("res://addons/orca/scenes/chat_window.tscn")
const TaskListPanel = preload("res://addons/orca/scripts/task_list_panel.gd")
const ChangeCard = preload("res://addons/orca/scripts/change_card.gd")
const DiffUtils = preload("res://addons/orca/scripts/diff_utils.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

class FakeAgent:
	extends RefCounted

	func get_mode() -> int:
		return 1

	func is_busy() -> bool:
		return true


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
	await _test_final_rendering(view)
	await process_frame
	await process_frame
	_test_working_indicator(view)
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
	view._session = {}
	view._has_session_content = false
	if view.task_list_panel != null and view.task_list_panel.get_parent() == get_root():
		view.task_list_panel.queue_free()
	view.queue_free()
	await process_frame
	_finish()


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
	_expect(not image_button.visible, "the unavailable image action should not reserve narrow composer width")
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
	var groups := _collect_nodes(view.chat_feed, "orca_tool_group")
	_expect(groups.size() == 1 and groups[0].call_count() == 4, "all Orca 1.1 intelligence reads should join consecutive activity groups")
	var events: Array = view._session.get("events", [])
	var persisted := JSON.stringify(events)
	_expect(events.size() == 4 and events[0].get("arguments") == {"name": "Godot Gameplay"}, "skill activity should persist only its bounded name")
	_expect(events[1].get("arguments", {}).get("class_name") == "Node" and events[1].get("help_topic") == "class_method:Node:add_child", "API activity should persist its safe query and help topic")
	_expect(events[2].get("arguments", {}).get("function_name") == "move" and events[2].get("open_path") == "res://player.gd", "function activity should retain bounded query and file navigation metadata")
	_expect(events[3].get("arguments", {}).get("direction") == "reverse" and events[3].get("arguments", {}).get("max_results") == 50, "dependency activity should retain only its bounded query controls")
	_expect(not persisted.contains("private skill body") and not persisted.contains("private API report") and not persisted.contains("private function body") and not persisted.contains("private dependency graph") and not persisted.contains("private hash") and not persisted.contains("private report"), "intelligence activity must redact bodies, reports, graphs, and hashes")
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
	card.set_status("applied_recovery", "Applied, but cleanup requires attention.")
	_expect(card._revert_button.visible, "a file patch in recovery state should retain its guarded Revert action")
	card.queue_free()


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
