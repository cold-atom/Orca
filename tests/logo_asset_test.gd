extends SceneTree

const LOGO_PATH := "res://addons/orca/assets/orca.svg"


func _init() -> void:
	var source := FileAccess.get_file_as_string(LOGO_PATH)
	if source.is_empty():
		printerr("logo_asset_test: could not read Orca logo")
		quit(1)
		return
	if source.contains("<rect") or source.contains("fill=\"#ffffff\""):
		printerr("logo_asset_test: logo must not contain an opaque white background")
		quit(1)
		return
	var texture := load(LOGO_PATH) as Texture2D
	if texture == null:
		printerr("logo_asset_test: imported logo texture is unavailable")
		quit(1)
		return
	var image := texture.get_image()
	if image == null or image.is_empty():
		printerr("logo_asset_test: imported logo image is unavailable")
		quit(1)
		return
	for point in [Vector2i(0, 0), Vector2i(image.get_width() - 1, 0), Vector2i(0, image.get_height() - 1), Vector2i(image.get_width() - 1, image.get_height() - 1)]:
		if image.get_pixelv(point).a > 0.05:
			printerr("logo_asset_test: logo corners must remain transparent")
			quit(1)
			return
	print("logo_asset_test: PASS")
	quit(0)
