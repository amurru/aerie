class_name AerieFxManager
extends Node3D

const MAX_NODES := 48
const BOLT_TTL := 1.4
const FLOATER_TTL := 3.0

var event_bus: AerieEventBus
var dragon: Node3D
var world: Node3D
var sun: DirectionalLight3D
var base_sun_energy: float = 0.85

var _flash: float = 0.0
var _entries: Array[Dictionary] = []


func setup(p_event_bus: AerieEventBus, p_dragon: Node3D, p_world: Node3D, p_sun: DirectionalLight3D) -> void:
	if event_bus != null and event_bus.notification_received.is_connected(_on_notification):
		event_bus.notification_received.disconnect(_on_notification)
	if event_bus != null and event_bus.audio_beat.is_connected(_on_beat):
		event_bus.audio_beat.disconnect(_on_beat)
	event_bus = p_event_bus
	dragon = p_dragon
	world = p_world
	sun = p_sun
	if sun != null:
		base_sun_energy = sun.light_energy
	if event_bus != null:
		if not event_bus.notification_received.is_connected(_on_notification):
			event_bus.notification_received.connect(_on_notification)
		if not event_bus.audio_beat.is_connected(_on_beat):
			event_bus.audio_beat.connect(_on_beat)


func _process(delta: float) -> void:
	if sun != null:
		_flash = maxf(0.0, _flash - delta * 1.8)
		sun.light_energy = base_sun_energy + _flash * 2.2
	var i := _entries.size() - 1
	while i >= 0:
		var e: Dictionary = _entries[i]
		e["age"] = float(e["age"]) + delta
		var age: float = e["age"]
		var ttl: float = e["ttl"]
		var node := e["node"] as Node3D
		if age >= ttl or not is_instance_valid(node):
			if is_instance_valid(node):
				node.queue_free()
			_entries.remove_at(i)
		else:
			var kind := str(e["kind"])
			if kind == "floater":
				node.position.y += float(e["rise"]) * delta
				var s: float = maxf(0.05, 1.0 - age / ttl)
				node.scale = Vector3.ONE * s * float(e["size"])
			elif kind == "bolt":
				var f: float = 1.0 - age / ttl
				node.scale = Vector3(1.0, maxf(0.1, f), 1.0)
		i -= 1


func _on_notification(app: String, _title: String, _body: String) -> void:
	var center := _focus_point()
	match app.to_lower():
		"discord", "vesktop", "telegramdesktop", "telegram":
			lightning_at(center + Vector3(randf_range(-18.0, 18.0), 0.0, randf_range(-30.0, -10.0)), Color("7fb4ff"))
		"spotify", "music":
			spawn_floaters(10, center, Color("7fe0a8"))
		_:
			lightning_at(center + Vector3(0.0, 0.0, -22.0), Color("ffe08a"))


func _on_beat(strength: float) -> void:
	var center := _focus_point()
	spawn_floaters(int(2.0 + strength * 6.0), center, Color("ffd36e"))
	if dragon != null and dragon.has_method("add_energy_boost"):
		dragon.call("add_energy_boost", strength * 0.6)


func _focus_point() -> Vector3:
	if dragon != null and is_instance_valid(dragon):
		return dragon.global_position
	return global_position


func lightning_at(world_pos: Vector3, tint: Color) -> void:
	_prune_if_needed(2)
	_flash = minf(1.0, _flash + 0.85)
	if event_bus != null:
		event_bus.publish_thunder(1.0)
	var root := Node3D.new()
	root.name = "LightningBolt"
	root.position = world_pos
	add_child(root)
	# Jagged vertical bolt from emissive boxes.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 3.0
	var x := 0.0
	for seg in range(5):
		var block := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.7, 7.0, 0.7)
		box.material = mat
		block.mesh = box
		x += randf_range(-2.2, 2.2)
		block.position = Vector3(x, -float(seg) * 6.0, randf_range(-1.0, 1.0))
		block.rotation.z = randf_range(-0.25, 0.25)
		root.add_child(block)
	var flash_light := OmniLight3D.new()
	flash_light.light_color = tint
	flash_light.light_energy = 4.0
	flash_light.omni_range = 90.0
	root.add_child(flash_light)
	_entries.append({"node": root, "age": 0.0, "ttl": BOLT_TTL, "kind": "bolt"})


func spawn_floaters(count: int, center: Vector3, tint: Color) -> void:
	_prune_if_needed(count)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 1.2
	for i in range(count):
		var mote := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.45
		mesh.height = 0.9
		mesh.material = mat
		mote.mesh = mesh
		var offset := Vector3(randf_range(-16.0, 16.0), randf_range(-2.0, 5.0), randf_range(-18.0, 6.0))
		mote.position = center + offset
		var size := randf_range(0.6, 1.6)
		mote.scale = Vector3.ONE * size
		add_child(mote)
		_entries.append({
			"node": mote, "age": 0.0, "ttl": FLOATER_TTL * randf_range(0.7, 1.2),
			"kind": "floater", "rise": randf_range(1.5, 4.5), "size": size,
		})


func _prune_if_needed(incoming: int) -> void:
	while _entries.size() + incoming > MAX_NODES and not _entries.is_empty():
		var oldest: Dictionary = _entries.pop_front()
		var node := oldest.get("node") as Node
		if is_instance_valid(node):
			node.queue_free()
