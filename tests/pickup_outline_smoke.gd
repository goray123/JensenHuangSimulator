extends SceneTree

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var apartment := preload("res://courtyard.tscn").instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	player.simulates_movement = false
	var pickups := get_nodes_in_group(&"pickups")
	for pickup in pickups:
		pickup.remove_from_group(&"pickups")
	var first := apartment.get_node("Pickup1") as RigidBody3D
	var second := apartment.get_node("Pickup2") as RigidBody3D
	first.add_to_group(&"pickups")
	second.add_to_group(&"pickups")
	player.global_position = Vector3(6.5, 0.065, -2)
	first.global_position = player.global_position + Vector3(-0.5, 0.04, 0)
	second.global_position = player.global_position + Vector3(1, 0.04, 0)
	await _wait_frames()
	_check(_outlined(first) and not _outlined(second), "Only the nearest grab target has a blue outline")
	player.global_position.x += 0.8
	await _wait_frames()
	_check(not _outlined(first) and _outlined(second), "Moving switches the outline to the new nearest target")
	second.global_position = player.global_position + Vector3(1.21, 0.04, 0)
	await _wait_frames()
	_check(not _outlined(first) and not _outlined(second), "Objects outside pickup reach lose the outline")
	second.global_position = player.global_position + Vector3(0.7, 1.0, 0)
	await _wait_frames()
	_check(_outlined(second), "A prop at table height uses the same grab reach rule")
	second.global_position.y = player.global_position.y + 3.0
	await _wait_frames()
	_check(not _outlined(second), "Objects above reachable height are not outlined")
	second.global_position = player.global_position + Vector3(0.7, 0.04, 0)
	await _wait_frames()
	player.simulates_movement = true
	await _hold_left()
	player.simulates_movement = false
	_check(player.held_pickup == second and not _outlined(second), "A left hold picks the outlined object and immediately hides its outline")
	first.global_position = player.global_position + Vector3(0.3, 0.04, 0)
	await _wait_frames()
	_check(not _outlined(first), "Full hands do not highlight another pickup")
	player.release_pickup(false)
	second.remove_from_group(&"pickups")
	await _wait_frames()
	_check(_outlined(first), "Emptying the hand restores pickup feedback")

	# A remote character must never change which object this viewport highlights.
	var remote := preload("res://player.tscn").instantiate() as CharacterBody3D
	remote.reads_local_input = false
	remote.simulates_movement = false
	apartment.add_child(remote)
	remote.global_position = second.global_position
	await _wait_frames()
	_check(_outlined(first) and not _outlined(second), "Remote characters do not override the local outline")
	player.reads_local_input = false
	await _wait_frames()
	_check(not _outlined(first), "Removing local control clears the old selection")
	player.reads_local_input = true
	player.simulates_movement = false
	await _wait_frames()
	_check(_outlined(first), "A locally controlled network client can highlight without simulating movement")
	remote.hold_pickup(first)
	_check(not _outlined(first), "Another player taking the target hides the outline immediately")
	remote.release_pickup(false)
	await _wait_frames()
	_check(_outlined(first), "A released object can be highlighted again")
	first.remove_from_group(&"pickups")
	remote.free()

	# Imported props are assembled after _ready; verify every model is covered.
	for pickup: RigidBody3D in pickups:
		pickup.remove_from_group(&"pickups")
	for pickup: RigidBody3D in pickups:
		var materials: Dictionary = {}
		for mesh: MeshInstance3D in pickup.find_children("*", "MeshInstance3D", true, false):
			materials[mesh] = [mesh.material_override, mesh.material_overlay, mesh.transform]
		var collider := pickup.get_node("CollisionShape3D") as CollisionShape3D
		var shape := collider.shape
		var collider_pose := collider.transform
		pickup.add_to_group(&"pickups")
		player.global_position = pickup.global_position + Vector3(0, -0.5, 0.7)
		await _wait_frames()
		_check(_outlined(pickup), "%s supports the outline, including imported models" % pickup.name)
		var mesh_count := pickup.find_children("*", "MeshInstance3D", true, false).size()
		for _repeat in 2:
			player.global_position.x += 3.0
			await _wait_frames()
			_check(not _outlined(pickup), "%s clears its outline when leaving reach" % pickup.name)
			player.global_position.x -= 3.0
			await _wait_frames()
		_check(pickup.find_children("*", "MeshInstance3D", true, false).size() == mesh_count, "%s reuses the outline without duplicating meshes" % pickup.name)
		for mesh: MeshInstance3D in materials:
			var original: Array = materials[mesh]
			_check(mesh.material_override == original[0] and mesh.material_overlay == original[1] and mesh.transform.is_equal_approx(original[2]), "%s preserves original materials and transforms" % pickup.name)
		_check(collider.shape == shape and collider.transform.is_equal_approx(collider_pose), "%s keeps its collision shape" % pickup.name)
		pickup.remove_from_group(&"pickups")

	# Both freeing the selection and leaving/resetting the scene must be safe.
	var disposable := preload("res://pickup.tscn").instantiate() as RigidBody3D
	apartment.add_child(disposable)
	disposable.global_position = player.global_position + Vector3(0.5, 0, 0)
	await _wait_frames()
	_check(_outlined(disposable), "A newly spawned pickup can be selected")
	disposable.queue_free()
	await _wait_frames()
	_check(player.get_pickup_target() == null, "Deleting the outlined pickup clears the selection safely")
	second.add_to_group(&"pickups")
	player.global_position = second.global_position + Vector3(0, 0, 0.7)
	await _wait_frames()
	_check(_outlined(second), "A new selection works after deletion")
	player.free()
	_check(not _outlined(second), "Removing the local player clears its outline")
	apartment.free()
	if not failed:
		print("Pickup outline smoke test passed.")
	quit(int(failed))


func _outlined(pickup: RigidBody3D) -> bool:
	for mesh: MeshInstance3D in pickup.find_children("PickupOutline", "MeshInstance3D", true, false):
		if mesh.is_visible_in_tree():
			return true
	return false


func _hold_left() -> void:
	_mouse(true)
	for _frame in 64:
		await physics_frame
	_mouse(false)


func _mouse(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _wait_frames() -> void:
	for _frame in 3:
		await physics_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)
