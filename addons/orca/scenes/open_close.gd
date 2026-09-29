@tool
extends "res://addons/orca/scripts/icon_button.gd"


func _ready() -> void:
	super()
	pressed.connect(test)

func _process(_delta):
	pass

func test() -> void:
	#print("Wazzup!")
	pass
