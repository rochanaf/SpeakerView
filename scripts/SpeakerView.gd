extends Node3D

enum SpatMode {DOME=0, CUBE=1, HYBRID=2}

const SG_SCALE: float = 10.0
const MAX_ELEVATION = 89.0
const MIN_ELEVATION = -89.0
const MIN_ZOOM: float = 4.0
const MAX_ZOOM: float = 70.0
const ZOOM_RANGE: float = MAX_ZOOM - MIN_ZOOM
const ZOOM_CURVE: float = 0.7
const INVERSE_ZOOM_CURVE: float = 1.0 / ZOOM_CURVE
const MOUSE_DRAG_SPEED: float = 0.1

var selected_speaker_number: int = 0
var reset_sources_position: bool = false
var quitting: bool = false

var speakerview_has_received_SG_data_at_least_once: bool = false

# command line args
var is_started_by_SG: bool = false # not used for now
var speakerview_window_position: Vector2i
var speakerview_window_size: Vector2i
var SG_asked_to_kill_speakerview: bool = false

var speaker_setup_name: String = ""
var old_speaker_setup_name: String = ""
var spat_mode: SpatMode
var show_source_number: bool
var show_speaker_number: bool
var show_speakers: bool
var show_speaker_triplets: bool
var show_source_activity: bool
var show_speaker_level: bool
var show_sphere_or_cube: bool
var spk_triplets: Array 

var cam_radius = 20.0
var rotation_speed = 0.1
var camera_azimuth: float = 70.0
var camera_elevation: float = 35.0
var camera_zoom_velocity: float = 0.0

var sphere_grid
var cube_grid

var use_vbap_complete_sphere: bool = false

var network_node
var dome_grid_node
var cube_grid_node
var triplets_node
var speakers_node
var camera_node

func _ready():
	network_node = get_node("Network")
	dome_grid_node = get_node("origin_grid/dome")
	cube_grid_node = get_node("origin_grid/cube")
	triplets_node = get_node("triplets")
	speakers_node = get_node("Speakers")
	camera_node = get_node("Center/Camera")
	
	sphere_grid = $shpere_grid
	cube_grid = $cube_grid
	
	var args = OS.get_cmdline_user_args()
	var dbgArgs: String = ""
	for arg in args:
		if arg == "launchedBySG=true":
			is_started_by_SG = true
		elif arg.contains("winPosition="):
			var values = arg.get_slice('=', 1)
			var split_values = values.split(",", false, 2)
			speakerview_window_position = Vector2i(int(split_values[0]), int(split_values[1]))
		elif arg.contains("winSize="):
			var values = arg.get_slice('=', 1)
			var split_values = values.split(",", false, 2)
			speakerview_window_size = Vector2i(int(split_values[0]), int(split_values[1]))
		elif arg.contains("camPos="):
			var values = arg.get_slice('=', 1)
			var split_values = values.split(",", false, 3)
			camera_azimuth = float(split_values[0])
			camera_elevation = float(split_values[1])
			cam_radius = float(split_values[2])
			clampf(cam_radius, camera_node.CAMERA_MIN_RADIUS, camera_node.CAMERA_MAX_RADIUS)
		dbgArgs += arg + " "
	$Debug.text = dbgArgs
	
	get_viewport().initial_position = Window.WindowInitialPosition.WINDOW_INITIAL_POSITION_ABSOLUTE
	if speakerview_window_position != Vector2i(0, 0):
		get_viewport().position = speakerview_window_position
	if speakerview_window_size != Vector2i(0, 0):
		get_viewport().size = speakerview_window_size

func _process(delta):
	# update_camera_position has to be called here if launched by SpatGris
	update_camera_position()
	
	sphere_grid.visible = ((spat_mode == SpatMode.DOME) or (spat_mode == SpatMode.HYBRID)) and show_sphere_or_cube
	cube_grid.visible = ((spat_mode == SpatMode.CUBE) or (spat_mode == SpatMode.HYBRID)) and show_sphere_or_cube
	
	dome_grid_node.visible = (spat_mode == SpatMode.DOME) or (spat_mode == SpatMode.HYBRID)
	cube_grid_node.visible = (spat_mode == SpatMode.CUBE) or (spat_mode == SpatMode.HYBRID)
	
	# camera zoom
	var zoom_to_add = delta * camera_zoom_velocity
	var current_zoom = (camera_node.global_position.length() - MIN_ZOOM) / ZOOM_RANGE
	var scaled_zoom = pow(current_zoom, ZOOM_CURVE)
	var scaled_target_zoom = max(scaled_zoom + zoom_to_add, 0.0)
	var unclipped_target_zoom = pow(scaled_target_zoom, INVERSE_ZOOM_CURVE) * ZOOM_RANGE + MIN_ZOOM
	var target_zoom = clamp(unclipped_target_zoom, MIN_ZOOM, MAX_ZOOM)
	
	camera_zoom_velocity *= pow(0.5, delta*8)
	cam_radius = target_zoom
	cam_radius = clampf(cam_radius, camera_node.CAMERA_MIN_RADIUS, camera_node.CAMERA_MAX_RADIUS)

