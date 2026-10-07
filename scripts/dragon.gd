extends Node3D

const TURN_RATE: float = 1.5
const MODEL_PATH := "res://assets/models/quaternius_dragon.glb"
const MODEL_LENGTH := 6.0

var flight_time: float = 0.0
var flight_speed: float = 27.0
# Unrushed underwater cruise: swimming stays slow and drift-like while the
# wings are folded, instead of racing at flight speed.
var swim_speed: float = 10.0
# Superspeed rush (Z key): 10s of multiplied thrust, then a cooldown that
# blocks consecutive rushes. Works in air and underwater.
const RUSH_DURATION := 10.0
const RUSH_COOLDOWN := 20.0
const RUSH_MULT := 2.2
var rush_time: float = 0.0
var rush_cooldown: float = 0.0
var altitude: float = 63.0
var turn_smooth: float = 0.0
var steering := Vector2.ZERO
var paused: bool = false
var energy_boost: float = 0.0
# Set by the controller: true while below the waterline in water.
var submerged: bool = false
var heading: float = 0.0
# 0 = wings out (flying), 1 = wings folded (swimming). Eased in _process.
# wallpaper.gd reads this for the dive camera.
var fold: float = 0.0
var swim_phase: float = 0.0

var _model: Node3D
var _anim: AnimationPlayer
var _skeleton: Skeleton3D
var _wing_l := [-1, -1]
var _wing_r := [-1, -1]
var _wing_tip_l := [-1, -1]
var _wing_tip_r := [-1, -1]
var _tail := [-1, -1]


func _ready() -> void:
	_build_dragon()
	position = Vector3(0.0, altitude, 0.0)


func _process(delta: float) -> void:
	if paused:
		return
	flight_time += delta
	energy_boost = maxf(0.0, energy_boost - delta * 0.8)
	rush_time = maxf(0.0, rush_time - delta)
	rush_cooldown = maxf(0.0, rush_cooldown - delta)
	var horizontal: float = Input.get_axis("move_left", "move_right")
	var vertical: float = Input.get_axis("move_down", "move_up")
	# Open flight: steering yaws the heading, dragon advances along it.
	# Hold A/D ~2s for a full U-turn.
	var turn_in: float = clampf(horizontal + steering.x, -1.0, 1.0)
	turn_smooth = lerpf(turn_smooth, turn_in, 1.0 - exp(-6.0 * delta))
	heading -= turn_in * TURN_RATE * delta
	# Swimming mode: wings fold back, body undulates like a fish.
	fold = lerpf(fold, 1.0 if submerged else 0.0, 1.0 - exp(-3.0 * delta))
	var wobble := 0.0
	if fold > 0.01:
		swim_phase += delta * 7.0
		wobble = sin(swim_phase) * 0.12 * fold
	rotation.y = heading + wobble
	var climb: float = vertical + steering.y
	# Floor -2.0 reaches deep lake basins; terrain collision in the
	# controller keeps the body out of rock.
	altitude = clampf(altitude + climb * 18.0 * delta, -2.0, 92.0)
	var bob: float = sin(flight_time * 0.72) * 2.2 * (1.0 - fold * 0.7)
	var desired_y: float = altitude + bob
	var facing := Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	# Easy with the flow: thrust eases from flight speed down to the slow
	# swim cruise as the wings fold, boost helping less underwater too.
	var thrust: float = lerpf(flight_speed + energy_boost * 10.0, swim_speed + energy_boost * 4.0, fold)
	if rush_time > 0.0:
		thrust *= RUSH_MULT
	position += facing * thrust * delta
	position.y = lerpf(position.y, desired_y, 1.0 - exp(-2.0 * delta))
	rotation.z = lerpf(rotation.z, clampf(-turn_smooth * 0.4, -0.5, 0.5), 1.0 - exp(-4.0 * delta))
	# Underwater the body pitches into the swim: stronger climb response
	# plus a slight nose-down cruise bias, so it reads as swimming, level.
	var pitch_gain := lerpf(0.12, 0.32, fold)
	var pitch_bias := -0.14 * fold
	rotation.x = lerpf(rotation.x, clampf(climb * pitch_gain + pitch_bias, -0.45, 0.45), 1.0 - exp(-3.0 * delta)) + sin(flight_time * 0.72) * 0.02 * (1.0 - fold)
	if _anim != null and _anim.is_playing():
		# Underwater the wingbeat slows to a lazy drift; the fold holds.
		# Rush quickens the beat so the sprint reads in the wings too.
		var beat: float = lerpf(1.0, 0.15, fold) * (1.6 if rush_time > 0.0 else 1.0)
		_anim.advance(delta * beat)
	_pose_swim_bones()
	steering = steering.move_toward(Vector2.ZERO, delta * 1.25)


