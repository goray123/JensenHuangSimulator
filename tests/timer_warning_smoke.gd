extends SceneTree

var failed := false
var alerts := 0


func _initialize() -> void:
	node_added.connect(func(node: Node) -> void:
		if node is AudioStreamPlayer and node.get_meta(&"sfx_event", &"") == &"timer_alert":
			alerts += 1)
	_run.call_deferred()


func _run() -> void:
	var apartment := preload("res://house.tscn").instantiate()
	root.add_child(apartment)
	await process_frame
	var environment := (apartment.get_node("WorldEnvironment") as WorldEnvironment).environment
	_check(environment.background_mode == Environment.BG_COLOR, "The round no longer depends on the flickering canvas background")
	var camera := apartment.get_node("Overview") as Camera3D
	var backdrop := camera.get_node("Backdrop") as MeshInstance3D
	var quad := backdrop.mesh as QuadMesh
	_check(quad != null and quad.size.y >= camera.size and backdrop.position.z < -camera.far * 0.9 and backdrop.position.z > -camera.far,
		"The gradient quad fills the camera view just inside its far plane")
	camera.size = 6.0
	await process_frame
	_check(is_equal_approx(quad.size.y, 6.0 * 1.02), "The gradient follows the contest zoom")
	# Stop the real countdown so only the seconds fed below reach the always-processing HUD.
	apartment.process_mode = Node.PROCESS_MODE_DISABLED

	var hud := apartment.get_node("HUD")
	var timer := hud.get_node("TimeLeft") as Control
	var vignette := hud.get_node("UrgentVignette") as ColorRect
	var rest := timer.position
	for seconds in range(60, 30, -1):
		hud.on_round_seconds_changed(seconds)
	_check(alerts == 0 and not vignette.visible, "Nothing fires before 30 seconds")
	hud.on_round_seconds_changed(30)
	await process_frame
	_check(alerts == 1 and not timer.position.is_equal_approx(rest), "30 seconds plays the alert once and shakes the timer")
	for _frame in 3:
		hud.on_round_seconds_changed(30)
	await create_timer(0.5).timeout
	_check(alerts == 1 and timer.position.is_equal_approx(rest), "The same second never repeats the alert and the shake settles back")

	for seconds in range(29, 10, -1):
		hud.on_round_seconds_changed(seconds)
	_check(not vignette.visible, "The overlay waits for the last 10 seconds")
	var intensity := func() -> float: return (vignette.material as ShaderMaterial).get_shader_parameter(&"intensity")
	hud.on_round_seconds_changed(10)
	await process_frame
	_check(vignette.visible and intensity.call() > 0.7 and not timer.position.is_equal_approx(rest), "10 seconds shows the red overlay and shakes the timer")
	await create_timer(0.9).timeout
	_check(intensity.call() < 0.35 and timer.position.is_equal_approx(rest), "The overlay eases back between ticks")
	hud.on_round_seconds_changed(9)
	await process_frame
	_check(intensity.call() > 0.7, "Every following second pulses again")
	hud.on_round_seconds_changed(10)
	hud.on_round_seconds_changed(9)
	_check(alerts == 1, "A reordered guest snapshot does not replay the 30-second alert")
	hud.on_round_seconds_changed(60)
	_check(not vignette.visible, "A restarted round clears the overlay")
	hud.on_round_seconds_changed(5)
	hud.clear_round_warnings()
	_check(not vignette.visible, "The round end clears the overlay")
	quit(int(failed))


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)
