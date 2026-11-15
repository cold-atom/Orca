@tool
extends VBoxContainer

const Loader = preload("res://addons/orca/scripts/blender_preview_loader.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const MAX_VIEWS := 3
static var _views: Array = []

var _surface: TextureRect
var _viewport: SubViewport
var _camera: Camera3D
var _model: Node3D
var _asset := {}
var _thumbnail: Texture2D
var _expanded: Window
var _hint: Label
var _scroll: ScrollContainer
var _yaw := 0.65
var _pitch := 0.35
var _radius := 1.0
var _distance := 3.0
var _center := Vector3.ZERO
var _target := Vector3.ZERO
var _drag := 0
var _on_screen := false
var _auto_frame := true

func _enter_tree() -> void:
	Localization.attach(self)

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_surface = TextureRect.new()
	_surface.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_surface.stretch_mode = TextureRect.STRETCH_SCALE
	_surface.custom_minimum_size.y = Metrics.scaled(220)
	_surface.mouse_filter = Control.MOUSE_FILTER_STOP
	_surface.focus_mode = Control.FOCUS_ALL
	_surface.gui_input.connect(_view_input)
	_surface.resized.connect(_resize_viewport)
	add_child(_surface)
	var actions := HFlowContainer.new()
	add_child(actions)
	for caption in ["Frame", "Reset", "Expand"]:
		var button := Button.new()
		button.text = caption
		if caption == "Frame": button.pressed.connect(frame_model)
		elif caption == "Reset": button.pressed.connect(reset_view)
		else: button.pressed.connect(_open_expanded)
		actions.add_child(button)
	_hint = Label.new()
	_hint.text = "Drag to orbit · Shift-drag or middle-drag to pan · Scroll to zoom"
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_color_override("font_color", Color(0.65, 0.69, 0.74))
	add_child(_hint)
	var parent := get_parent()
	while parent != null:
		if parent is Window: break
		if parent is ScrollContainer:
			_scroll = parent
			break
		parent = parent.get_parent()

func configure(bytes: PackedByteArray, thumbnail: Texture2D) -> bool:
	_thumbnail = thumbnail
	var asset := Loader.decode(bytes)
	if not asset.get("success", false):
		_surface.texture = thumbnail
		_surface.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_hint.text = "3D preview unavailable. The rendered image remains available."
		_disable_actions()
		return false
	configure_asset(asset, thumbnail)
	return true

func configure_asset(asset: Dictionary, thumbnail: Texture2D) -> void:
	_asset = asset
	_thumbnail = thumbnail
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.size = Vector2i(384, 256)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.handle_input_locally = false
	add_child(_viewport)
	_model = Node3D.new()
	_viewport.add_child(_model)
	for record in asset["meshes"]:
		var instance := MeshInstance3D.new()
		instance.mesh = record["mesh"]
		instance.transform = record["transform"]
		_model.add_child(instance)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.09, 0.105, 0.12)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.85, 0.89, 1.0)
	environment.ambient_light_energy = 0.65
	var world := WorldEnvironment.new()
	world.environment = environment
	_viewport.add_child(world)
	for rotation in [Vector3(-45, -35, 0), Vector3(-20, 145, 0)]:
		var light := DirectionalLight3D.new()
		light.rotation_degrees = rotation
		light.light_energy = 1.1 if rotation.y < 0 else 0.6
		_viewport.add_child(light)
	_camera = Camera3D.new()
	_camera.fov = 40
	_viewport.add_child(_camera)
	_camera.current = true
	var bounds: AABB = asset["bounds"]
	# Center only the display world, preserving immutable asset transforms while
	# avoiding camera look-at precision loss for small far-from-origin geometry.
	_model.position = -bounds.get_center()
	_center = Vector3.ZERO
	_radius = maxf(bounds.size.length() * 0.5, 0.001)
	_surface.texture = _viewport.get_texture()
	_surface.stretch_mode = TextureRect.STRETCH_SCALE
	frame_model()
	_resize_viewport()
	# At most three render scenes (including expanded viewers), not one per turn.
	_views = _views.filter(func(reference): return reference.get_ref() != null)
	_views.append(weakref(self))
	while _views.size() > MAX_VIEWS:
		var previous = _views.pop_front().get_ref()
		if is_instance_valid(previous): previous.release_preview()

func release_preview() -> void:
	_drag = 0
	_asset.clear()
	_camera = null
	_model = null
	if is_instance_valid(_viewport): _viewport.queue_free()
	_viewport = null
	_surface.texture = _thumbnail
	_surface.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_hint.text = "3D preview released to save memory. The rendered image remains available."
	_disable_actions()

