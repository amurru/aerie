class_name AerieEnvironmentDirector
extends Node

# Drives day/night from the system clock and runs a semi-random weather
# state machine. All changes are gradual lerps, never snaps.

const WEATHERS: Array[String] = ["Clear", "Cloudy", "Fog", "Storm"]

const DAY_TOP := Color("2f6cb0")
const DAY_HOR := Color("a9c6de")
const DAY_FOG := Color("a9c4de")
const DAY_SUN := Color("fff2df")
const DUSK_TOP := Color("3a4a7a")
const DUSK_HOR := Color("e8a06a")
const DUSK_FOG := Color("c98f70")
const DUSK_SUN := Color("ffc98a")
const NIGHT_TOP := Color("060a14")
const NIGHT_HOR := Color("1a2333")
const NIGHT_FOG := Color("141c28")
const NIGHT_SUN := Color("9fb8ff")

var environment: Environment
var sky_material: ProceduralSkyMaterial
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var camera: Camera3D
var dragon: Node3D
var fx: AerieFxManager

var weather: String = "Clear"
var weather_sun: float = 1.0
var weather_fog: float = 0.00045
var weather_dark: float = 0.0
var submerged: bool = false
var _weather_timer: float = 90.0
var _storm_timer: float = 5.0
var _rain: CPUParticles3D
var _time_of_day: float = 12.0
var _moon: MeshInstance3D

# Dynamic cloud deck (replaces the old static per-chunk puffs).
const DECK_COUNT := 26
const DECK_MIN_R := 90.0
const DECK_MAX_R := 340.0
const DECK_RESPAWN_R := 420.0
var _deck: Array[Node3D] = []
var _deck_scale: Array[float] = []
var _deck_target: Array[float] = []
var _deck_drift: Array[float] = []
var _cloud_mats: Array[StandardMaterial3D] = []
var _cloud_meshes: Array[BoxMesh] = []
var _coverage: float = 9.0
var _wind := Vector3(1.0, 0.0, 0.25).normalized()


func setup(p_env: Environment, p_sky: ProceduralSkyMaterial, p_sun: DirectionalLight3D,
		p_fill: DirectionalLight3D, p_camera: Camera3D, p_dragon: Node3D, p_fx: AerieFxManager) -> void:
	environment = p_env
	sky_material = p_sky
	sun = p_sun
	fill = p_fill
	camera = p_camera
	dragon = p_dragon
	fx = p_fx
	_make_rain()
	_make_deck()
	_make_moon()
	_roll_weather(120.0)
	_apply(1.0)


func _process(delta: float) -> void:
	_time_of_day = _clock_hours()
	_weather_timer -= delta
	if _weather_timer <= 0.0:
		_roll_weather()
	# Ease current weather params toward their targets.
	var k: float = 1.0 - exp(-delta / 8.0)
	weather_sun = lerpf(weather_sun, _target_sun(), k)
	weather_fog = lerpf(weather_fog, _target_fog(), k)
	weather_dark = lerpf(weather_dark, _target_dark(), k)
	_apply(delta)
	_update_rain()
	_update_storm(delta)
	_update_deck(delta)
	_update_moon()


func time_string() -> String:
	var h: int = int(_time_of_day) % 24
	var m: int = int((_time_of_day - floor(_time_of_day)) * 60.0)
	return "%02d:%02d" % [h, m]


func period_name() -> String:
	if _day_amount() >= 0.98:
		return "Day"
	if _day_amount() <= 0.02:
		return "Night"
	if _time_of_day < 12.0:
		return "Dawn"
	return "Dusk"


func _clock_hours() -> float:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	return float(dt.get("hour", 12)) + float(dt.get("minute", 0)) / 60.0 + float(dt.get("second", 0)) / 3600.0


func _day_amount() -> float:
	return clampf(smoothstep(-0.08, 0.12, sin((_time_of_day - 6.0) / 12.0 * PI)), 0.0, 1.0)


func _dusk_amount() -> float:
	var a: float = exp(-pow(_time_of_day - 6.75, 2.0) / 0.8)
	var b: float = exp(-pow(_time_of_day - 17.75, 2.0) / 1.2)
	return clampf(a + b, 0.0, 1.0)


func _target_sun() -> float:
	match weather:
		"Cloudy":
			return 0.65
		"Fog":
			return 0.55
		"Storm":
			return 0.35
	return 1.0


func _target_fog() -> float:
	match weather:
		"Cloudy":
			return 0.0009
		"Fog":
			return 0.0024
		"Storm":
			return 0.0013
	return 0.00045


func _target_dark() -> float:
	match weather:
		"Cloudy":
			return 0.25
		"Fog":
			return 0.35
		"Storm":
			return 0.55
	return 0.0


