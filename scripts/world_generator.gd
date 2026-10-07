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
var river_noise: FastNoiseLite
var _biome_cache: Dictionary = {}
var _water_cache: Dictionary = {}
var _volcanoes: Array[Dictionary] = []
var _volc_time: float = 0.0

var _sea_pool: Array[Node3D] = []
var _sea_bubbles: CPUParticles3D
var _sea_center := Vector3(0.0, 0.0, 0.0)
var _sea_built := false
var _water_mats: Array[StandardMaterial3D] = []
var _dive_alpha := 1.0
var _dive_target := 1.0
# Mesozoic water life: plesiosaurs, ichthyosaur schools, drifting
# ammonites. One record per creature root (children articulate); chunk
# recycle frees nodes, invalid entries are pruned in _process.
var _life: Array[Dictionary] = []
var _life_time: float = 0.0
var _life_tick: int = 0
const MAX_LIFE_NODES := 170


func _process(_delta: float) -> void:
	# Magma glow flicker for active volcanoes; eruption state machine.
	_dive_alpha = lerpf(_dive_alpha, _dive_target, 1.0 - exp(-_delta * 3.0))
	for i in range(_water_mats.size() - 1, -1, -1):
		var mat: StandardMaterial3D = _water_mats[i]
		if not is_instance_valid(mat):
			_water_mats.remove_at(i)
			continue
		var c: Color = mat.albedo_color
		c.a = _dive_alpha
		mat.albedo_color = c
	_update_life(_delta)
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

	river_noise = FastNoiseLite.new()
	river_noise.seed = world_seed + 101
	river_noise.frequency = 0.0011
	river_noise.fractal_octaves = 2
	river_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH


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
	_water_cache.clear()
	_water_mats.clear()
	_life.clear()
	_volcanoes.clear()
	world_seed = randi_range(1, 2000000000)
	_configure_noise()
	update_follow(dragon_pos)


func biome_name_at(dragon_pos: Vector3) -> String:
	if _river_weight(dragon_pos.x, dragon_pos.z) > 0.5 and _height_open(dragon_pos.x, dragon_pos.z) < WATER_LEVEL:
		return "River"
	var cell := _cell_at(dragon_pos.x, dragon_pos.z)
	if _water_class(cell) == WC_SEA:
		return "Sea"
	return BIOMES[_biome_index(cell)]


func get_ground_height(x: float, world_z: float) -> float:
	return _height_open(x, world_z)


const WATER_LEVEL := 8.0

# Water classes from neighborhood smoothing: scattered water cells merge
# into lakes, 3+ neighbors upgrade to sea, opposite pairs read as rivers.
const WC_NONE := 0
const WC_LAKE := 1
const WC_SEA := 2
const WC_RIVER := 3


func water_at(x_abs: float, world_z: float) -> bool:
	# Anything below the waterline holds water: the plane spans every chunk.
	return _height_open(x_abs, world_z) < WATER_LEVEL - 0.4


func _is_water_biome(biome_index: int) -> bool:
	return BIOMES[biome_index] == "Lake country" or BIOMES[biome_index] == "Steppe" or BIOMES[biome_index] == "Forest"


func _water_class(cell: Vector2i) -> int:
	if _water_cache.has(cell):
		return _water_cache[cell]
	var wet := {}
	var count := 0
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var c := cell + Vector2i(dx, dz)
			var w: bool = _is_water_biome(_raw_biome(c))
			wet[Vector2i(dx, dz)] = w
			if w:
				count += 1
	var result := WC_NONE
	if wet[Vector2i.ZERO]:
		if count >= 4:
			result = WC_SEA
		elif count == 3 and _is_opposite_pair(wet):
			result = WC_RIVER
		else:
			result = WC_LAKE
	elif count >= 5:
		# Dry cell ringed by water joins the lake.
		result = WC_LAKE
	_water_cache[cell] = result
	return result


