class_name AerieEventBus
extends Node

signal audio_level(value: float)
signal audio_beat(strength: float)
signal thunder_clap(intensity: float)
signal notification_received(app: String, title: String, body: String)

var last_level: float = 0.0
var last_beat_msec: int = 0
var last_notification: Dictionary = {}


func publish_level(value: float) -> void:
	last_level = clampf(value, 0.0, 1.0)
	audio_level.emit(last_level)


func publish_beat(strength: float) -> void:
	var now: int = Time.get_ticks_msec()
	last_beat_msec = now
	audio_beat.emit(clampf(strength, 0.0, 1.0))


func publish_thunder(intensity: float) -> void:
	thunder_clap.emit(clampf(intensity, 0.0, 1.0))


func publish_notification(app: String, title: String, body: String) -> void:
	last_notification = {"app": app, "title": title, "body": body}
	notification_received.emit(app, title, body)
