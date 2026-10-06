class_name AerieSfxManager
extends Node

# Ambience beds plus one-shots for weather and volcanoes. Loops run muted
# until their mix target rises; one-shots round-robin for overlap.

const PATH_AIR := "res://assets/audio/bsb_0904.ogg"
const PATH_WIND := "res://assets/audio/bsb_0146.ogg"
const PATH_RAIN := "res://assets/audio/bsb_0740.ogg"
const PATH_FIRE := "res://assets/audio/bsb_0030.ogg"
const PATH_THUNDER_A := "res://assets/audio/bsb_2718.ogg"
const PATH_THUNDER_B := "res://assets/audio/bsb_3113.ogg"
const PATH_BOOM := "res://assets/audio/bsb_1023.ogg"

var event_bus: AerieEventBus

var _air: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _rain: AudioStreamPlayer
var _fire: AudioStreamPlayer
var _thunder: Array[AudioStreamPlayer] = []
var _thunder_next := 0
var _boom: AudioStreamPlayer

var _wind_db := -26.0
var _rain_db := -60.0
var _fire_db := -60.0


func setup(p_event_bus: AerieEventBus) -> void:
	event_bus = p_event_bus
	_air = _loop(PATH_AIR, -20.0)
	_wind = _loop(PATH_WIND, _wind_db)
	_rain = _loop(PATH_RAIN, _rain_db)
	_fire = _loop(PATH_FIRE, _fire_db)
	_thunder.append(_shot(PATH_THUNDER_A))
	_thunder.append(_shot(PATH_THUNDER_B))
	_boom = _shot(PATH_BOOM)
	if event_bus != null and not event_bus.thunder_clap.is_connected(_on_thunder):
		event_bus.thunder_clap.connect(_on_thunder)


func set_ambience(weather: String, volcano: float) -> void:
	match weather:
		"Cloudy":
			_wind_db = -18.0
			_rain_db = -60.0
		"Fog":
			_wind_db = -22.0
			_rain_db = -60.0
		"Storm":
			_wind_db = -10.0
			_rain_db = -12.0
		_:
			_wind_db = -26.0
			_rain_db = -60.0
	_fire_db = -60.0 + clampf(volcano, 0.0, 1.0) * 48.0


func eruption_boom() -> void:
	_boom.pitch_scale = randf_range(0.85, 1.0)
	_boom.volume_db = -6.0
	_boom.play()


func _process(delta: float) -> void:
	var k: float = 1.0 - exp(-delta * 2.0)
	_wind.volume_db = lerpf(_wind.volume_db, _wind_db, k)
	_rain.volume_db = lerpf(_rain.volume_db, _rain_db, k)
	_fire.volume_db = lerpf(_fire.volume_db, _fire_db, k)


func _on_thunder(_intensity: float) -> void:
	var player: AudioStreamPlayer = _thunder[_thunder_next]
	_thunder_next = (_thunder_next + 1) % _thunder.size()
	player.pitch_scale = randf_range(0.9, 1.1)
	player.volume_db = -8.0
	player.play()


func _loop(path: String, start_db: float) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	var stream := load(path) as AudioStreamOggVorbis
	stream.loop = true
	player.stream = stream
	player.volume_db = start_db
	add_child(player)
	player.play()
	return player


func _shot(path: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.stream = load(path) as AudioStream
	add_child(player)
	return player