func _is_opposite_pair(wet: Dictionary) -> bool:
	var ns: bool = wet[Vector2i(0, -1)] and wet[Vector2i(0, 1)]
	var ew: bool = wet[Vector2i(-1, 0)] and wet[Vector2i(1, 0)]
	var d1: bool = wet[Vector2i(-1, -1)] and wet[Vector2i(1, 1)]
	var d2: bool = wet[Vector2i(-1, 1)] and wet[Vector2i(1, -1)]
	return ns or ew or d1 or d2


func _river_weight(x_abs: float, world_z: float) -> float:
	# Winding river band, position-based so channels run for kilometers
	# regardless of cell borders.
	return 1.0 - smoothstep(0.06, 0.14, absf(river_noise.get_noise_2d(x_abs, world_z)))


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
	# One opaque plane per chunk: terrain above the waterline hides it, so
	# seas, merged lakes, rivers, and desert oases all read correctly.
	_add_water(chunk, row, col)
	_add_aquatic_life(chunk, row, col)


func _height_for_biome(x: float, world_z: float, biome_index: int, wc: int) -> float:
	var broad: float = broad_noise.get_noise_2d(x, world_z)
	var detail: float = detail_noise.get_noise_2d(x, world_z)
	var ridge: float = 1.0 - abs(ridge_noise.get_noise_2d(x, world_z))
	var h: float
	match BIOMES[biome_index]:
		"Mountains":
			h = 22.0 + pow(ridge, 1.45) * 36.0 + broad * 7.0 + detail * 4.0
		"Glacier":
			h = 28.0 + pow(ridge, 1.7) * 30.0 + broad * 7.0 + detail * 2.0
		"Volcano":
			h = 20.0 + broad * 11.0 + detail * 6.0 + ridge * 9.0
		"Forest":
			h = 21.0 + broad * 14.0 + detail * 3.0 - _basin(broad, -0.25, 10.0)
		"Desert":
			h = 15.0 + abs(broad) * 8.5 + detail * 3.0 + sin(world_z * 0.024 + x * 0.012) * 3.5
		"Lake country":
			h = 17.0 + broad * 5.0 + detail * 1.3 - _basin(broad, -0.1, 14.0)
		"Highlands":
			h = 24.0 + abs(broad) * 18.0 + ridge * 8.0 + detail * 4.0
		_:
			h = 19.0 + broad * 8.0 + detail * 2.5 + sin(x * 0.018) * 2.0 - _basin(broad, -0.2, 8.0)
	if wc == WC_SEA:
		# Pull toward a rolling seabed instead of clipping to a ceiling:
		# ceilings terrace whole cells into straight-edged plateaus.
		var floor_h: float = 2.5 + detail * 2.0
		h = lerpf(h - 4.0, floor_h, 0.8)
	elif wc == WC_LAKE and not _is_water_biome(biome_index):
		# Dry cell absorbed by a neighboring lake: pull below the shoreline
		# (an islet may survive where the base was very high).
		h = lerpf(h - 3.0, 5.5 + detail * 1.0, 0.8)
	# Winding river channel, positional so it runs across cell borders.
	var rw: float = _river_weight(x, world_z)
	if rw > 0.0:
		h = lerpf(h, minf(h, WATER_LEVEL - 7.5 + detail * 0.5), rw)
	return h


func _basin(broad: float, edge: float, depth: float) -> float:
	# Carved lake basins where the broad noise dips: full depth below
	# (edge - 0.6), fading to none at edge.
	return (1.0 - smoothstep(edge - 0.6, edge, broad)) * depth


