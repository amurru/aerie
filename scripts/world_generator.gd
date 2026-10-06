extends Node3D

const CHUNK_LENGTH: float = 180.0
const WORLD_WIDTH: float = 520.0
const GRID_X: int = 44
const GRID_Z: int = 28
const KEEP_BEHIND: int = 2
const KEEP_AHEAD: int = 7
const SIDE_COLUMNS: int = 1
const BIOMES: Array[String] = ["Steppe", "Mountains", "Glacier", "Volcano", "Forest", "Desert", "Lake country", "Highlands"]

var world_seed: int = 82731
var chunks: Dictionary = {}
var broad_noise: FastNoiseLite
var detail_noise: FastNoiseLite
var ridge_noise: FastNoiseLite


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
	var current_row: int = int(floor(-dragon_pos.z / CHUNK_LENGTH))
	var current_col: int = int(floor((dragon_pos.x + WORLD_WIDTH * 0.5) / WORLD_WIDTH))
	for row in range(current_row - KEEP_BEHIND, current_row + KEEP_AHEAD + 1):
		for col in range(current_col - SIDE_COLUMNS, current_col + SIDE_COLUMNS + 1):
			var key := Vector2i(col, row)
			if not chunks.has(key):
				_spawn_chunk(row, col)
	for key in chunks.keys():
		var row: int = key.y
		var col: int = key.x
		if row < current_row - KEEP_BEHIND or row > current_row + KEEP_AHEAD \
				or col < current_col - SIDE_COLUMNS or col > current_col + SIDE_COLUMNS:
			var old_chunk: Node3D = chunks[key]
			chunks.erase(key)
			old_chunk.queue_free()


func regenerate_at(dragon_pos: Vector3) -> void:
	for old_chunk in chunks.values():
		old_chunk.queue_free()
	chunks.clear()
	world_seed = randi_range(1, 2000000000)
	_configure_noise()
	update_follow(dragon_pos)


func biome_name_at(dragon_pos: Vector3) -> String:
	var row: int = int(floor(-dragon_pos.z / CHUNK_LENGTH))
	return BIOMES[_biome_index(row)]


func get_ground_height(x: float, world_z: float) -> float:
	var index: int = int(floor(-world_z / CHUNK_LENGTH))
	return _height(x, world_z, index)


func _biome_index(index: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = abs(world_seed + index * 104729) + 1
	var result: int = rng.randi_range(0, BIOMES.size() - 1)
	if index > -1000:
		var previous_rng := RandomNumberGenerator.new()
		previous_rng.seed = abs(world_seed + (index - 1) * 104729) + 1
		var previous: int = previous_rng.randi_range(0, BIOMES.size() - 1)
		if result == previous:
			result = (result + rng.randi_range(1, BIOMES.size() - 1)) % BIOMES.size()
	return result


func _spawn_chunk(row: int, col: int) -> void:
	var chunk := Node3D.new()
	chunk.name = "Biome_r%02d_c%02d_%s" % [row, col, BIOMES[_biome_index(row)].replace(" ", "_")]
	chunk.position = Vector3(float(col) * WORLD_WIDTH, 0.0, -float(row) * CHUNK_LENGTH)
	add_child(chunk)
	chunks[Vector2i(col, row)] = chunk
	var biome_index: int = _biome_index(row)
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
	_add_clouds(chunk, row, col)


func _height_for_biome(x: float, world_z: float, biome_index: int) -> float:
	var broad: float = broad_noise.get_noise_2d(x, world_z)
	var detail: float = detail_noise.get_noise_2d(x, world_z)
	var ridge: float = 1.0 - abs(ridge_noise.get_noise_2d(x, world_z))
	match BIOMES[biome_index]:
		"Mountains":
			return 14.0 + pow(ridge, 1.45) * 36.0 + broad * 7.0 + detail * 4.0
		"Glacier":
			return 20.0 + pow(ridge, 1.7) * 30.0 + broad * 7.0 + detail * 2.0
		"Volcano":
			return 12.0 + broad * 11.0 + detail * 6.0 + ridge * 9.0
		"Forest":
			return 13.0 + broad * 14.0 + detail * 3.0
		"Desert":
			return 7.0 + abs(broad) * 8.5 + detail * 3.0 + sin(world_z * 0.024 + x * 0.012) * 3.5
		"Lake country":
			return 9.0 + broad * 5.0 + detail * 1.3
		"Highlands":
			return 16.0 + abs(broad) * 18.0 + ridge * 8.0 + detail * 4.0
		_:
			return 11.0 + broad * 8.0 + detail * 2.5 + sin(x * 0.018) * 2.0


func _height(x: float, world_z: float, index: int) -> float:
	var start_z: float = -float(index) * CHUNK_LENGTH
	var along: float = clampf((start_z - world_z) / CHUNK_LENGTH, 0.0, 1.0)
	var current: int = _biome_index(index)
	var height: float = _height_for_biome(x, world_z, current)
	var transition: float = 0.13
	if along < transition:
		var previous: int = _biome_index(index - 1)
		var weight: float = 0.5 + 0.5 * smoothstep(0.0, transition, along)
		height = lerpf(_height_for_biome(x, world_z, previous), height, weight)
	elif along > 1.0 - transition:
		var following: int = _biome_index(index + 1)
		var weight: float = 0.5 * smoothstep(1.0 - transition, 1.0, along)
		height = lerpf(height, _height_for_biome(x, world_z, following), weight)
	return snappedf(height, 1.0)


func _ground_color(biome_index: int, height: float, detail: float) -> Color:
	var low: Color
	var high: Color
	var snow_line: float = 1000.0
	match BIOMES[biome_index]:
		"Mountains":
			low = Color("4f8a35")
			snow_line = 42.0
			high = Color("f4f6f3") if height > snow_line else Color("7d9078")
		"Glacier":
			low = Color("bcdcec")
			high = Color("ffffff") if height > 32.0 else Color("aed6e8")
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
			high = Color("e8ece6") if height > 44.0 else Color("84ac54")
		_:
			# Steppe: vivid green meadow.
			low = Color("46a02e")
			high = Color("8fd14f")
	var blend: float = clampf((height - 20.0) / 60.0, 0.0, 0.85)
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
			var p00 := Vector3(x0, _height(base_x + x0, base_z + z0, row), z0)
			var p10 := Vector3(x1, _height(base_x + x1, base_z + z0, row), z0)
			var p11 := Vector3(x1, _height(base_x + x1, base_z + z1, row), z1)
			var p01 := Vector3(x0, _height(base_x + x0, base_z + z1, row), z1)
			_add_colored_triangle(surface, p00, p10, p11, row, col)
			_add_colored_triangle(surface, p00, p11, p01, row, col)
	surface.generate_normals()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Faceted_terrain"
	mesh_instance.mesh = surface.commit()
	parent.add_child(mesh_instance)


func _add_colored_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, row: int, col: int) -> void:
	var biome_index: int = _biome_index(row)
	var base_x: float = float(col) * WORLD_WIDTH
	var base_z: float = -float(row) * CHUNK_LENGTH
	for point in [a, b, c]:
		var detail: float = detail_noise.get_noise_2d(base_x + point.x, base_z + point.z)
		surface.set_color(_ground_color(biome_index, point.y, detail))
		surface.add_vertex(point)


