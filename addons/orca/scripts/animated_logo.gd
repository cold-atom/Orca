@tool
extends TextureRect

# Godot rasterizes CSS-animated SVGs, so this sheet is baked from the brand SVG.
const SPRITE_SHEET := preload("res://addons/orca/assets/orca-animated-sheet.png")
const FRAME_SIZE := Vector2i(194, 144)
const FRAME_COLUMNS := 10
const FRAME_COUNT := 140
const FRAMES_PER_SECOND := 10.0

var _atlas := AtlasTexture.new()
var _elapsed := 0.0
var _frame := -1


func _ready() -> void:
	_atlas.atlas = SPRITE_SHEET
	texture = _atlas
	_set_frame(0)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_elapsed = fmod(_elapsed + delta, FRAME_COUNT / FRAMES_PER_SECOND)
	_set_frame(int(_elapsed * FRAMES_PER_SECOND))


func _set_frame(frame: int) -> void:
	if frame == _frame:
		return
	_frame = frame
	_atlas.region = Rect2i(
		(frame % FRAME_COLUMNS) * FRAME_SIZE.x,
		(frame / FRAME_COLUMNS) * FRAME_SIZE.y,
		FRAME_SIZE.x,
		FRAME_SIZE.y
	)
