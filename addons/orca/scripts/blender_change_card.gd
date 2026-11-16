@tool
extends "res://addons/orca/scripts/mcp_read_card.gd"

signal preview_attachment_requested(image: Dictionary)
signal auto_apply_requested

var _operation := ""
var _automatic := false
var _overview: Label
var _auto_button: Button
var _technical: CheckBox
var _live := false

func configure(request: Dictionary, turn_id: int) -> void:
	super.configure(request, turn_id)
	_operation = str(request.get("operation", ""))
	_live = request.get("live_operation", false)
	_automatic = request.get("auto_apply", false)
	_title.text = "Blender workspace operation" if _automatic else "Review Blender workspace operation"
	_help.text = "Approve this exact operation in the dedicated asset workspace. Project imports have their own reviewed destination and recovery checkpoint."
	if _live:
		_title.text = "Live Blender operation" if _automatic else "Review live Blender operation"
		_help.text = "Approve this exact operation in your open Blender scene. Edits retain a recovery copy and remain unsaved in Blender. Project import and placement require their own review."
		if _operation in ["preview", "export"]: _help.text = "Preview/export uses a private saved copy in one bounded background Blender worker. Your open document is preserved. Only the reviewed objects and their included rig/parents are handed off."
	_allow.text = "Apply operation" if request.get("operation") in ["edit", "import", "place"] else "Allow operation"
	var overview := Label.new()
	_overview = overview
	overview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overview.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var lines := PackedStringArray([str(request.get("operation", "")).capitalize() + " · " + "Revision " + str(request.get("revision", ""))])
	if _live: lines.append(str(request.get("document", "")) + " · " + str(request.get("scene", "")))
	if request.has("objects"): lines.append("• " + ", ".join(request["objects"]))
	if request.get("operation") == "edit":
		var commands = JSON.parse_string(str(request.get("commands", "[]")))
		if commands is Array:
			for command in commands:
				lines.append("• " + str(command.get("op", "")).replace("_", " ").capitalize() + " · " + str(command.get("name", command.get("objects", ""))) + (" · " + str(command["kind"]) if command.has("kind") else ""))
	if request.has("destination"): lines.append("→ " + str(request["destination"]))
	if request.has("placement"): lines.append("→ " + str(request["placement"].get("scene", "")))
	overview.text = "\n".join(lines)
	get_child(0).add_child(overview)
	get_child(0).move_child(overview, 2)
	var details := CheckBox.new()
	_technical = details
	details.text = "Technical review details"
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.toggled.connect(func(expanded: bool):
		_details.visible = expanded
		_overview.visible = expanded)
	get_child(0).add_child(details)
	get_child(0).move_child(details, 3)
	_details.hide()
	if _automatic:
		_help.hide()
		_overview.hide()
		_allow.disabled = true
		_reject.disabled = true
		_allow.hide()
		_reject.hide()
		_status.text = "Running automatically…"
	elif _operation in ["help", "inspect", "edit", "preview", "export"]:
		_auto_button = Button.new()
		_auto_button.text = "Auto apply live session…" if _live else "Auto apply workspace…"
		_auto_button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_auto_button.pressed.connect(func(): auto_apply_requested.emit())
		get_child(0).add_child(_auto_button)

func complete(execution: Dictionary, duration_ms: int) -> void:
	super.complete(execution, duration_ms)
	if _auto_button != null: _auto_button.hide()
	_help.hide()
	_overview.hide()
	_technical.set_pressed_no_signal(false)
	_details.hide()
	_status.text = "Auto applied" if execution.get("success", false) and execution.get("data", {}).get("auto_apply", false) else "Blender operation completed" if execution.get("success", false) else "Blender operation did not complete"
	if execution.get("data", {}).get("save_pending", false): _status.text = "Applied in editor · Save pending"
	if _live and execution.get("data", {}).get("save_pending", false): _status.text = "Applied in Blender · Save pending"
	if _live and execution.get("data", {}).get("save_pending", false) and execution.get("data", {}).get("auto_apply", false): _status.text = "Auto applied in Blender · Save pending"
	var image: Dictionary = execution.get("data", {}).get("preview_image", {})
	if not image.is_empty():
		var bytes: PackedByteArray = execution.get("data", {}).get("preview_glb", PackedByteArray())
		if not bytes.is_empty():
			var viewer := preload("res://addons/orca/scripts/blender_preview_view.gd").new()
			get_child(0).add_child(viewer)
			viewer.configure(bytes, preload("res://addons/orca/scripts/image_attachments.gd").texture(image))
		else:
			_add_thumbnail(image)
		var attach := Button.new()
		attach.text = "Attach preview to chat"
		attach.pressed.connect(func(): preview_attachment_requested.emit(image.duplicate(true)))
		get_child(0).add_child(attach)

func _add_thumbnail(image: Dictionary) -> void:
	var preview := TextureRect.new()
	preview.texture = preload("res://addons/orca/scripts/image_attachments.gd").texture(image)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size.y = UiMetrics.scaled(180)
	get_child(0).add_child(preview)