func _roll_weather(min_duration: float = 0.0) -> void:
	var pool: Array[String] = ["Clear", "Clear", "Clear", "Clear", "Cloudy", "Cloudy", "Cloudy", "Fog", "Storm", "Storm"]
	var next: String = pool[randi_range(0, pool.size() - 1)]
	if next == weather:
		next = pool[randi_range(0, pool.size() - 1)]
	weather = next
	var duration: float = randf_range(75.0, 200.0)
	if weather == "Fog":
		duration = randf_range(45.0, 120.0)
	_weather_timer = maxf(duration, min_duration)


func _apply(_delta: float) -> void:
	if environment == null or sky_material == null or sun == null:
		return
	var day_f: float = _day_amount()
	var dusk_f: float = _dusk_amount() * (1.0 - (1.0 - day_f) * 0.5)
	var top: Color = DAY_TOP.lerp(DUSK_TOP, dusk_f).lerp(NIGHT_TOP, 1.0 - day_f)
	var hor: Color = DAY_HOR.lerp(DUSK_HOR, dusk_f).lerp(NIGHT_HOR, 1.0 - day_f)
	var fog_c: Color = DAY_FOG.lerp(DUSK_FOG, dusk_f).lerp(NIGHT_FOG, 1.0 - day_f)
	var sun_c: Color = DAY_SUN.lerp(DUSK_SUN, dusk_f).lerp(NIGHT_SUN, 1.0 - day_f)
	sky_material.sky_top_color = top.lerp(top * 0.45, weather_dark)
	sky_material.sky_horizon_color = hor.lerp(hor * 0.55, weather_dark)
	sky_material.ground_horizon_color = Color("7d9cbd").lerp(NIGHT_HOR, 1.0 - day_f)
	# The sky shader's own sun disk does not dim with our light energy, so it
	# would sit in the night sky as a dark blob. Shrink it away after dusk;
	# the moon mesh takes over.
	sky_material.sun_angle_max = lerpf(0.05, 18.0, day_f)
	environment.fog_light_color = fog_c
	environment.fog_density = weather_fog
	var sun_elev: float = lerpf(11.0, _sun_elevation(), day_f)
	var sun_azim: float = lerpf(-60.0, _sun_azimuth(), day_f)
	sun.rotation_degrees = Vector3(-sun_elev, sun_azim, 0.0)
	sun.light_color = sun_c
	var base_e: float = lerpf(lerpf(0.85, 0.5, dusk_f), 0.2, 1.0 - day_f)
	sun.light_energy = base_e * weather_sun
	if fill != null:
		fill.light_energy = lerpf(lerpf(0.3, 0.2, dusk_f), 0.08, 1.0 - day_f)
	environment.ambient_light_energy = lerpf(lerpf(0.38, 0.3, dusk_f), 0.12, 1.0 - day_f)


func _sun_elevation() -> float:
	var day_t: float = clampf((_time_of_day - 6.0) / 12.0, 0.0, 1.0)
	return lerpf(6.0, 58.0, sin(day_t * PI))


func _sun_azimuth() -> float:
	var day_t: float = clampf((_time_of_day - 6.0) / 12.0, 0.0, 1.0)
	return lerpf(60.0, -120.0, day_t)


func _make_deck() -> void:
	# Shared puff sizes + 3 brightness variants, composed randomly per cluster.
	var sizes := [
		Vector3(14.0, 4.0, 9.0), Vector3(9.0, 3.0, 7.0), Vector3(6.0, 2.6, 5.0),
		Vector3(18.0, 5.0, 10.0), Vector3(7.0, 4.5, 6.0), Vector3(11.0, 3.2, 12.0),
	]
	for s in sizes:
		var box := BoxMesh.new()
		box.size = s
		_cloud_meshes.append(box)
	for shade in [Color("f4f8fa"), Color("e8eef2"), Color("dbe3e9")]:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = shade
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.roughness = 1.0
		_cloud_mats.append(mat)
	# One cluster per deck slot, scattered around the dragon.
	for i in range(DECK_COUNT):
		var root := Node3D.new()
		root.name = "CloudCluster"
		add_child(root)
		var puffs: int = randi_range(3, 5)
		for p in range(puffs):
			var block := MeshInstance3D.new()
			block.mesh = _cloud_meshes[randi_range(0, _cloud_meshes.size() - 1)]
			block.material_override = _cloud_mats[randi_range(0, _cloud_mats.size() - 1)]
			block.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			block.position = Vector3(float(p - puffs / 2) * 7.0 + randf_range(-2.0, 2.0), randf_range(-1.5, 2.0), randf_range(-3.0, 3.0))
			var sc: float = randf_range(0.7, 1.4)
			block.scale = Vector3(sc, sc * randf_range(0.8, 1.1), sc)
			root.add_child(block)
		_deck.append(root)
		_deck_scale.append(0.01)
		_deck_target.append(0.0)
		_deck_drift.append(randf_range(0.7, 1.3))
		_scatter_cloud(root)


