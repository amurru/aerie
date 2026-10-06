extends Node3D

const CHUNK_LENGTH: float = 180.0
const WORLD_WIDTH: float = 520.0
const GRID_X: int = 44
const GRID_Z: int = 28
const ROW_RADIUS: int = 4
const COL_RADIUS: int = 2
const EDGE_BLEND: float = 0.13
const BIOMES: Array[String] = ["Steppe", "Mountains", "Glacier", "Volcano", "Forest", "Desert", "Lake country", "Highlands"]

var world_seed: int = 82731
var chunks: Dictionary = {}
var broad_noise: FastNoiseLite
var detail_noise: FastNoiseLite
var ridge_noise: FastNoiseLite
var _biome_cache: Dictionary = {}
var _volcanoes: Array[Dictionary] = []
var _volc_time: float = 0.0

var _sea_pool: Array[Node3D] = []
var _sea_bubbles: CPUParticles3D
var _sea_center := Vector3(0.0, 0.0, 0.0)
var _sea_built := false


func _process(_delta: float) -> void:
	# Magma glow flicker for active volcanoes; eruption state machine.
	if _volcanoes.is_empty():
		return
	_volc_time += _delta
	for v in _volcanoes:
		var glow: OmniLight3D = v.get("glow")
		if not is_instance_valid(glow):
			continue
		var p: float = v.get("phase", 0.0)
		var flicker: float = sin(_volc_time * 7.0 + p) * 0.5 + sin(_volc_time * 13.0 + p * 2.0) * 0.3
		var erupting: float = float(v.get("erupting", 0.0))
		if erupting > 0.0:
			erupting = maxf(0.0, erupting - _delta)
			v["erupting"] = erupting
		var cooldown: float = float(v.get("cooldown", 0.0))
		if cooldown > 0.0:
			v["cooldown"] = maxf(0.0, cooldown - _delta)
		var active: bool = bool(v.get("active", false))
		if erupting > 0.0:
			glow.light_energy = 5.5 + flicker
		elif active:
			glow.light_energy = 2.6 + flicker
		else:
			glow.light_energy = 0.0
		var fountain: CPUParticles3D = v.get("fountain")
		if is_instance_valid(fountain):
			fountain.emitting = erupting > 0.0
		for flow in v.get("flows", []):
			if is_instance_valid(flow):
				(flow as Node3D).visible = erupting > 0.0


func nearest_volcano(dragon_pos: Vector3, max_dist: float) -> int:
	var best := -1
	var best_d := max_dist
	for i in range(_volcanoes.size()):
		var anchor: Vector3 = _volcanoes[i].get("anchor", Vector3.ZERO)
		var d: float = dragon_pos.distance_to(anchor)
		if d < best_d:
			best_d = d
			best = i
	return best


func volcano_proximity(dragon_pos: Vector3) -> float:
	var closest := 1e20
	for v in _volcanoes:
		var glow: Object = v.get("glow")
		if glow == null or not is_instance_valid(glow):
			continue
		var anchor: Vector3 = v.get("anchor", Vector3.ZERO)
		closest = minf(closest, dragon_pos.distance_to(anchor))
	if closest >= 1e19:
		return 0.0
	return clampf(1.0 - closest / 220.0, 0.0, 1.0)


func try_erupt(index: int, duration: float) -> bool:
	if index < 0 or index >= _volcanoes.size():
		return false
	var v: Dictionary = _volcanoes[index]
	if not is_instance_valid(v.get("glow")):
		return false
	if float(v.get("erupting", 0.0)) > 0.0 or float(v.get("cooldown", 0.0)) > 0.0:
		return false
	v["erupting"] = duration
	v["cooldown"] = duration + 30.0
	return true


func _ready() -> void:
	randomize()
	world_seed = randi_range(1, 2000000000)
	_configure_noise()
	update_follow(Vector3.ZERO)