func _input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_zoom_velocity -= (camera_zoom_velocity + 2.0) * 0.1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_zoom_velocity += (camera_zoom_velocity + 1.0) * 0.1 
	
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		camera_azimuth += event.relative.x * MOUSE_DRAG_SPEED
		camera_elevation += event.relative.y * MOUSE_DRAG_SPEED
		camera_elevation = clamp(camera_elevation, MIN_ELEVATION, MAX_ELEVATION)
	
	# trackpad on MacOS
	elif event is InputEventPanGesture:
		cam_radius += event.delta.y
		cam_radius = clampf(cam_radius, camera_node.CAMERA_MIN_RADIUS, camera_node.CAMERA_MAX_RADIUS)

	elif event is InputEventKey:
		# Handle Fullscreen mode
		if event.pressed and event.ctrl_pressed:
			if event.keycode == KEY_F:
				var mode = get_viewport().get_mode()
				if mode == Window.MODE_FULLSCREEN:
					get_viewport().set_mode(Window.MODE_WINDOWED)
				else:
					get_viewport().set_mode(Window.MODE_FULLSCREEN)

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if !speakerview_has_received_SG_data_at_least_once:
			return
		
		# When closing window, send info to SpatGris
		quitting = true
		network_node.send_UDP()
		get_tree().quit()

func update_camera_position():
	var x = cam_radius * cos(deg_to_rad(camera_azimuth)) * cos(deg_to_rad(camera_elevation))
	var y = cam_radius * sin(deg_to_rad(camera_elevation))
	var z = cam_radius * sin(deg_to_rad(camera_azimuth)) * cos(deg_to_rad(camera_elevation))
	
	camera_node.global_position = Vector3(x, y, z)

func toggle_reset_sources_positions():
	reset_sources_position = true
	network_node.send_UDP()
	reset_sources_position = false

func update_app_data(data: Variant):
	SG_asked_to_kill_speakerview = data.killSV
	speaker_setup_name = data.spkStpName
	spat_mode = data.spatMode
	show_source_number = data.showSourceNumber
	show_speaker_number = data.showSpeakerNumber
	show_speakers = data.showSpeakers
	show_speaker_triplets = data.showSpeakerTriplets
	show_source_activity = data.showSourceActivity
	show_speaker_level = data.showSpeakerLevel
	show_sphere_or_cube = data.showSphereOrCube
	spk_triplets = data.spkTriplets
	
#	if is_started_by_SG:
#		pass
	
	if show_speaker_triplets and !spk_triplets.is_empty():
		triplets_node.visible = true
		render_spk_triplets()
	else:
		triplets_node.visible = false
	
	if old_speaker_setup_name != speaker_setup_name:
		old_speaker_setup_name = speaker_setup_name
		get_viewport().set_title("SpeakerView - " + speaker_setup_name)
	
	if SG_asked_to_kill_speakerview:
		get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
	
	speakerview_has_received_SG_data_at_least_once = true

func render_spk_triplets():
	var vertices = PackedVector3Array()
	
	for triplet in spk_triplets:
		var spk_1 = speakers_node.get_speaker(triplet[0])
		var spk_2 = speakers_node.get_speaker(triplet[1])
		var spk_3 = speakers_node.get_speaker(triplet[2])
		
		if spk_1 != null and spk_2 != null and spk_3 != null:
			vertices.push_back(Vector3(spk_1.position.x, spk_1.position.y, spk_1.position.z))
			vertices.push_back(Vector3(spk_2.position.x, spk_2.position.y, spk_2.position.z))
			vertices.push_back(Vector3(spk_1.position.x, spk_1.position.y, spk_1.position.z))
			vertices.push_back(Vector3(spk_3.position.x, spk_3.position.y, spk_3.position.z))
			vertices.push_back(Vector3(spk_2.position.x, spk_2.position.y, spk_2.position.z))
			vertices.push_back(Vector3(spk_3.position.x, spk_3.position.y, spk_3.position.z))
	
	var arr_mesh = ArrayMesh.new()
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	triplets_node.mesh = arr_mesh
