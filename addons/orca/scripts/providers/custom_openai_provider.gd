@tool
extends "res://addons/orca/scripts/providers/provider_base.gd"


func definition() -> Dictionary:
	return {
		"id": "custom",
		"name": "OpenAI-compatible",
		"base_url": "http://localhost:1234/v1",
		"key_label": "API Key",
		"key_url": "",
		"default_model": "",
		"description": "Custom or local compatible endpoint",
		"custom_url": true
	}