func _configure_noise() -> void:
	broad_noise = FastNoiseLite.new()
	broad_noise.seed = world_seed + 11
	broad_noise.frequency = 0.0025
	broad_noise.fractal_octaves = 3
	broad_noise.fractal_gain = 0.48
	broad_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

	detail_noise = FastNoiseLite.new()
	detail_noise.seed = world_seed + 29
	detail_noise.frequency = 0.012
	detail_noise.fractal_octaves = 2
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX

	ridge_noise = FastNoiseLite.new()
	ridge_noise.seed = world_seed + 47
	ridge_noise.frequency = 0.0042
	ridge_noise.fractal_octaves = 2
	ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX


func update_follow(dragon_pos: Vector3) -> void:
	# Open world: symmetric radius in every direction so U-turns and free
	# flight always have terrain.
	var center := _cell_at(dragon_pos.x, dragon_pos.z)
	for row in range(center.y - ROW_RADIUS, center.y + ROW_RADIUS + 1):
		for col in range(center.x - COL_RADIUS, center.x + COL_RADIUS + 1):
			var key := Vector2i(col, row)
			if not chunks.has(key):
				_spawn_chunk(row, col)
	for key in chunks.keys():
		if absi(key.y - center.y) > ROW_RADIUS or absi(key.x - center.x) > COL_RADIUS:
			var old_chunk: Node3D = chunks[key]
			chunks.erase(key)
			old_chunk.queue_free()
	# Drop volcano records whose chunk was recycled.
	for i in range(_volcanoes.size() - 1, -1, -1):
		if not is_instance_valid(_volcanoes[i].get("glow")):
			_volcanoes.remove_at(i)


func regenerate_at(dragon_pos: Vector3) -> void:
	for old_chunk in chunks.values():
		old_chunk.queue_free()
	chunks.clear()
	_biome_cache.clear()
	_volcanoes.clear()
	world_seed = randi_range(1, 2000000000)
	_configure_noise()
	update_follow(dragon_pos)


func biome_name_at(dragon_pos: Vector3) -> String:
	return BIOMES[_biome_index(_cell_at(dragon_pos.x, dragon_pos.z))]


func get_ground_height(x: float, world_z: float) -> float:
	return _height_open(x, world_z)


const WATER_LEVEL := 16.0


func water_at(x_abs: float, world_z: float) -> bool:
	match BIOMES[_biome_index(_cell_at(x_abs, world_z))]:
		"Lake country", "Steppe", "Forest":
			return true
	return false


func is_submerged(dragon_pos: Vector3) -> bool:
	return dragon_pos.y < WATER_LEVEL - 0.4 and water_at(dragon_pos.x, dragon_pos.z)


func ensure_underwater(center: Vector3) -> void:
	# Detail only exists while approached: a small recycled pool of weed and
	# rock plus a bubble emitter, parked near the dragon while submerged.
	if not _sea_built:
		_build_sea_pool()
	var active: bool = is_submerged(center)
	if active and _sea_center.distance_to(center) > 15.0:
		_sea_center = center
		_scatter_sea_pool()
	for node in _sea_pool:
		if node.get_meta("skip", false):
			node.visible = false
		else:
			node.visible = active
	if _sea_bubbles != null:
		_sea_bubbles.emitting = active
		if active:
			_sea_bubbles.global_position = center + Vector3(0.0, 1.0, -2.0)


func _build_sea_pool() -> void:
	_sea_built = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var weed_mat := _solid_material(Color("2e7a3d"))
	var rock_mat := _solid_material(Color("5a6068"))
	for i in range(20):
		var tuft := MeshInstance3D.new()
		tuft.name = "Seaweed"
		var blade := CylinderMesh.new()
		blade.top_radius = 0.12
		blade.bottom_radius = 0.35
		blade.height = rng.randf_range(2.5, 5.0)
		blade.radial_segments = 5
		blade.material = weed_mat
		tuft.mesh = blade
		tuft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(tuft)
		tuft.visible = false
		_sea_pool.append(tuft)
	for i in range(10):
		var rock := MeshInstance3D.new()
		rock.name = "UnderwaterRock"
		var stone := SphereMesh.new()
		stone.radius = rng.randf_range(0.6, 1.6)
		stone.height = stone.radius * 1.4
		stone.material = rock_mat
		rock.mesh = stone
		rock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(rock)
		rock.visible = false
		_sea_pool.append(rock)
	_sea_bubbles = CPUParticles3D.new()
	_sea_bubbles.name = "DiveBubbles"
	_sea_bubbles.amount = 40
	_sea_bubbles.lifetime = 2.0
	_sea_bubbles.local_coords = false
	_sea_bubbles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_sea_bubbles.emission_sphere_radius = 1.5
	_sea_bubbles.direction = Vector3(0.0, 1.0, 0.0)
	_sea_bubbles.spread = 12.0
	_sea_bubbles.initial_velocity_min = 2.0
	_sea_bubbles.initial_velocity_max = 4.5
	_sea_bubbles.gravity = Vector3(0.0, 1.5, 0.0)
	var bead := SphereMesh.new()
	bead.radius = 0.12
	bead.height = 0.24
	var bead_mat := StandardMaterial3D.new()
	bead_mat.albedo_color = Color("cfe8f2")
	bead_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bead.material = bead_mat
	_sea_bubbles.mesh = bead
	_sea_bubbles.emitting = false
	add_child(_sea_bubbles)