func _disable_actions() -> void:
	for button in get_child(1).get_children():
		if button is Button: button.disabled = true

func frame_model() -> void:
	_auto_frame = true
	_target = _center
	var aspect := maxf(float(_viewport.size.x) / _viewport.size.y, 0.25) if _viewport != null else 1.0
	var angle := atan(tan(deg_to_rad(20)) * minf(aspect, 1.0))
	_distance = _radius / sin(angle) * 1.12
	_update_camera()

func reset_view() -> void:
	_yaw = 0.65
	_pitch = 0.35
	frame_model()

func _update_camera() -> void:
	if not is_instance_valid(_camera): return
	var direction := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch))
	_camera.position = _target + direction * _distance
	_camera.look_at(_target, Vector3.UP)
	_camera.near = maxf(0.0001, minf(_distance * 0.01, _radius * 0.01))
	_camera.far = maxf(_distance + _radius * 100, _camera.near * 1000)
	_redraw()

func _view_input(event: InputEvent) -> void:
	if not is_instance_valid(_camera): return
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			_drag = (2 if event.button_index == MOUSE_BUTTON_MIDDLE or event.shift_pressed else 1) if event.pressed else 0
			if event.pressed: _surface.grab_focus()
			_surface.accept_event()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_auto_frame = false
			_distance = clampf(_distance * (0.88 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.88), _radius * 0.05, _radius * 100)
			_update_camera()
			_surface.accept_event()
	elif event is InputEventMouseMotion and _drag != 0:
		if event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_MIDDLE) == 0:
			_drag = 0
			return
		if _drag == 1:
			_yaw = fposmod(_yaw - event.relative.x * 0.009, TAU)
			_pitch = clampf(_pitch + event.relative.y * 0.009, -1.48, 1.48)
		else:
			_auto_frame = false
			var rate := _distance * 2.0 * tan(deg_to_rad(20)) / maxf(_surface.size.y, 1)
			_target += (-_camera.basis.x * event.relative.x + _camera.basis.y * event.relative.y) * rate
			_target = _center + (_target - _center).limit_length(_radius * 100)
		_update_camera()
		_surface.accept_event()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_F:
		frame_model()
		_surface.accept_event()
	elif event is InputEventMagnifyGesture:
		_auto_frame = false
		_distance = clampf(_distance / maxf(event.factor, 0.1), _radius * 0.05, _radius * 100)
		_update_camera()
		_surface.accept_event()

func _resize_viewport() -> void:
	if _viewport == null: return
	var dimensions := _surface.size
	var ratio := minf(1.0, 1024.0 / maxf(dimensions.x, dimensions.y))
	_viewport.size = Vector2i(maxi(2, int(dimensions.x * ratio)), maxi(2, int(dimensions.y * ratio)))
	if _auto_frame: frame_model()
	else: _redraw()

func _redraw() -> void:
	if _viewport != null: _viewport.render_target_update_mode = SubViewport.UPDATE_ONCE if _visible_preview() else SubViewport.UPDATE_DISABLED

func _visible_preview() -> bool:
	return is_visible_in_tree() and (_scroll == null or _surface.get_global_rect().intersects(_scroll.get_global_rect()))

func _process(_delta: float) -> void:
	if _viewport == null: return
	var visible_now := _visible_preview()
	if visible_now != _on_screen:
		_on_screen = visible_now
		_redraw()
	if not visible_now: _drag = 0

func _open_expanded() -> void:
	if _asset.is_empty(): return
	if is_instance_valid(_expanded):
		_expanded.grab_focus()
		return
	_expanded = Window.new()
	_expanded.title = "Blender 3D preview"
	_expanded.size = Vector2i(800, 600).min(get_window().size)
	_expanded.transient = true
	add_child(_expanded)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]: margin.add_theme_constant_override(side, Metrics.scaled_int(10))
	_expanded.add_child(margin)
	var viewer = get_script().new()
	margin.add_child(viewer)
	viewer._surface.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewer.configure_asset(_asset.duplicate(), _thumbnail)
	_expanded.close_requested.connect(_expanded.queue_free)
	_expanded.window_input.connect(func(event: InputEvent):
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE: _expanded.queue_free())
	_expanded.popup_centered()

func _exit_tree() -> void:
	if is_instance_valid(_expanded): _expanded.queue_free()
	_views = _views.filter(func(reference): return reference.get_ref() != null and reference.get_ref() != self)