func _pose_swim_bones() -> void:
	# Additive fold over the flying animation (advanced manually above, so
	# this ordering is deterministic): wings sweep back, tail sways.
	# Requires a live animation stream: without per-frame pose resets the
	# multiplies would accumulate and spin the wings like a propeller.
	if _skeleton == null or fold < 0.01:
		return
	if _anim == null or not _anim.is_playing():
		return
	var sweep := Quaternion(Vector3.UP, fold * 1.3)
	var curl := Quaternion(Vector3.UP, fold * 0.9)
	for b in _wing_l:
		if b >= 0:
			_skeleton.set_bone_pose_rotation(b, _skeleton.get_bone_pose_rotation(b) * sweep)
	for b in _wing_r:
		if b >= 0:
			_skeleton.set_bone_pose_rotation(b, _skeleton.get_bone_pose_rotation(b) * sweep.inverse())
	for b in _wing_tip_l:
		if b >= 0:
			_skeleton.set_bone_pose_rotation(b, _skeleton.get_bone_pose_rotation(b) * curl)
	for b in _wing_tip_r:
		if b >= 0:
			_skeleton.set_bone_pose_rotation(b, _skeleton.get_bone_pose_rotation(b) * curl.inverse())
	var sway := Quaternion(Vector3.UP, sin(swim_phase + 1.2) * 0.28 * fold)
	for b in _tail:
		if b >= 0:
			_skeleton.set_bone_pose_rotation(b, _skeleton.get_bone_pose_rotation(b) * sway)


func add_mouse_steer(relative: Vector2) -> void:
	steering.x = clampf(steering.x + relative.x * 0.0018, -1.0, 1.0)
	steering.y = clampf(steering.y - relative.y * 0.0018, -1.0, 1.0)


func add_energy_boost(strength: float) -> void:
	energy_boost = clampf(energy_boost + strength, 0.0, 1.5)


func try_rush() -> bool:
	# Starts a 10s superspeed rush unless one is running or cooling down.
	if paused:
		return false
	if rush_time > 0.0 or rush_cooldown > 0.0:
		return false
	rush_time = RUSH_DURATION
	rush_cooldown = RUSH_DURATION + RUSH_COOLDOWN
	return true


func rush_active() -> bool:
	return rush_time > 0.0


func add_impulse(lateral: float, vertical: float) -> void:
	steering.x = clampf(steering.x + lateral, -1.0, 1.0)
	steering.y = clampf(steering.y + vertical, -1.0, 1.0)

func _build_dragon() -> void:
	# Quaternius CC0 dragon (assets/models/CREDITS.md): rigged, animated.
	var packed: PackedScene = load(MODEL_PATH)
	_model = packed.instantiate()
	_model.name = "DragonModel"
	add_child(_model)
	# Quaternius faces +Z; our forward is -Z.
	_model.rotation.y = PI
	# Uniform scale from measured bounds to the target body length.
	var bounds := AABB()
	var first := true
	var queue: Array[Node] = [_model]
	while not queue.is_empty():
		var n: Node = queue.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var local: AABB = (n as MeshInstance3D).mesh.get_aabb()
			var world_box: AABB = (n as MeshInstance3D).global_transform * local
			bounds = world_box if first else bounds.merge(world_box)
			first = false
		for c in n.get_children():
			queue.append(c)
	var longest: float = maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	if longest > 0.001:
		_model.scale = Vector3.ONE * (MODEL_LENGTH / longest)
	# Skeleton, flying loop on manual advance so bone overrides stay ordered.
	var anims: Array[Node] = _model.find_children("*", "AnimationPlayer", true, false)
	if not anims.is_empty():
		_anim = anims[0]
		_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		var clip := "DragonArmature|Dragon_Flying"
		# Imported clips default to play-once: without looping, advance()
		# stops rewriting bone poses, which freezes the wings in air and
		# makes swim overrides accumulate into a propeller underwater.
		var res: Animation = _anim.get_animation(clip)
		if res != null:
			res.loop_mode = Animation.LOOP_LINEAR
		_anim.play(clip)
	var skels: Array[Node] = _model.find_children("*", "Skeleton3D", true, false)
	if not skels.is_empty():
		_skeleton = skels[0]
		_wing_l = [_bone("Wing1.L"), _bone("Wing2.L")]
		_wing_r = [_bone("Wing1.R"), _bone("Wing2.R")]
		_wing_tip_l = [_bone("Wing3.L"), _bone("Wing4.L")]
		_wing_tip_r = [_bone("Wing3.R"), _bone("Wing4.R")]
		_tail = [_bone("Tail2"), _bone("Tail3")]
	# Headlamp: readability while diving and at night.
	var lamp := OmniLight3D.new()
	lamp.name = "DiveLamp"
	lamp.light_color = Color("bfe0ff")
	lamp.light_energy = 0.7
	lamp.omni_range = 26.0
	lamp.position = Vector3(0.0, 1.2, -3.0)
	add_child(lamp)


func _bone(bone_name: String) -> int:
	if _skeleton == null:
		return -1
	return _skeleton.find_bone(bone_name)
