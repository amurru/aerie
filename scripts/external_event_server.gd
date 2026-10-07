class_name AerieExternalEventServer
extends Node

const DEFAULT_PORT := 42420
const DEFAULT_HOST := "127.0.0.1"
const FALLBACK_PATH := "/tmp/aerie-events.jsonl"

var event_bus: AerieEventBus
var port: int = DEFAULT_PORT
var server: TCPServer
var _peers: Array[StreamPeerTCP] = []
var _buffers: Dictionary = {}
var _file_offset: int = 0
var _file_partial: String = ""
var _file_timer: float = 0.0


func setup(p_event_bus: AerieEventBus, p_port: int = DEFAULT_PORT) -> void:
	event_bus = p_event_bus
	port = p_port
	server = TCPServer.new()
	var err := server.listen(port, DEFAULT_HOST)
	if err != OK:
		push_warning("Aerie event server: listen on %d failed: %s" % [port, error_string(err)])
	# Skip whatever is already in the fallback file; only tail new bytes.
	_file_offset = _file_size(FALLBACK_PATH)


func _process(_delta: float) -> void:
	_accept_new()
	_drain_peers()
	_file_timer -= _delta
	if _file_timer <= 0.0:
		_file_timer = 0.5
		_poll_fallback_file()


func _accept_new() -> void:
	if server == null or not server.is_listening():
		return
	while server.is_connection_available():
		var peer := server.take_connection()
		if peer != null:
			_peers.append(peer)
			_buffers[peer.get_instance_id()] = ""


func _drain_peers() -> void:
	var dead: Array[StreamPeerTCP] = []
	for peer in _peers:
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			dead.append(peer)
			continue
		var available: int = peer.get_available_bytes()
		if available <= 0:
			continue
		var chunk := peer.get_string(available)
		var key: int = peer.get_instance_id()
		var buf: String = str(_buffers.get(key, "")) + chunk
		var lines := buf.split("\n")
		_buffers[key] = lines[lines.size() - 1]
		for i in range(lines.size() - 1):
			_handle_line(lines[i].strip_edges())
	for peer in dead:
		_buffers.erase(peer.get_instance_id())
		_peers.erase(peer)


func _handle_line(line: String) -> void:
	if line.is_empty():
		return
	var parsed: Variant = JSON.parse_string(line)
	if parsed is Dictionary:
		_handle_event(parsed)
	elif parsed is Array:
		for item in parsed:
			if item is Dictionary:
				_handle_event(item)


func _handle_event(ev: Dictionary) -> void:
	if event_bus == null:
		return
	if ev.has("app") or ev.has("title"):
		event_bus.publish_notification(
			str(ev.get("app", "unknown")),
			str(ev.get("title", "")),
			str(ev.get("body", ""))
		)
		return
	match str(ev.get("type", "")):
		"notification":
			event_bus.publish_notification(
				str(ev.get("app", "unknown")),
				str(ev.get("title", "")),
				str(ev.get("body", ""))
			)
		"beat", "audio_beat":
			event_bus.publish_beat(float(ev.get("strength", 0.7)))
		"level", "audio_level":
			event_bus.publish_level(float(ev.get("value", 0.0)))


func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n


func _poll_fallback_file() -> void:
	if not FileAccess.file_exists(FALLBACK_PATH):
		return
	var f := FileAccess.open(FALLBACK_PATH, FileAccess.READ)
	if f == null:
		return
	var length: int = f.get_length()
	# File was truncated or rotated: restart from the top.
	if length < _file_offset:
		_file_offset = 0
		_file_partial = ""
	if length == _file_offset:
		f.close()
		return
	# Read only the new bytes, not the whole file every poll.
	f.seek(_file_offset)
	var chunk := f.get_buffer(length - _file_offset).get_string_from_utf8()
	f.close()
	_file_offset = length
	var lines := (_file_partial + chunk).split("\n")
	_file_partial = lines[lines.size() - 1]
	for i in range(lines.size() - 1):
		_handle_line(lines[i].strip_edges())
