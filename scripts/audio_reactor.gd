class_name AerieAudioReactor
extends Node

const BUS_NAME := "Voice"
const CAPTURE_EFFECT_INDEX := 0
const SPECTRUM_EFFECT_INDEX := 1

var event_bus: AerieEventBus
var bus_index: int = -1
var mic_player: AudioStreamPlayer
var spectrum: AudioEffectSpectrumAnalyzerInstance

var enabled: bool = true
var current_level: float = 0.0
var beat_threshold: float = 0.45
var beat_cooldown: float = 0.35
var _cooldown_left: float = 0.0
var _spectrum_ok: bool = false


func setup(p_event_bus: AerieEventBus) -> void:
	event_bus = p_event_bus
	_ensure_bus()
	_ensure_mic()


func _ensure_bus() -> void:
	bus_index = AudioServer.get_bus_index(BUS_NAME)
	if bus_index == -1:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, BUS_NAME)
		AudioServer.set_bus_send(bus_index, "Master")
		var capture := AudioEffectCapture.new()
		capture.buffer_length = 0.25
		AudioServer.add_bus_effect(bus_index, capture, CAPTURE_EFFECT_INDEX)
		var analyzer := AudioEffectSpectrumAnalyzer.new()
		analyzer.buffer_length = 4.0
		analyzer.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
		AudioServer.add_bus_effect(bus_index, analyzer, SPECTRUM_EFFECT_INDEX)
	else:
		_ensure_effects()
	_update_spectrum_handle()


func _ensure_effects() -> void:
	var has_capture := false
	var has_spectrum := false
	for i in range(AudioServer.get_bus_effect_count(bus_index)):
		var fx := AudioServer.get_bus_effect(bus_index, i)
		if fx is AudioEffectCapture:
			has_capture = true
		if fx is AudioEffectSpectrumAnalyzer:
			has_spectrum = true
	if not has_capture:
		var capture := AudioEffectCapture.new()
		capture.buffer_length = 0.25
		AudioServer.add_bus_effect(bus_index, capture)
	if not has_spectrum:
		var analyzer := AudioEffectSpectrumAnalyzer.new()
		AudioServer.add_bus_effect(bus_index, analyzer)
	_update_spectrum_handle()


func _update_spectrum_handle() -> void:
	_spectrum_ok = false
	spectrum = null
	for i in range(AudioServer.get_bus_effect_count(bus_index)):
		var fx := AudioServer.get_bus_effect(bus_index, i)
		if fx is AudioEffectSpectrumAnalyzer:
			var inst := AudioServer.get_bus_effect_instance(bus_index, i, 0)
			if inst is AudioEffectSpectrumAnalyzerInstance:
				spectrum = inst
				_spectrum_ok = true
			break


func _ensure_mic() -> void:
	if mic_player != null:
		return
	mic_player = AudioStreamPlayer.new()
	mic_player.name = "VoiceMic"
	mic_player.stream = AudioStreamMicrophone.new()
	mic_player.bus = BUS_NAME
	add_child(mic_player)
	# play() fails silently when input is disabled or no mic; that is fine.
	mic_player.play()


func use_monitor_source(monitor_name: String) -> bool:
	if monitor_name.is_empty():
		return false
	for dev in AudioServer.get_input_device_list():
		if dev == monitor_name:
			AudioServer.input_device = dev
			_ensure_mic()
			if not mic_player.playing:
				mic_player.play()
			return true
	return false


func list_inputs() -> PackedStringArray:
	return AudioServer.get_input_device_list()


func _process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	if not enabled or bus_index == -1:
		return
	if event_bus == null:
		return
	var level := _read_level()
	current_level = lerpf(current_level, level, 1.0 - exp(-10.0 * delta))
	event_bus.publish_level(current_level)
	if current_level >= beat_threshold and _cooldown_left <= 0.0:
		_cooldown_left = beat_cooldown
		event_bus.publish_beat(current_level)


func _read_level() -> float:
	if _spectrum_ok and spectrum != null:
		var bass := spectrum.get_magnitude_for_frequency_range(60.0, 250.0)
		var voice := spectrum.get_magnitude_for_frequency_range(300.0, 3400.0)
		var energy: float = (bass.x + bass.y) * 0.5 + (voice.x + voice.y) * 0.35
		return clampf(energy * 3.0, 0.0, 1.0)
	# Fallback: raw capture RMS.
	for i in range(AudioServer.get_bus_effect_count(bus_index)):
		var fx := AudioServer.get_bus_effect(bus_index, i)
		if fx is AudioEffectCapture:
			var cap := fx as AudioEffectCapture
			var frames: int = mini(cap.get_frames_available(), 512)
			if frames < 64:
				return 0.0
			var buf := cap.get_buffer(frames)
			if buf.is_empty():
				return 0.0
			var sum := 0.0
			for s in buf:
				sum += s.x * s.x + s.y * s.y
			return clampf(sqrt(sum / float(buf.size() * 2)) * 4.0, 0.0, 1.0)
	return 0.0