func _height_open(x_abs: float, world_z: float) -> float:
	# Open-world height: cell biome blended toward edge neighbors on both
	# axes. Midpoint (0.5/0.5) exactly on shared edges, so neighbor chunks
	# compute identical values and seams match.
	var cell := _cell_at(x_abs, world_z)
	var h: float = _height_for_biome(x_abs, world_z, _biome_index(cell), _water_class(cell))
	var origin_x: float = float(cell.x) * WORLD_WIDTH - WORLD_WIDTH * 0.5
	var u: float = (x_abs - origin_x) / WORLD_WIDTH
	if u < EDGE_BLEND:
		var n := Vector2i(cell.x - 1, cell.y)
		var w: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, u))
		h = lerpf(_height_for_biome(x_abs, world_z, _biome_index(n), _water_class(n)), h, 1.0 - w)
	elif u > 1.0 - EDGE_BLEND:
		var n2 := Vector2i(cell.x + 1, cell.y)
		var w2: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, 1.0 - u))
		h = lerpf(_height_for_biome(x_abs, world_z, _biome_index(n2), _water_class(n2)), h, 1.0 - w2)
	var origin_z: float = -float(cell.y + 1) * CHUNK_LENGTH
	var t: float = (world_z - origin_z) / CHUNK_LENGTH
	if t < EDGE_BLEND:
		var n3 := Vector2i(cell.x, cell.y + 1)
		var w3: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, t))
		h = lerpf(_height_for_biome(x_abs, world_z, _biome_index(n3), _water_class(n3)), h, 1.0 - w3)
	elif t > 1.0 - EDGE_BLEND:
		var n4 := Vector2i(cell.x, cell.y - 1)
		var w4: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, 1.0 - t))
		h = lerpf(_height_for_biome(x_abs, world_z, _biome_index(n4), _water_class(n4)), h, 1.0 - w4)
	return snappedf(h, 1.0)


func _color_open(x_abs: float, world_z: float, height: float, detail: float) -> Color:
	# Same edge weights as _height_open, applied to colors so tint borders
	# stay continuous too.
	var cell := _cell_at(x_abs, world_z)
	var c: Color = _ground_color(_biome_index(cell), height, detail, _water_class(cell))
	var origin_x: float = float(cell.x) * WORLD_WIDTH - WORLD_WIDTH * 0.5
	var u: float = (x_abs - origin_x) / WORLD_WIDTH
	if u < EDGE_BLEND:
		var n := Vector2i(cell.x - 1, cell.y)
		var w: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, u))
		c = _ground_color(_biome_index(n), height, detail, _water_class(n)).lerp(c, 1.0 - w)
	elif u > 1.0 - EDGE_BLEND:
		var n2 := Vector2i(cell.x + 1, cell.y)
		var w2: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, 1.0 - u))
		c = _ground_color(_biome_index(n2), height, detail, _water_class(n2)).lerp(c, 1.0 - w2)
	var origin_z: float = -float(cell.y + 1) * CHUNK_LENGTH
	var t: float = (world_z - origin_z) / CHUNK_LENGTH
	if t < EDGE_BLEND:
		var n3 := Vector2i(cell.x, cell.y + 1)
		var w3: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, t))
		c = _ground_color(_biome_index(n3), height, detail, _water_class(n3)).lerp(c, 1.0 - w3)
	elif t > 1.0 - EDGE_BLEND:
		var n4 := Vector2i(cell.x, cell.y - 1)
		var w4: float = 0.5 * (1.0 - smoothstep(0.0, EDGE_BLEND, 1.0 - t))
		c = _ground_color(_biome_index(n4), height, detail, _water_class(n4)).lerp(c, 1.0 - w4)
	return c


func _ground_color(biome_index: int, height: float, detail: float, wc: int) -> Color:
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
	color = color * (1.0 + detail * 0.045)
	if wc != WC_NONE and height < WATER_LEVEL:
		# Depth-graded bed: shallow sand-teal sinking toward deep teal.
		var depth: float = clampf((WATER_LEVEL - height) / 14.0, 0.0, 1.0)
		color = color.lerp(Color("1d5a5e"), 0.25 + depth * 0.6)
	return color


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


func _water_color_at(x_abs: float, world_z: float) -> Color:
	# Depth-graded surface: pale shelf water sinking through teal and blue
	# toward abyssal navy, teal rivers. Sampled per-vertex from the same
	# height field, so shared chunk edges compute identical values and no
	# tint seam appears.
	var depth: float = WATER_LEVEL - _height_open(x_abs, world_z)
	var c: Color = _depth_ramp(depth)
	var rw: float = _river_weight(x_abs, world_z)
	if rw > 0.3:
		c = c.lerp(Color("3a8a7a"), rw * 0.6)
	return c