func _scatter_sea_pool() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = absi(int(_sea_center.x) * 13 + int(_sea_center.z) * 7) + 99
	for node in _sea_pool:
		var ox: float = rng.randf_range(-45.0, 45.0)
		var oz: float = rng.randf_range(-45.0, 45.0)
		var gx: float = _sea_center.x + ox
		var gz: float = _sea_center.z + oz
		var ground: float = _height_open(gx, gz)
		if ground > WATER_LEVEL - 0.5:
			node.visible = false
			node.set_meta("skip", true)
			continue
		node.set_meta("skip", false)
		node.position = Vector3(gx, ground + 1.2, gz)
		node.rotation.y = rng.randf_range(0.0, TAU)


func _cell_at(x_abs: float, world_z: float) -> Vector2i:
	var col: int = int(floor((x_abs + WORLD_WIDTH * 0.5) / WORLD_WIDTH))
	var row: int = int(floor(-world_z / CHUNK_LENGTH))
	return Vector2i(col, row)


func _raw_biome(cell: Vector2i) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = absi(world_seed + cell.x * 73856093 + cell.y * 19349663) + 7
	return rng.randi_range(0, BIOMES.size() - 1)


func _biome_index(cell: Vector2i) -> int:
	if _biome_cache.has(cell):
		return _biome_cache[cell]
	var result: int = _raw_biome(cell)
	# Deterministic de-dup against fixed neighbors (order-independent).
	var left: int = _raw_biome(cell + Vector2i(-1, 0))
	var back: int = _raw_biome(cell + Vector2i(0, -1))
	if result == left or result == back:
		result = (result + 1) % BIOMES.size()
		if result == left or result == back:
			result = (result + 1) % BIOMES.size()
	_biome_cache[cell] = result
	return result


func _spawn_chunk(row: int, col: int) -> void:
	var cell := Vector2i(col, row)
	var chunk := Node3D.new()
	chunk.name = "Biome_r%02d_c%02d_%s" % [row, col, BIOMES[_biome_index(cell)].replace(" ", "_")]
	chunk.position = Vector3(float(col) * WORLD_WIDTH, 0.0, -float(row) * CHUNK_LENGTH)
	add_child(chunk)
	chunks[Vector2i(col, row)] = chunk
	var biome_index: int = _biome_index(cell)
	var biome: String = BIOMES[biome_index]
	_add_terrain(chunk, row, col, biome_index)
	if biome == "Forest":
		_add_forest(chunk, row, col)
	elif biome == "Desert":
		_add_cacti(chunk, row, col)
	elif biome == "Glacier":
		_add_ice_spires(chunk, row, col)
	elif biome == "Volcano":
		_add_volcano(chunk, row, col)
	if biome == "Lake country" or biome == "Steppe" or biome == "Forest":
		_add_water(chunk, biome)


