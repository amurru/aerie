extends Node3D

var left_wing: Node3D
var right_wing: Node3D
var flight_time: float = 0.0
var flight_speed: float = 27.0
var altitude: float = 63.0
var lateral_drift: float = 0.0
var steering := Vector2.ZERO
var paused: bool = false
var energy_boost: float = 0.0


func _ready() -> void:
	_build_dragon()
	position = Vector3(0.0, altitude, 0.0)


func _process(delta: float) -> void:
	if paused:
		return
	flight_time += delta
	energy_boost = maxf(0.0, energy_boost - delta * 0.8)
	var horizontal: float = Input.get_axis("move_left", "move_right")
	var vertical: float = Input.get_axis("move_down", "move_up")
	var climb_input: float = vertical + steering.y
	lateral_drift = move_toward(lateral_drift, horizontal * 30.0 + steering.x * 30.0, 50.0 * delta)
	altitude = clampf(altitude + climb_input * 18.0 * delta, 28.0, 92.0)
	var desired_y: float = altitude + sin(flight_time * 0.72) * 2.2
	position.x += lateral_drift * delta
	position.z -= (flight_speed + energy_boost * 10.0) * delta
	position.y = lerpf(position.y, desired_y, 1.0 - exp(-2.0 * delta))
	rotation.y = lerp_angle(rotation.y, clampf(-lateral_drift * 0.022, -0.55, 0.55), 1.0 - exp(-4.0 * delta))
	rotation.z = lerpf(rotation.z, clampf(lateral_drift * 0.018, -0.45, 0.45), 1.0 - exp(-4.0 * delta))
	rotation.x = lerpf(rotation.x, clampf(-climb_input * 0.12, -0.3, 0.3), 1.0 - exp(-3.0 * delta)) + sin(flight_time * 0.72) * 0.02
	var flap: float = sin(flight_time * 6.2) * 0.58 + 0.08
	left_wing.rotation.z = flap
	right_wing.rotation.z = -flap
	steering = steering.move_toward(Vector2.ZERO, delta * 1.25)


func add_mouse_steer(relative: Vector2) -> void:
	steering.x = clampf(steering.x + relative.x * 0.0018, -1.0, 1.0)
	steering.y = clampf(steering.y - relative.y * 0.0018, -1.0, 1.0)


func add_energy_boost(strength: float) -> void:
	energy_boost = clampf(energy_boost + strength, 0.0, 1.5)


func add_impulse(lateral: float, vertical: float) -> void:
	steering.x = clampf(steering.x + lateral, -1.0, 1.0)
	steering.y = clampf(steering.y + vertical, -1.0, 1.0)


func _build_dragon() -> void:
	var scale_color := Color("3e9b83")
	var shadow_color := Color("286a63")
	var belly_color := Color("d69b55")
	_add_box("Armored_body", Vector3(0.0, 0.0, 0.15), Vector3(1.55, 1.35, 4.9), scale_color)
	_add_box("Chest_plate", Vector3(0.0, -0.48, -0.95), Vector3(1.13, 0.52, 1.65), belly_color)
	_add_box("Shoulders", Vector3(0.0, 0.43, -0.95), Vector3(2.0, 0.62, 1.5), scale_color)
	_add_box("Neck", Vector3(0.0, 0.28, -2.35), Vector3(0.86, 0.83, 2.1), scale_color)
	_add_box("Broad_head", Vector3(0.0, 0.52, -3.35), Vector3(1.52, 1.13, 1.45), scale_color)
	_add_box("Muzzle", Vector3(0.0, 0.22, -4.12), Vector3(1.02, 0.57, 0.83), belly_color)
	_add_box("Jaw", Vector3(0.0, -0.18, -3.95), Vector3(0.95, 0.28, 0.93), shadow_color)
	for side in [-1.0, 1.0]:
		_add_box("Hind_leg", Vector3(side * 0.72, -0.71, 1.05), Vector3(0.53, 0.72, 1.05), shadow_color)
		_add_box("Fore_leg", Vector3(side * 0.83, -0.44, -1.05), Vector3(0.32, 0.72, 0.82), shadow_color)
		_add_box("Golden_eye", Vector3(side * 0.59, 0.64, -3.7), Vector3(0.18, 0.2, 0.22), Color("ffd36e"), true)
		_add_box("Horn", Vector3(side * 0.43, 1.17, -3.0), Vector3(0.24, 0.82, 0.25), Color("d5b783"))
		_add_box("Tail_segment_1", Vector3(side * 0.11, 0.12, 2.78), Vector3(0.8, 0.68, 1.45), shadow_color)
		_add_box("Tail_segment_2", Vector3(side * 0.08, 0.1, 4.0), Vector3(0.47, 0.42, 1.35), scale_color)
	_add_box("Tail_spade", Vector3(0.0, 0.12, 4.92), Vector3(0.95, 0.24, 0.65), Color("d9904f"))
	left_wing = _create_wing(-1.0)
	right_wing = _create_wing(1.0)
	for spike in range(6):
		_add_box("Back_spine", Vector3(0.0, 0.78, 1.0 - float(spike) * 0.72), Vector3(0.25, 0.56, 0.4), Color("e39a4f"))


func _create_wing(side: float) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = "Left_wing" if side < 0.0 else "Right_wing"
	pivot.position = Vector3(side * 0.62, 0.47, -0.75)
	add_child(pivot)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var membrane := StandardMaterial3D.new()
	membrane.albedo_color = Color("d66b56")
	membrane.roughness = 0.86
	membrane.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(membrane)
	var p0 := Vector3.ZERO
	var p1 := Vector3(side * 7.6, 0.12, -0.5)
	var p2 := Vector3(side * 8.7, 0.18, -3.6)
	var p3 := Vector3(side * 5.0, 0.43, -2.65)
	var p4 := Vector3(side * 1.45, 0.28, -5.0)
	var p5 := Vector3(side * 0.55, 0.1, -2.0)
	for tri in [[p0, p1, p2], [p0, p2, p3], [p0, p3, p4], [p0, p4, p5]]:
		for point in tri:
			st.set_color(Color("d66b56") if point.x * side > 1.5 else Color("e49a63"))
			st.add_vertex(point)
	st.generate_normals()
	var surface := MeshInstance3D.new()
	surface.name = "Copper_membrane"
	surface.mesh = st.commit()
	pivot.add_child(surface)
	_add_wing_bone(pivot, Vector3.ZERO, p2, side)
	_add_wing_bone(pivot, Vector3.ZERO, p4, side)
	_add_wing_bone(pivot, p2, p3, side)
	_add_wing_bone(pivot, p3, p4, side)
	return pivot


func _add_wing_bone(parent: Node3D, start: Vector3, finish: Vector3, side: float) -> void:
	var beam := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.14, 0.16, start.distance_to(finish))
	box.material = _material(Color("efbc78"))
	beam.mesh = box
	beam.position = (start + finish) * 0.5
	parent.add_child(beam)
	beam.look_at(beam.global_position + (finish - start).normalized(), Vector3.UP)


func _add_box(node_name: String, at: Vector3, size: Vector3, color: Color, emissive: bool = false) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	var box := BoxMesh.new()
	box.size = size
	var material := _material(color)
	if emissive:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 0.75
	box.material = material
	instance.mesh = box
	instance.position = at
	add_child(instance)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.78
	return material
