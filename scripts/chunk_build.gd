extends RefCounted

# Incremental chunk mesh builder.
#
# Pure CPU: it samples the terrain/water height fields and piles triangles
# into SurfaceTool arrays. It never touches the SceneTree and never calls the
# RenderingServer, so it is safe to run to completion on a worker thread
# (`run_all`) or to step on the main thread under a time budget (`step`).
# ArrayMesh, node, and material creation all stay on the main thread in
# world_generator._assemble_chunk.
#
# Output lives in `surfaces`: one entry per mesh layer, each
# {"kind": "terrain"|"water", "arrays": Array} ready for
# ArrayMesh.add_surface_from_arrays().

const WATER_GX := 36
const WATER_GZ := 16

enum Phase { SAMPLE_TERRAIN, EMIT_TERRAIN, SAMPLE_WATER, EMIT_WATER, FINISH, DONE }

var gen
var row: int
var col: int
var biome_index: int
var chunk_name: String
var cell: Vector2i
var grid_x: int
var grid_z: int
var chunk_length: float
var world_width: float
var water_level: float

var surfaces: Array[Dictionary] = []
var done: bool = false

var _phase: int = Phase.SAMPLE_TERRAIN
var _iy: int = 0
var _nx: int = 0
var _wcols: int = 0
var _base_x: float = 0.0
var _base_z: float = 0.0
var _terrain: SurfaceTool
var _water: SurfaceTool
var _heights: PackedFloat32Array
var _colors: PackedColorArray
var _wcolors: PackedColorArray
# Private biome/water caches. The shared caches on the generator are written
# by the main thread (assembly, collision), so a worker must never touch
# them; each builder keeps its own and the results are identical because the
# lookups are pure functions of the cell seed.
var _bcache: Dictionary = {}
var _wcache: Dictionary = {}


func setup(p_gen, p_row: int, p_col: int, p_biome_index: int, p_name: String,
		p_grid_x: int, p_grid_z: int, p_chunk_length: float, p_world_width: float,
		p_water_level: float) -> void:
	gen = p_gen
	row = p_row
	col = p_col
	biome_index = p_biome_index
	chunk_name = p_name
	cell = Vector2i(p_col, p_row)
	grid_x = p_grid_x
	grid_z = p_grid_z
	chunk_length = p_chunk_length
	world_width = p_world_width
	water_level = p_water_level
	_base_x = float(col) * world_width
	_base_z = -float(row) * chunk_length
	_nx = grid_x + 1
	_wcols = WATER_GX + 1
	_heights.resize((grid_z + 1) * _nx)
	_colors.resize((grid_z + 1) * _nx)
	_wcolors.resize((WATER_GZ + 1) * _wcols)
	_terrain = SurfaceTool.new()
	_terrain.begin(Mesh.PRIMITIVE_TRIANGLES)
	_water = SurfaceTool.new()
	_water.begin(Mesh.PRIMITIVE_TRIANGLES)


# Run every phase. Used inside a worker thread.
func run_all() -> void:
	while not done:
		_advance_row()


# Do as many row-slices as fit the microsecond budget. Returns true when
# finished. Used to stream on the main thread without a stall.
func step(budget_usec: int) -> bool:
	var deadline: int = Time.get_ticks_usec() + budget_usec
	while not done:
		_advance_row()
		if Time.get_ticks_usec() >= deadline:
			break
	return done


func _advance_row() -> void:
	match _phase:
		Phase.SAMPLE_TERRAIN:
			_sample_terrain_row(_iy)
			_iy += 1
			if _iy > grid_z:
				_phase = Phase.EMIT_TERRAIN
				_iy = 0
		Phase.EMIT_TERRAIN:
			_emit_terrain_row(_iy)
			_iy += 1
			if _iy >= grid_z:
				_phase = Phase.SAMPLE_WATER
				_iy = 0
		Phase.SAMPLE_WATER:
			_sample_water_row(_iy)
			_iy += 1
			if _iy > WATER_GZ:
				_phase = Phase.EMIT_WATER
				_iy = 0
		Phase.EMIT_WATER:
			_emit_water_row(_iy)
			_iy += 1
			if _iy >= WATER_GZ:
				_phase = Phase.FINISH
		Phase.FINISH:
			_finish()