func _height_for_biome(x: float, world_z: float, biome_index: int) -> float:
	var broad: float = broad_noise.get_noise_2d(x, world_z)
	var detail: float = detail_noise.get_noise_2d(x, world_z)
	var ridge: float = 1.0 - abs(ridge_noise.get_noise_2d(x, world_z))
	match BIOMES[biome_index]:
		"Mountains":
			return 22.0 + pow(ridge, 1.45) * 36.0 + broad * 7.0 + detail * 4.0
		"Glacier":
			return 28.0 + pow(ridge, 1.7) * 30.0 + broad * 7.0 + detail * 2.0
		"Volcano":
			return 20.0 + broad * 11.0 + detail * 6.0 + ridge * 9.0
		"Forest":
			return 21.0 + broad * 14.0 + detail * 3.0 - _basin(broad, -0.25, 10.0)
		"Desert":
			return 15.0 + abs(broad) * 8.5 + detail * 3.0 + sin(world_z * 0.024 + x * 0.012) * 3.5
		"Lake country":
			return 17.0 + broad * 5.0 + detail * 1.3 - _basin(broad, -0.1, 14.0)
		"Highlands":
			return 24.0 + abs(broad) * 18.0 + ridge * 8.0 + detail * 4.0
		_:
			return 19.0 + broad * 8.0 + detail * 2.5 + sin(x * 0.018) * 2.0 - _basin(broad, -0.2, 8.0)


func _basin(broad: float, edge: float, depth: float) -> float:
	# Carved lake basins where the broad noise dips: full depth below
	# (edge - 0.6), fading to none at edge.
	return (1.0 - smoothstep(edge - 0.6, edge, broad)) * depth


func _height_open(x_abs: float, world_z: float) -> float:
	# Open-world height: cell biome blended toward edge neighbors on both
	# axes. Midpoint (0.5/0.5) exactly on shared edges, so neighbor chunks
	# compute identical values and seams match.
	var cell := _cell_at(x_abs, world_z)
	var h: float = _height_for_biome(x_abs, world_z, _biome_index(cell))
	var origin_x: float = float(cell.x) * WORLD_WIDTH - WORLD_WIDTH * 0.5
	var u: float = (x_abs - origin_x) / WORLD_WIDTH
	if u < EDGE_BLEND:
		var n := Vector2i(cell.x - 1, cell.y)
		var w: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, u))
		h = lerpf(_height_for_biome(x_abs, world_z, _biome_index(n)), h, 1.0 - w)
	elif u > 1.0 - EDGE_BLEND:
		var n2 := Vector2i(cell.x + 1, cell.y)
		var w2: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, 1.0 - u))
		h = lerpf(_height_for_biome(x_abs, world_z, _biome_index(n2)), h, 1.0 - w2)
	var origin_z: float = -float(cell.y + 1) * CHUNK_LENGTH
	var t: float = (world_z - origin_z) / CHUNK_LENGTH
	if t < EDGE_BLEND:
		var n3 := Vector2i(cell.x, cell.y + 1)
		var w3: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, t))
		h = lerpf(_height_for_biome(x_abs, world_z, _biome_index(n3)), h, 1.0 - w3)
	elif t > 1.0 - EDGE_BLEND:
		var n4 := Vector2i(cell.x, cell.y - 1)
		var w4: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, 1.0 - t))
		h = lerpf(_height_for_biome(x_abs, world_z, _biome_index(n4)), h, 1.0 - w4)
	return snappedf(h, 1.0)


func _color_open(x_abs: float, world_z: float, height: float, detail: float) -> Color:
	# Same edge weights as _height_open, applied to colors so tint borders
	# stay continuous too.
	var cell := _cell_at(x_abs, world_z)
	var c: Color = _ground_color(_biome_index(cell), height, detail)
	var origin_x: float = float(cell.x) * WORLD_WIDTH - WORLD_WIDTH * 0.5
	var u: float = (x_abs - origin_x) / WORLD_WIDTH
	if u < EDGE_BLEND:
		var n := Vector2i(cell.x - 1, cell.y)
		var w: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, u))
		c = _ground_color(_biome_index(n), height, detail).lerp(c, 1.0 - w)
	elif u > 1.0 - EDGE_BLEND:
		var n2 := Vector2i(cell.x + 1, cell.y)
		var w2: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, 1.0 - u))
		c = _ground_color(_biome_index(n2), height, detail).lerp(c, 1.0 - w2)
	var origin_z: float = -float(cell.y + 1) * CHUNK_LENGTH
	var t: float = (world_z - origin_z) / CHUNK_LENGTH
	if t < EDGE_BLEND:
		var n3 := Vector2i(cell.x, cell.y + 1)
		var w3: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, t))
		c = _ground_color(_biome_index(n3), height, detail).lerp(c, 1.0 - w3)
	elif t > 1.0 - EDGE_BLEND:
		var n4 := Vector2i(cell.x, cell.y - 1)
		var w4: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, 1.0 - t))
		c = _ground_color(_biome_index(n4), height, detail).lerp(c, 1.0 - w4)
	return c