func _depth_ramp(depth: float) -> Color:
	# Multi-stop ramp so depth reads at a glance: bright shallows over
	# shorelines, dark open water over basins and channels.
	var shelf := Color("5fd0d8")
	var teal := Color("2a9ab5")
	var mid := Color("145e9e")
	var deep := Color("0a3a7a")
	var abyss := Color("061a3d")
	if depth <= 0.0:
		return shelf
	if depth < 3.0:
		return shelf.lerp(teal, depth / 3.0)
	if depth < 6.0:
		return teal.lerp(mid, (depth - 3.0) / 3.0)
	if depth < 10.0:
		return mid.lerp(deep, (depth - 6.0) / 4.0)
	if depth < 14.0:
		return deep.lerp(abyss, (depth - 10.0) / 4.0)
	return abyss


func _add_water(parent: Node3D, row: int, col: int) -> void:
	var water := MeshInstance3D.new()
	water.name = "Still_water"
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var water_material := StandardMaterial3D.new()
	# Opaque-look surface that can fade while diving so the swimmer stays
	# visible: transparency on, alpha driven toward 1.0 / 0.45 in _process.
	water_material.vertex_color_use_as_albedo = true
	water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water_material.roughness = 0.3
	water_material.metallic = 0.0
	# Unculled: visible from above, and from below while diving.
	water_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	surface.set_material(water_material)
	# Full chunk span with coincident edge verts: no coverage gap, no seam.
	# Dense enough (36x16) that depth tinting resolves basins, channels,
	# and shorelines instead of blurring across them.
	var gx := 36
	var gz := 16
	var base_x: float = float(col) * WORLD_WIDTH
	var base_z: float = -float(row) * CHUNK_LENGTH
	for j in range(gz):
		for i in range(gx):
			var x0: float = -WORLD_WIDTH * 0.5 + WORLD_WIDTH * float(i) / gx
			var x1: float = -WORLD_WIDTH * 0.5 + WORLD_WIDTH * float(i + 1) / gx
			var z0: float = -CHUNK_LENGTH * float(j) / gz
			var z1: float = -CHUNK_LENGTH * float(j + 1) / gz
			var quad := [Vector3(x0, WATER_LEVEL, z0), Vector3(x1, WATER_LEVEL, z0), Vector3(x1, WATER_LEVEL, z1), Vector3(x0, WATER_LEVEL, z1)]
			for v in [quad[0], quad[1], quad[2]]:
				surface.set_color(_water_color_at(base_x + v.x, base_z + v.z))
				surface.add_vertex(v)
			for v in [quad[0], quad[2], quad[3]]:
				surface.set_color(_water_color_at(base_x + v.x, base_z + v.z))
				surface.add_vertex(v)
	surface.generate_normals()
	water.mesh = surface.commit()
	water.position = Vector3.ZERO
	parent.add_child(water)
	_water_mats.append(water_material)


func set_dive(diving: bool) -> void:
	_dive_target = 0.45 if diving else 1.0


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
		if ground < WATER_LEVEL - 1.0:
			continue
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
		if ground < WATER_LEVEL - 1.0:
			continue
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
		if ground < WATER_LEVEL - 1.0:
			continue
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


