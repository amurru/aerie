extends Node3D

const WorldGenerator = preload("res://scripts/world_generator.gd")
const DragonFlight = preload("res://scripts/dragon.gd")
const EventBus = preload("res://scripts/event_bus.gd")
const InputManager = preload("res://scripts/input_manager.gd")
const AudioReactor = preload("res://scripts/audio_reactor.gd")
const ExternalEventServer = preload("res://scripts/external_event_server.gd")
const FxManager = preload("res://scripts/fx_manager.gd")

var dragon: Node3D
var world: Node3D
var chase_camera: Camera3D
var sun_light: DirectionalLight3D
var hud_panel: PanelContainer
var biome_label: Label
var status_label: Label
var hud_visible: bool = true
var paused: bool = false
var hud_timer: float = 0.0
var event_bus: AerieEventBus
var input_manager: AerieInputManager
var audio_reactor: AerieAudioReactor
var event_server: AerieExternalEventServer
var fx_manager: AerieFxManager


func _ready() -> void:
	event_bus = EventBus.new()
	event_bus.name = "AerieEventBus"
	add_child(event_bus)
	input_manager = InputManager.new()
	input_manager.name = "InputManager"
	add_child(input_manager)
	input_manager.setup()
	_setup_environment()
	world = WorldGenerator.new()
	world.name = "Streaming_world"
	add_child(world)
	dragon = DragonFlight.new()
	dragon.name = "Dragon"
	add_child(dragon)
	_setup_camera()
	_setup_hud()
	_setup_interactivity()
	_update_hud()


func _process(delta: float) -> void:
	world.update_follow(dragon.global_position)
	# Chase behind the heading so free flight and U-turns read correctly.
	# Slight lateral lag keeps steering parallax visible.
	var facing := Vector3(-sin(dragon.rotation.y), 0.0, -cos(dragon.rotation.y))
	var target: Vector3 = dragon.global_position - facing * 19.0 + Vector3(0.0, 7.6, 0.0)
	chase_camera.global_position = chase_camera.global_position.lerp(target, 1.0 - exp(-2.7 * delta))
	chase_camera.look_at(dragon.global_position + facing * 4.0 + Vector3(0.0, 0.1, 0.0), Vector3.UP)
	hud_timer -= delta
	if hud_timer <= 0.0:
		_update_hud()
		hud_timer = 0.35


func compass_point() -> String:
	var points := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var idx: int = int(round(-dragon.rotation.y / (PI / 4.0))) % 8
	if idx < 0:
		idx += 8
	return points[idx]


func _setup_input() -> void:
	# Kept for backward compatibility; real setup lives in InputManager.
	if input_manager != null:
		input_manager.setup()
		return
	_add_key_action("move_left", [KEY_A, KEY_LEFT])
	_add_key_action("move_right", [KEY_D, KEY_RIGHT])
	_add_key_action("move_up", [KEY_W, KEY_UP])
	_add_key_action("move_down", [KEY_S, KEY_DOWN])


func _setup_interactivity() -> void:
	fx_manager = FxManager.new()
	fx_manager.name = "FxManager"
	add_child(fx_manager)
	fx_manager.setup(event_bus, dragon, world, sun_light)
	audio_reactor = AudioReactor.new()
	audio_reactor.name = "AudioReactor"
	add_child(audio_reactor)
	audio_reactor.setup(event_bus)
	event_server = ExternalEventServer.new()
	event_server.name = "ExternalEventServer"
	add_child(event_server)
	var tcp_port := 42420
	if OS.has_environment("AERIE_EVENT_PORT"):
		tcp_port = int(OS.get_environment("AERIE_EVENT_PORT"))
	event_server.setup(event_bus, tcp_port)


func _add_key_action(action_name: String, keycodes: Array[int]) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	for keycode in keycodes:
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		InputMap.action_add_event(action_name, event)