func _ground_color(biome_index: int, height: float, detail: float) -> Color:
	var low: Color
	var high: Color
	var snow_line: float = 1000.0
	match BIOMES[biome_index]:
		"Mountains":
			low = Color("4f8a35")
			snow_line = 50.0
			high = Color("f4f6f3") if height > snow_line else Color("7d9078")
		"Glacier":
			low = Color("bcdcec")
			high = Color("ffffff") if height > 40.0 else Color("aed6e8")
		"Volcano":
			low = Color("4a3428")
			high = Color("8a5f3d")
		"Forest":
			low = Color("1f6b2e")
			high = Color("46b34a")
		"Desert":
			low = Color("c98f3d")
			high = Color("e8b04b")
		"Lake country":
			low = Color("2f8a3d")
			high = Color("6fbf5a")
		"Highlands":
			low = Color("4f8a2f")
			high = Color("e8ece6") if height > 52.0 else Color("84ac54")
		_:
			# Steppe: vivid green meadow.
			low = Color("46a02e")
			high = Color("8fd14f")
	var blend: float = clampf((height - 28.0) / 60.0, 0.0, 0.85)
	var color: Color = low.lerp(high, blend)
	return color * (1.0 + detail * 0.045)


func _add_terrain(parent: Node3D, row: int, col: int, biome_index: int) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	# Ice reflects more sun; rock/grass stays matte but not fully flat.
	if BIOMES[biome_index] == "Glacier":
		material.roughness = 0.38
		material.metallic = 0.05
	else:
		material.roughness = 0.85
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	surface.set_material(material)
	var width: float = WORLD_WIDTH
	for iz in range(GRID_Z):
		for ix in range(GRID_X):
			var x0: float = -width * 0.5 + width * float(ix) / GRID_X
			var x1: float = -width * 0.5 + width * float(ix + 1) / GRID_X
			var z0: float = -CHUNK_LENGTH * float(iz) / GRID_Z
			var z1: float = -CHUNK_LENGTH * float(iz + 1) / GRID_Z
			var base_z: float = -float(row) * CHUNK_LENGTH
			var base_x: float = float(col) * WORLD_WIDTH
			var p00 := Vector3(x0, _height_open(base_x + x0, base_z + z0), z0)
			var p10 := Vector3(x1, _height_open(base_x + x1, base_z + z0), z0)
			var p11 := Vector3(x1, _height_open(base_x + x1, base_z + z1), z1)
			var p01 := Vector3(x0, _height_open(base_x + x0, base_z + z1), z1)
			_add_colored_triangle(surface, p00, p10, p11, row, col)
			_add_colored_triangle(surface, p00, p11, p01, row, col)
	surface.generate_normals()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Faceted_terrain"
	mesh_instance.mesh = surface.commit()
	parent.add_child(mesh_instance)


func _add_colored_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, row: int, col: int) -> void:
	var base_x: float = float(col) * WORLD_WIDTH
	var base_z: float = -float(row) * CHUNK_LENGTH
	for point in [a, b, c]:
		var x_abs: float = base_x + point.x
		var world_z: float = base_z + point.z
		var detail: float = detail_noise.get_noise_2d(x_abs, world_z)
		surface.set_color(_color_open(x_abs, world_z, point.y, detail))
		surface.add_vertex(point)


