# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The GPU vegetation cull measures from the camera the renderer DRAWS.
##
## With physics interpolation on, a camera moved in _physics_process is drawn, and
## its get_frustum() built, from an interpolated transform up to a tick BEHIND its
## global_transform. The cull took its eye from global_position and normalised the
## frustum planes' signs with a point 1.2 m ahead of global_position, while the planes
## themselves came from get_frustum(). Climbing fast, that point fell outside the drawn
## frustum's top or bottom plane, the plane was FLIPPED, and every on-screen tree and
## card failed it: the whole forest vanished on the frames that drew between ticks
## ("cards and trees flicker if you change elevation fast").
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Ind := preload("res://addons/wuifwoud/forest_indirect.gd")


## Points the DRAWN camera sees: the view axis near and far, and toward each corner of
## the image at 60 m. All are inside the drawn frustum by construction.
static func _on_screen(cam: Camera3D, drawn: Transform3D) -> Array:
	var out: Array = []
	var fwd := -drawn.basis.z
	out.append(drawn.origin + fwd * 3.0)
	out.append(drawn.origin + fwd * 400.0)
	# 80 % of the VERTICAL half-extent (`fov` is vertical under keep_height), used both
	# ways: the horizontal extent is never the narrower one at a landscape aspect.
	var half := tan(deg_to_rad(cam.fov) * 0.5) * 0.8
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var dir: Vector3 = (fwd + drawn.basis.x * (float(sx) * half)
				+ drawn.basis.y * (float(sy) * half)).normalized()
			out.append(drawn.origin + dir * 60.0)
	return out


static func run() -> Dictionary:
	var d: Array = []
	var passed := 0
	var failed := 0
	var tree := Engine.get_main_loop() as SceneTree
	# The cull must hold for a project that interpolates physics, whatever this project's setting: on for the suite.
	var interpolated := tree.physics_interpolation
	tree.physics_interpolation = true
	var host := Node3D.new()
	tree.root.add_child(host)
	# Metres per PHYSICS TICK straight up: 25, 50 and 90 m/s at 60 Hz: a helicopter, a
	# climbing aircraft, a fast fly-camera. Pitched down 25 degrees, looking at the
	# ground the forest is on.
	for per_tick in [0.42, 0.83, 1.5]:
		var cam := Camera3D.new()
		host.add_child(cam)
		cam.rotation.x = deg_to_rad(-25.0)
		cam.position = Vector3(0.0, 300.0, 0.0)
		cam.reset_physics_interpolation()
		var checked := 0
		var worst_lead := 0.0
		var eye_bad := 0
		var outside := 0
		for i in 120:
			await tree.physics_frame
			cam.position += Vector3(0.0, per_tick, 0.0)
			await tree.process_frame
			var drawn := cam.get_camera_transform()
			var lead := drawn.origin.distance_to(cam.global_position)
			if lead < 0.05:
				continue                      # this frame drew the tick itself
			worst_lead = maxf(worst_lead, lead)
			checked += 1
			if Ind.eye_of(cam).distance_to(drawn.origin) > 1e-3:
				eye_bad += 1
			var rows := Ind.frustum_rows(cam)
			for pt in _on_screen(cam, drawn):
				for p in 6:
					var n := Vector3(rows[p * 4], rows[p * 4 + 1], rows[p * 4 + 2])
					if n.dot(pt) + rows[p * 4 + 3] < 0.0:
						outside += 1
			if checked >= 12:
				break
		print("  climb %.0f m/s: %d interpolated frames, physics transform led by up to %.2f m; eye off on %d, on-screen points culled %d"
			% [per_tick * 60.0, checked, worst_lead, eye_bad, outside])
		if checked >= 3: passed += 1
		else: failed += 1; d.append("climb %.0f m/s: only %d frames drew between ticks" % [per_tick * 60.0, checked])
		if eye_bad == 0: passed += 1
		else: failed += 1; d.append("climb %.0f m/s: the cull's eye is not the drawn camera on %d frames" % [per_tick * 60.0, eye_bad])
		if outside == 0: passed += 1
		else: failed += 1; d.append("climb %.0f m/s: %d on-screen point tests failed a plane (a FLIPPED plane culls the forest)" % [per_tick * 60.0, outside])
		cam.queue_free()
	host.queue_free()
	tree.physics_interpolation = interpolated
	return {"name": "vegetation_view", "passed": passed, "failed": failed, "details": d}