func _setup_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("2f6cb0")
	sky_material.sky_horizon_color = Color("a9c6de")
	sky_material.sky_curve = 0.55
	sky_material.sky_energy_multiplier = 0.9
	sky_material.ground_bottom_color = Color("2f3d44")
	sky_material.ground_horizon_color = Color("7d9cbd")
	sky_material.ground_curve = 0.18
	sky_material.ground_energy_multiplier = 0.6
	sky_material.sun_angle_max = 18.0
	sky.sky_material = sky_material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.38
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 0.9
	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.3
	environment.adjustment_contrast = 1.06
	environment.fog_enabled = true
	environment.fog_light_color = Color("a9c4de")
	environment.fog_density = 0.00045
	environment.fog_sky_affect = 0.15
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.name = "Late_summer_sun"
	sun.rotation_degrees = Vector3(-38.0, -32.0, 0.0)
	sun.light_color = Color("fff2df")
	sun.light_energy = 0.85
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 240.0
	add_child(sun)
	sun_light = sun
	# Fill from the camera side: backlit faces (dragon tail, downhill slopes)
	# otherwise go near-black under a single key light. No shadows, subtle.
	var fill := DirectionalLight3D.new()
	fill.name = "Camera_fill"
	fill.rotation_degrees = Vector3(-12.0, 148.0, 0.0)
	fill.light_color = Color("cfe0ff")
	fill.light_energy = 0.3
	fill.shadow_enabled = false
	add_child(fill)


func _setup_camera() -> void:
	chase_camera = Camera3D.new()
	chase_camera.name = "Dragon_chase_camera"
	chase_camera.current = true
	chase_camera.fov = 66.0
	chase_camera.near = 0.1
	chase_camera.far = 700.0
	chase_camera.position = Vector3(0.0, 46.0, 22.0)
	add_child(chase_camera)
	chase_camera.look_at(Vector3(0.0, 39.0, -4.0), Vector3.UP)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Wallpaper_HUD"
	layer.layer = 5
	add_child(layer)
	hud_panel = PanelContainer.new()
	hud_panel.position = Vector2(24.0, 24.0)
	hud_panel.custom_minimum_size = Vector2(318.0, 104.0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.075, 0.1, 0.76)
	panel_style.border_color = Color(0.36, 0.75, 0.71, 0.72)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(9)
	panel_style.content_margin_left = 15.0
	panel_style.content_margin_right = 15.0
	panel_style.content_margin_top = 11.0
	panel_style.content_margin_bottom = 10.0
	hud_panel.add_theme_stylebox_override("panel", panel_style)
	layer.add_child(hud_panel)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 3)
	hud_panel.add_child(stack)
	var title := Label.new()
	title.text = "AERIE  /  SKYBOUND"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color("a8e8d1"))
	stack.add_child(title)
	biome_label = Label.new()
	biome_label.add_theme_font_size_override("font_size", 15)
	biome_label.add_theme_color_override("font_color", Color("fff1d7"))
	stack.add_child(biome_label)
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 11)
	status_label.add_theme_color_override("font_color", Color("bfd1d2"))
	stack.add_child(status_label)


func _update_hud() -> void:
	if biome_label == null or dragon == null:
		return
	biome_label.text = "Flying over  %s   ·   %s" % [world.biome_name_at(dragon.global_position), compass_point()]
	status_label.text = "WASD / arrows steer   •   R new world   •   F1 hide"
	var window := get_window()
	var extra := ""
	if audio_reactor != null:
		extra = "   •   voice %.2f" % audio_reactor.current_level
	if paused:
		status_label.text = "PAUSED   •   SPACE resume   •   F1 hide" + extra
	elif window.mode == Window.MODE_FULLSCREEN:
		status_label.text = "WASD / arrows steer   •   R new world   •   F11 window" + extra
	else:
		status_label.text += extra
	hud_panel.visible = hud_visible


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_F1:
				hud_visible = not hud_visible
				_update_hud()
				get_viewport().set_input_as_handled()
			KEY_F11:
				var window := get_window()
				window.mode = Window.MODE_WINDOWED if window.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
				get_viewport().set_input_as_handled()
			KEY_R:
				world.regenerate_at(dragon.global_position)
				_update_hud()
				get_viewport().set_input_as_handled()
			KEY_SPACE:
				paused = not paused
				dragon.paused = paused
				_update_hud()
				get_viewport().set_input_as_handled()
			KEY_L:
				# Debug: simulate Discord notification -> lightning.
				event_bus.publish_notification("Discord", "Test ping", "lightning check")
				get_viewport().set_input_as_handled()
			KEY_B:
				# Debug: simulate voice beat -> floaters + boost.
				event_bus.publish_beat(0.8)
				get_viewport().set_input_as_handled()
			KEY_M:
				# Debug: toggle voice reactivity.
				audio_reactor.enabled = not audio_reactor.enabled
				_update_hud()
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_MIDDLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		dragon.add_mouse_steer(event.relative)