func _sample_terrain_row(iz: int) -> void:
	var z: float = -chunk_length * float(iz) / float(grid_z)
	var world_z: float = _base_z + z
	var row_base: int = iz * _nx
	for ix in range(_nx):
		var x: float = -world_width * 0.5 + world_width * float(ix) / float(grid_x)
		var x_abs: float = _base_x + x
		var h: float = gen._height_open(x_abs, world_z, _bcache, _wcache)
		_heights[row_base + ix] = h
		var detail: float = gen.detail_noise.get_noise_2d(x_abs, world_z)
		_colors[row_base + ix] = gen._color_open(x_abs, world_z, h, detail, _bcache, _wcache)


func _emit_terrain_row(iz: int) -> void:
	var x_half: float = -world_width * 0.5
	var z0: float = -chunk_length * float(iz) / float(grid_z)
	var z1: float = -chunk_length * float(iz + 1) / float(grid_z)
	var row0: int = iz * _nx
	var row1: int = row0 + _nx
	for ix in range(grid_x):
		var x0: float = x_half + world_width * float(ix) / float(grid_x)
		var x1: float = x_half + world_width * float(ix + 1) / float(grid_x)
		var i00: int = row0 + ix
		var i10: int = i00 + 1
		var i01: int = row1 + ix
		var i11: int = i01 + 1
		_emit_tri(_terrain,
			Vector3(x0, _heights[i00], z0), _colors[i00],
			Vector3(x1, _heights[i11], z1), _colors[i11],
			Vector3(x1, _heights[i10], z0), _colors[i10])
		_emit_tri(_terrain,
			Vector3(x0, _heights[i00], z0), _colors[i00],
			Vector3(x0, _heights[i01], z1), _colors[i01],
			Vector3(x1, _heights[i11], z1), _colors[i11])


func _sample_water_row(j: int) -> void:
	var z: float = -chunk_length * float(j) / float(WATER_GZ)
	var world_z: float = _base_z + z
	var row_base: int = j * _wcols
	for i in range(_wcols):
		var x: float = -world_width * 0.5 + world_width * float(i) / float(WATER_GX)
		_wcolors[row_base + i] = gen._water_color_at(_base_x + x, world_z, _bcache, _wcache)


func _emit_water_row(j: int) -> void:
	var x_half: float = -world_width * 0.5
	var z0: float = -chunk_length * float(j) / float(WATER_GZ)
	var z1: float = -chunk_length * float(j + 1) / float(WATER_GZ)
	var row0: int = j * _wcols
	var row1: int = row0 + _wcols
	for i in range(WATER_GX):
		var x0: float = x_half + world_width * float(i) / float(WATER_GX)
		var x1: float = x_half + world_width * float(i + 1) / float(WATER_GX)
		var i00: int = row0 + i
		var i10: int = i00 + 1
		var i01: int = row1 + i
		var i11: int = i01 + 1
		_emit_tri(_water,
			Vector3(x0, water_level, z0), _wcolors[i00],
			Vector3(x1, water_level, z1), _wcolors[i11],
			Vector3(x1, water_level, z0), _wcolors[i10])
		_emit_tri(_water,
			Vector3(x0, water_level, z0), _wcolors[i00],
			Vector3(x0, water_level, z1), _wcolors[i01],
			Vector3(x1, water_level, z1), _wcolors[i11])


func _emit_tri(surface: SurfaceTool, a: Vector3, ca: Color, b: Vector3, cb: Color, c: Vector3, cc: Color) -> void:
	surface.set_color(ca)
	surface.add_vertex(a)
	surface.set_color(cb)
	surface.add_vertex(b)
	surface.set_color(cc)
	surface.add_vertex(c)


func _finish() -> void:
	_terrain.generate_normals()
	surfaces.append({"kind": "terrain", "arrays": _terrain.commit_to_arrays()})
	_water.generate_normals()
	surfaces.append({"kind": "water", "arrays": _water.commit_to_arrays()})
	_phase = Phase.DONE
	done = true
