@tool
extends RefCounted


static func editor_scale() -> float:
	if Engine.is_editor_hint():
		return maxf(EditorInterface.get_editor_scale(), 0.5)
	return 1.0


static func scaled(value: float, scale_override := -1.0) -> float:
	var scale := editor_scale() if scale_override <= 0.0 else scale_override
	return roundf(value * scale)


static func scaled_vector(value: Vector2, scale_override := -1.0) -> Vector2:
	return Vector2(scaled(value.x, scale_override), scaled(value.y, scale_override))


static func scaled_int(value: float, scale_override := -1.0) -> int:
	return maxi(1, int(scaled(value, scale_override)))
