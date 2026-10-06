class_name AerieInputManager
extends Node

const MOVE_LEFT := "move_left"
const MOVE_RIGHT := "move_right"
const MOVE_UP := "move_up"
const MOVE_DOWN := "move_down"


func setup() -> void:
	_add_key_action(MOVE_LEFT, [KEY_A, KEY_LEFT])
	_add_key_action(MOVE_RIGHT, [KEY_D, KEY_RIGHT])
	_add_key_action(MOVE_UP, [KEY_W, KEY_UP])
	_add_key_action(MOVE_DOWN, [KEY_S, KEY_DOWN])


func _add_key_action(action_name: String, keycodes: Array) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	for keycode in keycodes:
		var exists := false
		for e in InputMap.action_get_events(action_name):
			if e is InputEventKey and e.physical_keycode == keycode:
				exists = true
				break
		if exists:
			continue
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		InputMap.action_add_event(action_name, event)