func _add_aquatic_life(parent: Node3D, row: int, col: int) -> void:
	# Mesozoic seas: plesiosaurs cruise, ichthyosaur pods dart, ammonites
	# drift. Only some water bodies are populated; placement is
	# deterministic per cell so reshuffles differ but revisits stay stable.
	var cell := Vector2i(col, row)
	var wc: int = _water_class(cell)
	if wc == WC_NONE:
		# Rivers carve below the waterline without a lake/sea class: sample
		# the chunk, treat it as river habitat when genuinely wet.
		var wet := 0
		var base_x: float = float(col) * WORLD_WIDTH
		var base_z: float = -float(row) * CHUNK_LENGTH
		for sample in [Vector2(-0.3, -0.3), Vector2(0.0, -0.2), Vector2(0.3, -0.3), Vector2(-0.2, -0.6), Vector2(0.2, -0.6), Vector2(0.0, -0.85)]:
			var wx: float = base_x + sample.x * WORLD_WIDTH
			var wz: float = base_z + sample.y * CHUNK_LENGTH
			if water_at(wx, wz):
				wet += 1
		if wet < 2:
			return
		wc = WC_RIVER
	var rng := RandomNumberGenerator.new()
	rng.seed = absi(world_seed + row * 9176 + col * 1543) + 5001
	# Not every water body gets life: seas almost always, lakes usually,
	# rivers sometimes.
	var occupancy := 1.0
	match wc:
		WC_SEA:
			occupancy = 0.95
		WC_LAKE:
			occupancy = 0.7
		_:
			occupancy = 0.5
	if rng.randf() > occupancy:
		return
	if _life.size() >= MAX_LIFE_NODES:
		return
	var schools := 0
	var plesiosaurs := 0
	var ammonites := 0
	match wc:
		WC_SEA:
			plesiosaurs = rng.randi_range(1, 2)
			schools = rng.randi_range(3, 4)
			ammonites = rng.randi_range(1, 2)
		WC_LAKE:
			plesiosaurs = rng.randi_range(0, 1)
			schools = rng.randi_range(2, 3) if rng.randf() < 0.7 else 0
			ammonites = rng.randi_range(1, 2)
		_:
			schools = 2 if rng.randf() < 0.5 else 0
	for p in range(plesiosaurs):
		_spawn_plesiosaur(parent, row, col, rng)
	if schools > 0:
		_spawn_ichthy_school(parent, row, col, rng, schools)
	for a in range(ammonites):
		_spawn_ammonite(parent, row, col, rng)


func _find_water_spot(rng: RandomNumberGenerator, row: int, col: int) -> Vector3:
	# Returns a chunk-local swim center, or Vector3.INF when no open water
	# was found after several tries.
	var base_x: float = float(col) * WORLD_WIDTH
	var base_z: float = -float(row) * CHUNK_LENGTH
	for attempt in range(8):
		var x: float = rng.randf_range(-WORLD_WIDTH * 0.5 + 25.0, WORLD_WIDTH * 0.5 - 25.0)
		var z: float = -rng.randf_range(12.0, CHUNK_LENGTH - 12.0)
		var ground: float = _height_open(base_x + x, base_z + z)
		if ground < WATER_LEVEL - 1.2:
			var depth_span: float = (WATER_LEVEL - 0.8) - (ground + 1.0)
			var y: float = ground + 1.0 + clampf(depth_span, 0.5, 4.5) * rng.randf_range(0.3, 0.7)
			y = clampf(y, ground + 1.0, WATER_LEVEL - 1.0)
			return Vector3(x, y, z)
	return Vector3.INF


func _still_water_spot(rng: RandomNumberGenerator, row: int, col: int, min_depth: float) -> Vector3:
	# Like _find_water_spot but prefers room below the surface for tall
	# creatures (plesiosaur necks): returns a deep spot when found,
	# otherwise the shallowest water found (necks may breach to breathe).
	var best := Vector3.INF
	for attempt in range(4):
		var spot: Vector3 = _find_water_spot(rng, row, col)
		if spot == Vector3.INF:
			continue
		if spot.y <= WATER_LEVEL - min_depth:
			return spot
		if best == Vector3.INF:
			best = spot
	return best