func _add_water(parent: Node3D, biome: String) -> void:
	var water := MeshInstance3D.new()
	water.name = "Still_water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(WORLD_WIDTH - 10.0, CHUNK_LENGTH)
	water.mesh = plane
	water.position = Vector3(0.0, 11.0, -CHUNK_LENGTH * 0.5)
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
		var ground: float = _height(float(col) * WORLD_WIDTH + x, -float(row) * CHUNK_LENGTH + z, row)
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
		var ground: float = _height(float(col) * WORLD_WIDTH + x, -float(row) * CHUNK_LENGTH + z, row)
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
		var ground: float = _height(float(col) * WORLD_WIDTH + x, -float(row) * CHUNK_LENGTH + z, row)
		var scale: float = rng.randf_range(0.65, 1.65)
		transforms.append(Transform3D(Basis().rotated(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3(scale, scale, scale)), Vector3(x, ground + 3.8 * scale, z)))
	_new_multimesh(ice_mesh, transforms, parent, "Ice_spires")


func _add_volcano(parent: Node3D, row: int, col: int) -> void:
	var x: float = -52.0 if (row % 2 == 0) else 55.0
	var local_z: float = -CHUNK_LENGTH * 0.55
	var world_z: float = -float(row) * CHUNK_LENGTH + local_z
	var ground: float = _height(float(col) * WORLD_WIDTH + x, world_z, row)
	var cone := MeshInstance3D.new()
	cone.name = "Seven_sided_volcanic_cone"
	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 5.5
	cone_mesh.bottom_radius = 39.0
	cone_mesh.height = 54.0
	cone_mesh.radial_segments = 7
	cone_mesh.rings = 1
	cone_mesh.material = _solid_material(Color("554a3f"))
	cone.mesh = cone_mesh
	cone.position = Vector3(x, ground + 25.0, local_z)
	parent.add_child(cone)
	var crater := MeshInstance3D.new()
	crater.name = "Lava_crater"
	var crater_mesh := CylinderMesh.new()
	crater_mesh.top_radius = 8.0
	crater_mesh.bottom_radius = 8.0
	crater_mesh.height = 0.55
	crater_mesh.radial_segments = 8
	var lava_material := _solid_material(Color("ff6a23"))
	lava_material.emission_enabled = true
	lava_material.emission = Color("ff4a0d")
	lava_material.emission_energy_multiplier = 1.8
	crater_mesh.material = lava_material
	crater.mesh = crater_mesh
	crater.position = Vector3(x, ground + 52.7, local_z)
	parent.add_child(crater)


func _add_clouds(parent: Node3D, row: int, col: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = abs(world_seed + row * 4421 + col * 149) + 5
	# Unshaded: sun never hits cloud bottoms, so lit shading renders them
	# near-black (see the dark slabs). Flat bright reads as stylized cloud.
	var material := _solid_material(Color("eef4f6", 0.9))
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for cloud in range(3):
		var cloud_root := Node3D.new()
		cloud_root.position = Vector3(rng.randf_range(-WORLD_WIDTH * 0.45, WORLD_WIDTH * 0.45), rng.randf_range(67.0, 94.0), -rng.randf_range(16.0, CHUNK_LENGTH - 16.0))
		parent.add_child(cloud_root)
		var puffs: int = rng.randi_range(3, 5)
		for puff in range(puffs):
			var block := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(rng.randf_range(5.0, 11.0), rng.randf_range(2.5, 4.6), rng.randf_range(4.0, 9.0))
			box.material = material
			block.mesh = box
			# Rectangular shadows from puff-boxes read as glitches; skip them.
			block.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			block.position = Vector3(float(puff - puffs / 2) * 4.0, rng.randf_range(-0.8, 1.2), rng.randf_range(-1.5, 1.5))
			cloud_root.add_child(block)


func _solid_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.93
	return material