func _add_water(parent: Node3D, biome: String) -> void:
	var water := MeshInstance3D.new()
	water.name = "Still_water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(WORLD_WIDTH - 10.0, CHUNK_LENGTH)
	water.mesh = plane
	water.position = Vector3(0.0, 16.0, -CHUNK_LENGTH * 0.5)
	var water_material := StandardMaterial3D.new()
	# Opaque: transparency blended the pale terrain underneath into cyan.
	water_material.albedo_color = Color("1470d4") if biome == "Lake country" else Color("1c74c4")
	water_material.roughness = 0.3
	water_material.metallic = 0.0
	water.material_override = water_material
	parent.add_child(water)


func _new_multimesh(mesh: Mesh, transforms: Array[Transform3D], parent: Node3D, node_name: String) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in range(transforms.size()):
		multimesh.set_instance_transform(i, transforms[i])
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	parent.add_child(instance)


func _add_forest(parent: Node3D, row: int, col: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = abs(world_seed + row * 8191 + col * 131) + 2
	var trunks: Array[Transform3D] = []
	var crowns: Array[Transform3D] = []
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.33
	trunk_mesh.bottom_radius = 0.48
	trunk_mesh.height = 3.8
	trunk_mesh.radial_segments = 5
	trunk_mesh.material = _solid_material(Color("584332"))
	var crown_mesh := CylinderMesh.new()
	crown_mesh.top_radius = 0.0
	crown_mesh.bottom_radius = 2.35
	crown_mesh.height = 5.3
	crown_mesh.radial_segments = 5
	crown_mesh.material = _solid_material(Color("2f7a3d"))
	for tree in range(50):
		var x: float = rng.randf_range(-WORLD_WIDTH * 0.5 + 12.0, WORLD_WIDTH * 0.5 - 12.0)
		if absf(x) < 16.0:
			x += signf(x) * 20.0 if absf(x) > 0.1 else 25.0
		var z: float = -rng.randf_range(8.0, CHUNK_LENGTH - 8.0)
		var ground: float = _height_open(float(col) * WORLD_WIDTH + x, -float(row) * CHUNK_LENGTH + z)
		var scale: float = rng.randf_range(0.72, 1.32)
		var base := Vector3(x, ground, z)
		trunks.append(Transform3D(Basis().scaled(Vector3(scale, scale, scale)), base + Vector3(0.0, 1.9 * scale, 0.0)))
		for tier in range(3):
			var tier_scale: float = scale * (1.0 - float(tier) * 0.19)
			crowns.append(Transform3D(Basis().scaled(Vector3(tier_scale, tier_scale, tier_scale)), base + Vector3(0.0, (3.2 + float(tier) * 1.65) * scale, 0.0)))
	_new_multimesh(trunk_mesh, trunks, parent, "Pine_trunks")
	_new_multimesh(crown_mesh, crowns, parent, "Faceted_pine_canopies")


func _add_cacti(parent: Node3D, row: int, col: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = abs(world_seed + row * 6151 + col * 137) + 3
	var cactus_mesh := CylinderMesh.new()
	cactus_mesh.top_radius = 0.35
	cactus_mesh.bottom_radius = 0.52
	cactus_mesh.height = 3.1
	cactus_mesh.radial_segments = 5
	cactus_mesh.material = _solid_material(Color("4a8f3f"))
	var transforms: Array[Transform3D] = []
	for plant in range(18):
		var x: float = rng.randf_range(-WORLD_WIDTH * 0.5 + 12.0, WORLD_WIDTH * 0.5 - 12.0)
		if absf(x) < 18.0:
			x += 27.0 if x >= 0.0 else -27.0
		var z: float = -rng.randf_range(10.0, CHUNK_LENGTH - 10.0)
		var ground: float = _height_open(float(col) * WORLD_WIDTH + x, -float(row) * CHUNK_LENGTH + z)
		var s: float = rng.randf_range(0.75, 1.35)
		transforms.append(Transform3D(Basis().scaled(Vector3(s, s, s)), Vector3(x, ground + 1.55 * s, z)))
	_new_multimesh(cactus_mesh, transforms, parent, "Desert_succulents")


func _add_ice_spires(parent: Node3D, row: int, col: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = abs(world_seed + row * 3323 + col * 139) + 4
	var ice_mesh := CylinderMesh.new()
	ice_mesh.top_radius = 0.0
	ice_mesh.bottom_radius = 1.25
	ice_mesh.height = 8.0
	ice_mesh.radial_segments = 5
	ice_mesh.material = _solid_material(Color("e8f7fa"))
	var transforms: Array[Transform3D] = []
	for shard in range(16):
		var x: float = rng.randf_range(-WORLD_WIDTH * 0.5 + 15.0, WORLD_WIDTH * 0.5 - 15.0)
		if absf(x) < 22.0:
			x += 30.0 if x >= 0.0 else -30.0
		var z: float = -rng.randf_range(12.0, CHUNK_LENGTH - 12.0)
		var ground: float = _height_open(float(col) * WORLD_WIDTH + x, -float(row) * CHUNK_LENGTH + z)
		var scale: float = rng.randf_range(0.65, 1.65)
		transforms.append(Transform3D(Basis().rotated(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3(scale, scale, scale)), Vector3(x, ground + 3.8 * scale, z)))
	_new_multimesh(ice_mesh, transforms, parent, "Ice_spires")


func _add_volcano(parent: Node3D, row: int, col: int) -> void:
	var x: float = -52.0 if (row % 2 == 0) else 55.0
	var local_z: float = -CHUNK_LENGTH * 0.55
	var world_z: float = -float(row) * CHUNK_LENGTH + local_z
	var ground: float = _height_open(float(col) * WORLD_WIDTH + x, world_z)
	# Not every volcano erupts: deterministic active/dormant split per cell.
	var active: bool = absi(row * 31 + col * 17 + world_seed) % 10 < 6
	var cone := MeshInstance3D.new()
	cone.name = "Seven_sided_volcanic_cone"
	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 5.5
	cone_mesh.bottom_radius = 39.0
	cone_mesh.height = 54.0
	cone_mesh.radial_segments = 7
	cone_mesh.rings = 1
	cone_mesh.material = _solid_material(Color("3a2f28") if active else Color("554a3f"))
	cone.mesh = cone_mesh
	cone.position = Vector3(x, ground + 25.0, local_z)
	parent.add_child(cone)
	var crater := MeshInstance3D.new()
	crater.name = "Lava_crater" if active else "Cold_crater"
	var crater_mesh := CylinderMesh.new()
	crater_mesh.top_radius = 8.0
	crater_mesh.bottom_radius = 8.0
	crater_mesh.height = 0.55
	crater_mesh.radial_segments = 8
	if active:
		var lava_material := _solid_material(Color("ff6a23"))
		lava_material.emission_enabled = true
		lava_material.emission = Color("ff4a0d")
		lava_material.emission_energy_multiplier = 2.5
		crater_mesh.material = lava_material
	else:
		crater_mesh.material = _solid_material(Color("2b2522"))
	crater.mesh = crater_mesh
	crater.position = Vector3(x, ground + 52.7, local_z)
	parent.add_child(crater)
	# Every volcano gets an eruption kit so shouting can wake dormant ones;
	# only active cones get idle embers and smoke.
	var glow := OmniLight3D.new()
	glow.name = "MagmaGlow"
	glow.light_color = Color("ff5a1a")
	glow.light_energy = 2.6 if active else 0.0
	glow.omni_range = 70.0
	glow.position = Vector3(x, ground + 56.0, local_z)
	parent.add_child(glow)
	var record := {
		"anchor": parent.position + Vector3(x, ground + 53.0, local_z),
		"glow": glow,
		"fountain": null,
		"flows": [],
		"active": active,
		"erupting": 0.0,
		"cooldown": 0.0,
		"phase": randf() * TAU,
	}
	_volcanoes.append(record)
	var flows: Array = record["flows"]
	_add_flows(parent, flows, x, ground, local_z)
	record["fountain"] = _add_fountain(parent, x, ground + 53.0, local_z)
	if active:
		_add_embers(parent, x, ground + 53.0, local_z)
		_add_smoke(parent, x, ground + 56.0, local_z)


func _lava_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("ff3a0a")
	mat.emission_enabled = true
	mat.emission = Color("ff4a0d")
	mat.emission_energy_multiplier = 2.5
	return mat


func _add_flows(parent: Node3D, flows: Array, x: float, ground: float, local_z: float) -> void:
	# Magma spill: emissive strips draped down the cone, hidden until eruption.
	var mat := _lava_material()
	for a in range(4):
		var ang: float = float(a) * PI * 0.5 + 0.4
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var top: Vector3 = Vector3(x, ground + 52.0, local_z) + dir * 6.0
		var bottom: Vector3 = Vector3(x, ground + 2.0, local_z) + dir * 33.0
		var strip := MeshInstance3D.new()
		strip.name = "MagmaFlow"
		var box := BoxMesh.new()
		var length: float = top.distance_to(bottom)
		box.size = Vector3(1.4, 0.5, length)
		box.material = mat
		strip.mesh = box
		strip.position = (top + bottom) * 0.5
		parent.add_child(strip)
		strip.look_at(strip.global_position + (bottom - top).normalized(), Vector3.UP)
		strip.visible = false
		strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		flows.append(strip)


func _add_fountain(parent: Node3D, x: float, y: float, local_z: float) -> CPUParticles3D:
	# Red lava fountain, idle until eruption.
	var fountain := CPUParticles3D.new()
	fountain.name = "LavaFountain"
	fountain.amount = 140
	fountain.lifetime = 2.2
	fountain.lifetime_randomness = 0.35
	fountain.local_coords = false
	fountain.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	fountain.emission_sphere_radius = 4.0
	fountain.direction = Vector3(0.0, 1.0, 0.0)
	fountain.spread = 12.0
	fountain.initial_velocity_min = 16.0
	fountain.initial_velocity_max = 24.0
	fountain.gravity = Vector3(0.0, -14.0, 0.0)
	fountain.damping_min = 0.2
	fountain.damping_max = 0.8
	var drop := SphereMesh.new()
	drop.radius = 0.28
	drop.height = 0.56
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("ff2a0d")
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop.material = mat
	fountain.mesh = drop
	fountain.position = Vector3(x, y, local_z)
	fountain.emitting = false
	parent.add_child(fountain)
	return fountain


func _add_embers(parent: Node3D, x: float, y: float, local_z: float) -> void:
	var sparks := CPUParticles3D.new()
	sparks.name = "Embers"
	sparks.amount = 48
	sparks.lifetime = 2.6
	sparks.lifetime_randomness = 0.4
	sparks.local_coords = false
	sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	sparks.emission_sphere_radius = 5.0
	sparks.direction = Vector3(0.0, 1.0, 0.0)
	sparks.spread = 18.0
	sparks.initial_velocity_min = 7.0
	sparks.initial_velocity_max = 13.0
	sparks.gravity = Vector3(0.0, 2.0, 0.0)
	sparks.damping_min = 0.5
	sparks.damping_max = 1.5
	var ember_mesh := SphereMesh.new()
	ember_mesh.radius = 0.16
	ember_mesh.height = 0.32
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("ff8a2a")
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ember_mesh.material = mat
	sparks.mesh = ember_mesh
	sparks.position = Vector3(x, y, local_z)
	sparks.emitting = true
	parent.add_child(sparks)


func _add_smoke(parent: Node3D, x: float, y: float, local_z: float) -> void:
	var smoke := CPUParticles3D.new()
	smoke.name = "SmokeColumn"
	smoke.amount = 36
	smoke.lifetime = 5.0
	smoke.lifetime_randomness = 0.3
	smoke.local_coords = false
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	smoke.emission_sphere_radius = 3.5
	smoke.direction = Vector3(0.15, 1.0, 0.0)
	smoke.spread = 10.0
	smoke.initial_velocity_min = 6.0
	smoke.initial_velocity_max = 10.0
	smoke.gravity = Vector3(0.0, 1.0, 0.0)
	var puff_mesh := BoxMesh.new()
	puff_mesh.size = Vector3(2.2, 2.2, 2.2)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("4a4a52")
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mesh.material = mat
	smoke.mesh = puff_mesh
	smoke.position = Vector3(x, y, local_z)
	smoke.emitting = true
	parent.add_child(smoke)


func _solid_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.93
	return material