func _spawn_plesiosaur(parent: Node3D, row: int, col: int, rng: RandomNumberGenerator) -> void:
	# Long-necked cruiser: hull, raised neck + head with eyes, four paddle
	# flippers that row, and a tail spike. Slow majestic circles.
	var center: Vector3 = _still_water_spot(rng, row, col, 2.4)
	if center == Vector3.INF:
		return
	if _life.size() >= MAX_LIFE_NODES:
		return
	var hide := _solid_material(Color("5f7f4e"))
	var dark := _solid_material(Color("465f3c"))
	var root := Node3D.new()
	root.name = "Plesiosaur"
	var body := MeshInstance3D.new()
	var hull := SphereMesh.new()
	hull.radius = 0.9
	hull.height = 1.8
	hull.radial_segments = 8
	hull.rings = 4
	hull.material = hide
	body.mesh = hull
	body.scale = Vector3(1.0, 0.8, 1.6)
	root.add_child(body)
	var neck := MeshInstance3D.new()
	var neck_mesh := CylinderMesh.new()
	neck_mesh.top_radius = 0.2
	neck_mesh.bottom_radius = 0.34
	neck_mesh.height = 2.3
	neck_mesh.radial_segments = 6
	neck_mesh.material = hide
	neck.mesh = neck_mesh
	neck.position = Vector3(0.0, 1.0, -1.5)
	var neck_base := -0.85
	neck.rotation.x = neck_base
	root.add_child(neck)
	var head := MeshInstance3D.new()
	var skull := SphereMesh.new()
	skull.radius = 0.32
	skull.height = 0.64
	skull.radial_segments = 6
	skull.rings = 3
	skull.material = hide
	head.mesh = skull
	head.scale = Vector3(1.0, 0.8, 1.5)
	head.position = Vector3(0.0, 2.0, -2.5)
	root.add_child(head)
	var eye_mat := _solid_material(Color("14100c"))
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var dot := SphereMesh.new()
		dot.radius = 0.07
		dot.height = 0.14
		dot.material = eye_mat
		eye.mesh = dot
		eye.position = Vector3(side * 0.22, 2.1, -2.85)
		root.add_child(eye)
	var flip_mesh := BoxMesh.new()
	flip_mesh.size = Vector3(1.7, 0.14, 0.55)
	flip_mesh.material = dark
	var flippers: Array[Node3D] = []
	var sides: Array[float] = []
	var fx := [-1.0, 1.0, -1.0, 1.0]
	var fz := [-0.7, -0.7, 1.0, 1.0]
	for i in range(4):
		var flip := MeshInstance3D.new()
		flip.mesh = flip_mesh
		flip.position = Vector3(fx[i] * 1.0, -0.25, fz[i])
		flip.rotation.y = fx[i] * -0.2
		root.add_child(flip)
		flippers.append(flip)
		sides.append(fx[i])
	var tail := MeshInstance3D.new()
	var spike := CylinderMesh.new()
	spike.top_radius = 0.06
	spike.bottom_radius = 0.3
	spike.height = 1.7
	spike.radial_segments = 5
	spike.material = dark
	tail.mesh = spike
	tail.position = Vector3(0.0, 0.15, 2.2)
	tail.rotation.x = 1.35
	root.add_child(tail)
	for c in root.get_children():
		(c as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(root)
	_life.append({
		"node": root, "kind": "plesio", "center": center,
		"radius": rng.randf_range(6.0, 12.0),
		"speed": rng.randf_range(0.1, 0.18) * (1.0 if rng.randf() < 0.5 else -1.0),
		"phase": rng.randf_range(0.0, TAU),
		"flippers": flippers, "sides": sides, "neck": neck,
		"neck_base": neck_base, "tail": tail,
	})


func _spawn_ichthy_school(parent: Node3D, row: int, col: int, rng: RandomNumberGenerator, count: int) -> void:
	# Dolphin-shaped sea dragons: torpedo body, snout, dorsal fin, side
	# paddles, and a vertical tail fluke. Quick pods that porpoise.
	var center: Vector3 = _find_water_spot(rng, row, col)
	if center == Vector3.INF:
		return
	var slate := _solid_material(Color("46626f"))
	var fin_mat := _solid_material(Color("2e454f"))
	var radius: float = rng.randf_range(6.0, 12.0)
	var speed: float = rng.randf_range(0.35, 0.6) * (1.0 if rng.randf() < 0.5 else -1.0)
	var phase: float = rng.randf_range(0.0, TAU)
	for i in range(count):
		if _life.size() >= MAX_LIFE_NODES:
			return
		var root := Node3D.new()
		root.name = "Ichthyosaur"
		var body := MeshInstance3D.new()
		var hull := SphereMesh.new()
		hull.radius = 0.5
		hull.height = 1.0
		hull.radial_segments = 7
		hull.rings = 4
		hull.material = slate
		body.mesh = hull
		body.scale = Vector3(0.9, 0.95, 2.4)
		root.add_child(body)
		var snout := MeshInstance3D.new()
		var beak := CylinderMesh.new()
		beak.top_radius = 0.05
		beak.bottom_radius = 0.28
		beak.height = 0.9
		beak.radial_segments = 6
		beak.material = slate
		snout.mesh = beak
		snout.position = Vector3(0.0, 0.05, -1.55)
		snout.rotation.x = -PI * 0.5
		root.add_child(snout)
		var dorsal := MeshInstance3D.new()
		var fin := PrismMesh.new()
		fin.size = Vector3(0.12, 0.7, 0.5)
		fin.material = fin_mat
		dorsal.mesh = fin
		dorsal.position = Vector3(0.0, 0.7, 0.2)
		dorsal.rotation.x = 0.25
		root.add_child(dorsal)
		var fluke := MeshInstance3D.new()
		var tail_fin := PrismMesh.new()
		tail_fin.size = Vector3(0.1, 1.0, 0.4)
		tail_fin.material = fin_mat
		fluke.mesh = tail_fin
		fluke.position = Vector3(0.0, 0.1, 1.65)
		root.add_child(fluke)
		var pad_mesh := BoxMesh.new()
		pad_mesh.size = Vector3(0.7, 0.1, 0.3)
		pad_mesh.material = fin_mat
		for side in [-1.0, 1.0]:
			var pad := MeshInstance3D.new()
			pad.mesh = pad_mesh
			pad.position = Vector3(side * 0.55, -0.15, -0.3)
			root.add_child(pad)
		for c in root.get_children():
			(c as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(root)
		_life.append({
			"node": root, "kind": "ichthy", "center": center,
			"radius": radius * rng.randf_range(0.7, 1.15),
			"speed": speed * rng.randf_range(0.9, 1.1),
			"phase": phase + rng.randf_range(-0.6, 0.6),
			"bob": rng.randf_range(0.5, 1.0), "fluke": fluke,
		})


func _spawn_ammonite(parent: Node3D, row: int, col: int, rng: RandomNumberGenerator) -> void:
	# Coiled drifters: amber coil shell, pale body, trailing tentacles.
	# Barely move, slow spin and sway on the current.
	var center: Vector3 = _find_water_spot(rng, row, col)
	if center == Vector3.INF:
		return
	if _life.size() >= MAX_LIFE_NODES:
		return
	var root := Node3D.new()
	root.name = "Ammonite"
	var shell := MeshInstance3D.new()
	var coil := TorusMesh.new()
	coil.inner_radius = 0.35
	coil.outer_radius = 0.7
	coil.rings = 8
	coil.ring_segments = 12
	coil.material = _solid_material(Color("b07a3a"))
	shell.mesh = coil
	shell.scale = Vector3(1.0, 1.0, 0.7)
	root.add_child(shell)
	var body := MeshInstance3D.new()
	var mantle := SphereMesh.new()
	mantle.radius = 0.3
	mantle.height = 0.6
	mantle.radial_segments = 6
	mantle.rings = 3
	mantle.material = _solid_material(Color("d8c8a8"))
	body.mesh = mantle
	body.position = Vector3(0.0, -0.15, -0.55)
	root.add_child(body)
	var tent_mat := _solid_material(Color("8a6a4a"))
	var tentacles: Array[Node3D] = []
	for t in range(5):
		var arm := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.09
		cone.bottom_radius = 0.02
		cone.height = 0.7
		cone.radial_segments = 5
		cone.material = tent_mat
		arm.mesh = cone
		var spread: float = (float(t) - 2.0) * 0.18
		arm.position = Vector3(spread * 1.6, -0.75, -0.55 + absf(spread) * 0.4)
		arm.rotation.x = 0.15
		arm.rotation.z = -spread
		root.add_child(arm)
		tentacles.append(arm)
	for c in root.get_children():
		(c as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(root)
	_life.append({
		"node": root, "kind": "ammo", "center": center,
		"phase": rng.randf_range(0.0, TAU), "tentacles": tentacles,
	})


func _update_life(_delta: float) -> void:
	_life_time += _delta
	_life_tick += 1
	var t: float = _life_time
	for i in range(_life.size() - 1, -1, -1):
		var entry: Dictionary = _life[i]
		var obj: Variant = entry.get("node")
		if not is_instance_valid(obj):
			_life.remove_at(i)
			continue
		# Half the creatures animate each frame (30 Hz sampling, motion
		# stays continuous since it is driven by absolute time).
		if ((i + _life_tick) & 1) == 1:
			continue
		var node := obj as Node3D
		var kind := str(entry.get("kind", "plesio"))
		var center: Vector3 = entry.get("center", Vector3.ZERO)
		var phase: float = float(entry.get("phase", 0.0))
		if kind == "plesio":
			var radius: float = float(entry.get("radius", 8.0))
			var speed: float = float(entry.get("speed", 0.14))
			var ang: float = phase + t * speed
			node.position = center + Vector3(cos(ang) * radius, sin(t * 0.8 + phase) * 0.4, sin(ang) * radius)
			var dir_sign: float = 1.0 if speed >= 0.0 else -1.0
			var vel := Vector3(-sin(ang) * dir_sign, 0.0, cos(ang) * dir_sign)
			node.rotation.y = atan2(-vel.x, -vel.z)
			# Rowing flippers, swaying neck, lazy tail.
			var flippers: Array = entry.get("flippers", [])
			var sides: Array = entry.get("sides", [])
			for f in range(flippers.size()):
				var flip := flippers[f] as Node3D
				if not is_instance_valid(flip):
					continue
				var side: float = float(sides[f]) if f < sides.size() else 1.0
				var lag: float = 1.3 if f >= 2 else 0.0
				flip.rotation.z = side * (0.15 + sin(t * 2.4 + phase + lag) * 0.4)
			var neck := entry.get("neck") as Node3D
			if is_instance_valid(neck):
				neck.rotation.x = float(entry.get("neck_base", -0.85)) + sin(t * 0.8 + phase) * 0.08
			var tail := entry.get("tail") as Node3D
			if is_instance_valid(tail):
				tail.rotation.y = sin(t * 1.5 + phase) * 0.15
		elif kind == "ichthy":
			var radius_i: float = float(entry.get("radius", 8.0))
			var speed_i: float = float(entry.get("speed", 0.5))
			var bob: float = float(entry.get("bob", 0.7))
			var ang_i: float = phase + t * speed_i
			node.position = center + Vector3(cos(ang_i) * radius_i, sin(t * 1.4 + phase) * bob, sin(ang_i) * radius_i)
			var dir_i: float = 1.0 if speed_i >= 0.0 else -1.0
			var vel_i := Vector3(-sin(ang_i) * dir_i, 0.0, cos(ang_i) * dir_i)
			node.rotation.y = atan2(-vel_i.x, -vel_i.z)
			node.rotation.x = cos(t * 1.4 + phase) * 0.12
			node.rotation.z = sin(t * 1.1 + phase) * 0.08
			var fluke := entry.get("fluke") as Node3D
			if is_instance_valid(fluke):
				fluke.rotation.y = sin(t * 5.0 + phase) * 0.35
		elif kind == "ammo":
			node.position = center + Vector3(sin(t * 0.25 + phase) * 2.0, sin(t * 0.6 + phase) * 0.8, cos(t * 0.2 + phase) * 2.0)
			node.rotation.y = phase + t * 0.25
			node.rotation.z = sin(t * 0.5 + phase) * 0.1
			var arms: Array = entry.get("tentacles", [])
			for a in range(arms.size()):
				var arm := arms[a] as Node3D
				if is_instance_valid(arm):
					arm.rotation.x = 0.15 + sin(t * 1.8 + phase + float(a) * 0.7) * 0.18
