extends SceneTree

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var apartment := preload("res://tests/courtyard_fixture.tscn").instantiate()
	root.add_child(apartment)
	var player := apartment.get_node("Player") as CharacterBody3D
	player.simulates_movement = false
	var pickups := get_nodes_in_group(&"pickups")
	for pickup in pickups:
		# Selection feedback is independent of body simulation; keep these
		# fixtures still while moving them between controlled reach positions.
		pickup.freeze = true
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
	_check_marker_shape(first)
	var first_marker := first.get_node("PickupMarker") as MeshInstance3D
	var initial_heading := first_marker.global_basis.x
	_check(first.freeze, "The marker animation test uses a frozen pickup")
	await create_timer(0.15).timeout
	_check(initial_heading.angle_to(first_marker.global_basis.x) > 0.05, "A frozen pickup's marker rotates during normal process frames")
	var first_pose := first.global_transform
	first.global_position += Vector3(0.12, 0.2, -0.1)
	first.rotation = Vector3(0.6, 0.4, -0.5)
	await _wait_frames()
	_check_marker_position(first)
	first.global_transform = first_pose
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
	second.freeze = true
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
	first.freeze = true
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
			if mesh.name == &"PickupMarker":
				continue
			materials[mesh] = [mesh.material_override, mesh.material_overlay, mesh.transform]
		var collider := pickup.get_node("CollisionShape3D") as CollisionShape3D
		var shape := collider.shape
		var collider_pose := collider.transform
		pickup.add_to_group(&"pickups")
		player.global_position = pickup.global_position + Vector3(0, -0.5, 0.7)
		await _wait_frames()
		_check(_outlined(pickup), "%s supports the outline, including imported models" % pickup.name)
		_check_marker_shape(pickup)
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
	var disposable := preload("res://tests/pickup_fixture.tscn").instantiate() as RigidBody3D
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
	await _test_client_marker()
	if not failed:
		print("Pickup outline and rotating marker smoke test passed.")
	quit(int(failed))


func _outlined(pickup: RigidBody3D) -> bool:
	var outlined := false
	for mesh: MeshInstance3D in pickup.find_children("PickupOutline", "MeshInstance3D", true, false):
		if mesh.is_visible_in_tree():
			outlined = true
	var marker := pickup.get_node_or_null("PickupMarker") as MeshInstance3D
	var marked := marker != null and marker.is_visible_in_tree()
	_check(marked == outlined, "%s shows its blue marker only when its blue outline is visible" % pickup.name)
	return outlined


func _check_marker_shape(pickup: RigidBody3D) -> void:
	var marker := pickup.get_node_or_null("PickupMarker") as MeshInstance3D
	_check(marker != null, "%s creates a pickup marker on selection" % pickup.name)
	if marker == null:
		return
	_check(pickup.get("_pickup_marker") == marker, "%s reuses its own marker reference" % pickup.name)
	_check(pickup.find_children("PickupMarker", "MeshInstance3D", true, false).size() == 1,
		"%s has exactly one marker" % pickup.name)
	_check(marker.find_children("PickupOutline", "MeshInstance3D", true, false).is_empty(),
		"%s does not outline its auxiliary marker" % pickup.name)
	var pyramid := marker.mesh as CylinderMesh
	_check(pyramid != null, "%s uses a pyramid mesh" % pickup.name)
	if pyramid != null:
		_check(is_zero_approx(pyramid.bottom_radius) and pyramid.top_radius > 0.0 and pyramid.radial_segments == 4,
			"%s has a downward pointing square pyramid" % pickup.name)
		_check(pyramid.height <= 0.3 and pyramid.top_radius <= 0.2,
			"%s keeps the marker small" % pickup.name)
	var material := marker.material_override as StandardMaterial3D
	_check(material != null, "%s has a marker material" % pickup.name)
	if material != null:
		var color := material.albedo_color
		_check(color.r < 0.2 and color.g < 0.6 and color.b > 0.9,
			"%s uses a blue marker" % pickup.name)


func _check_marker_position(pickup: RigidBody3D) -> void:
	var marker := pickup.get_node("PickupMarker") as MeshInstance3D
	var collider := pickup.get_node("CollisionShape3D") as CollisionShape3D
	var bounds := collider.global_transform * collider.shape.get_debug_mesh().get_aabb()
	var center := bounds.get_center()
	_check(is_equal_approx(marker.global_position.x, center.x) and is_equal_approx(marker.global_position.z, center.z),
		"The marker follows the translated and tilted pickup's collider center")
	var pyramid := marker.mesh as CylinderMesh
	_check(marker.global_position.y - pyramid.height * 0.5 > bounds.end.y + 0.12,
		"The pyramid tip stays above the tilted pickup's world bounds")
	_check(marker.global_basis.y.is_equal_approx(Vector3.UP), "The marker stays upright when its pickup tilts")


func _test_client_marker() -> void:
	# A separate multiplayer branch exercises the real client authority path
	# without depending on a second game instance or shared lobby ports.
	var branch := Node3D.new()
	branch.name = "MarkerClient"
	root.add_child(branch)
	var client_api := SceneMultiplayer.new()
	var client_peer := ENetMultiplayerPeer.new()
	var result := client_peer.create_client("127.0.0.1", 1)
	_check(result == OK, "A client peer can be created for the marker test")
	if result != OK:
		branch.free()
		return
	client_api.multiplayer_peer = client_peer
	set_multiplayer(client_api, branch.get_path())
	var pickup := preload("res://tests/pickup_fixture.tscn").instantiate() as RigidBody3D
	branch.add_child(pickup)
	pickup.set_pickup_highlighted(true)
	_check(not pickup.multiplayer.is_server() and pickup.freeze,
		"The client marker test uses a frozen body on a non-server peer")
	_check(_outlined(pickup), "A client can show the same selected-item feedback")
	var marker := pickup.get_node("PickupMarker") as MeshInstance3D
	var heading := marker.global_basis.x
	await create_timer(0.15).timeout
	_check(heading.angle_to(marker.global_basis.x) > 0.05,
		"A frozen network client's marker rotates during normal process frames")
	_check_marker_position(pickup)
	pickup.set_pickup_highlighted(false)
	_check(not _outlined(pickup), "The client marker hides with its outline")
	branch.free()
	client_peer.close()


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
