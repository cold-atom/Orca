extends RefCounted

## Returns a value while exercising a multiline signature.
@warning_ignore(
	"unused_parameter"
)
static func documented(
	value: String = "func fake_in_string():",
	callback: Callable = func(): return "# not a comment"
) -> String:
	var triple := """A fake declaration:
func fake_in_triple():
	pass
"""
	# func fake_in_comment():
	return value + triple


class First:
	func duplicate() -> String:
		return "first"


class Second:
	class Nested:
		func duplicate() -> String:
			return 'second'


func after_classes() -> void:
	pass