func _scatter_cloud(root: Node3D) -> void:
	if dragon == null:
		return
	var ang: float = randf_range(0.0, TAU)
	var dist: float = randf_range(DECK_MIN_R, DECK_MAX_R)
	root.position = Vector3(
		dragon.global_position.x + cos(ang) * dist,
		randf_range(78.0, 125.0),
		dragon.global_position.z + sin(ang) * dist
	)


func _coverage_target() -> float:
	match weather:
		"Cloudy":
			return 19.0
		"Fog":
			return 13.0
		"Storm":
			return float(DECK_COUNT)
	return 9.0


func _wind_speed() -> float:
	match weather:
		"Cloudy":
			return 2.5
		"Fog":
			return 1.0
		"Storm":
			return 6.0
	return 1.5


func _update_deck(delta: float) -> void:
	if dragon == null:
		return
	_coverage = lerpf(_coverage, _coverage_target(), 1.0 - exp(-delta / 6.0))
	var bright: float = _day_amount() * (1.0 - weather_dark * 0.75)
	var bases := [Color("f4f8fa"), Color("e8eef2"), Color("dbe3e9")]
	for i in range(_cloud_mats.size()):
		_cloud_mats[i].albedo_color = bases[i] * bright
	var wind_v: Vector3 = _wind * _wind_speed()
	for i in range(_deck.size()):
		var root: Node3D = _deck[i]
		root.position += wind_v * _deck_drift[i] * delta
		var flat := Vector2(root.position.x - dragon.global_position.x, root.position.z - dragon.global_position.z)
		if flat.length() > DECK_RESPAWN_R:
			_scatter_cloud(root)
		_deck_target[i] = 1.0 if float(i) < _coverage else 0.0
		_deck_scale[i] = lerpf(_deck_scale[i], _deck_target[i], 1.0 - exp(-delta / 1.5))
		var s: float = maxf(_deck_scale[i], 0.01)
		root.scale = Vector3(s, s, s)
		root.visible = _deck_scale[i] > 0.02


func _make_moon() -> void:
	_moon = MeshInstance3D.new()
	_moon.name = "NightMoon"
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("dfe8ff")
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material = mat
	_moon.mesh = sphere
	_moon.scale = Vector3.ONE * 18.0
	_moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_moon.visible = false
	add_child(_moon)


func _update_moon() -> void:
	if _moon == null or camera == null or sun == null:
		return
	var day_f: float = _day_amount()
	_moon.visible = day_f < 0.5
	if not _moon.visible:
		return
	# Anchored to the real light axis, so the visible moon and the cast
	# shadows always agree. Night elevation is low on purpose: the chase
	# camera looks slightly downward, so a high moon would sit above the
	# frame (and read as a detached studio light).
	var axis: Vector3 = sun.global_transform.basis.z.normalized()
	_moon.global_position = camera.global_position + axis * 500.0


func _make_rain() -> void:
	_rain = CPUParticles3D.new()
	_rain.name = "WeatherRain"
	_rain.amount = 900
	_rain.lifetime = 0.9
	_rain.local_coords = false
	_rain.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_rain.emission_box_extents = Vector3(35.0, 1.0, 35.0)
	_rain.direction = Vector3(0.15, -1.0, 0.05)
	_rain.spread = 5.0
	_rain.initial_velocity_min = 26.0
	_rain.initial_velocity_max = 32.0
	_rain.gravity = Vector3(0.0, -6.0, 0.0)
	var streak := BoxMesh.new()
	streak.size = Vector3(0.035, 0.7, 0.035)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("9fb6cc")
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	streak.material = mat
	_rain.mesh = streak
	_rain.emitting = false
	add_child(_rain)


func _update_rain() -> void:
	if _rain == null or camera == null:
		return
	_rain.global_position = camera.global_position + Vector3(0.0, 8.0, 0.0)
	# No rain below the surface: hidden the frame you dive.
	_rain.visible = not submerged
	_rain.emitting = weather == "Storm" and not submerged


func _update_storm(delta: float) -> void:
	if weather != "Storm" or fx == null or dragon == null:
		return
	_storm_timer -= delta
	if _storm_timer <= 0.0:
		_storm_timer = randf_range(3.0, 8.0)
		var at: Vector3 = dragon.global_position + Vector3(randf_range(-40.0, 40.0), 0.0, randf_range(-60.0, -20.0))
		fx.lightning_at(at, Color("a8c4ff"))
