# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The impostor card's basis (ForestAssets.card_basis, tree_billboard.gdshader's vertex() in GDScript): a card is
## oriented as its frame was baked (right = tree_up x to_cam), so it stays upright in the WORLD when the camera rolls
## or pitches and when it stands off screen centre (it used to take the camera's right: cards leaned and rolled with
## the screen); it still faces the camera squarely; overhead it hands over to the camera's right without a jump; and
## the shader carries the same construction.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const VA := preload("res://addons/wuifwoud/forest_assets.gd")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## wf_common's wf_frame_basis: the basis the bake gave the frame looking from `dir` (tree space).
static func _frame_basis(dir: Vector3) -> Array:
	var up := Vector3(0, 0, -1) if absf(dir.y) > 0.99 else Vector3.UP
	var x := up.cross(dir).normalized()
	return [x, dir.cross(x)]


static func run() -> Dictionary:
	var r := {"name": "forest_card_basis", "passed": 0, "failed": 0, "details": []}
	var up := Vector3.UP
	# A camera 30 deg above a tree, the card well off screen centre, the camera rolled 12 deg: the old basis
	# (the camera's right) and the new one.
	var to_cam := Vector3(0.6, 0.5, 0.62).normalized()
	var fwd := -Vector3(0.0, 0.45, 1.0).normalized()          # where the camera looks (not at this tree)
	var cam_basis := Basis.looking_at(fwd, Vector3.UP).rotated(fwd, deg_to_rad(12.0))
	var cam_right := cam_basis.x
	var b: Array = VA.card_basis(to_cam, up, cam_right)
	var right: Vector3 = b[0]
	var cup: Vector3 = b[1]
	_chk(r, "the card faces the camera squarely (right, up both perpendicular to the view)",
			absf(right.dot(to_cam)) < 1e-4 and absf(cup.dot(to_cam)) < 1e-4 and absf(right.dot(cup)) < 1e-4)
	_chk(r, "its right is level: the trunk stays upright in the world (right.y %.4f)" % right.y, absf(right.y) < 1e-4)
	_chk(r, "its up leans toward the sky, never down (up.y %.3f)" % cup.y, cup.y > 0.0)
	var fb := _frame_basis(to_cam)
	_chk(r, "it is the basis the frame was baked with (right %.4f, up %.4f off)" % [
			(right - (fb[0] as Vector3)).length(), (cup - (fb[1] as Vector3)).length()],
			right.is_equal_approx(fb[0]) and cup.is_equal_approx(fb[1]))
	_chk(r, "the camera's right was NOT that basis here (the old card rolled: %.1f deg)" % rad_to_deg(
			acos(clampf(cam_right.normalized().dot(right), -1.0, 1.0))),
			cam_right.normalized().dot(right) < cos(deg_to_rad(5.0)))
	# Rolling the camera does not turn the card.
	var rolled: Vector3 = (cam_basis.rotated(fwd, deg_to_rad(-24.0))).x
	var b2: Array = VA.card_basis(to_cam, up, rolled)
	_chk(r, "rolling the camera 24 deg leaves the card as it was", (b2[0] as Vector3).is_equal_approx(right))
	# A tilted tree (a slope's lean, its instance up) carries its own up.
	var lean := Vector3(0.15, 1.0, 0.0).normalized()
	var b3: Array = VA.card_basis(to_cam, lean, cam_right)
	_chk(r, "a leaning tree's card is level to the tree's own up", absf((b3[0] as Vector3).dot(lean)) < 1e-4)
	# Overhead: the camera's right, and no jump on the way there.
	var down_cam_right := Vector3(1, 0, 0)
	var top: Array = VA.card_basis(Vector3(0.0, 1.0, 0.0), up, down_cam_right)
	_chk(r, "straight overhead the card takes the camera's right", (top[0] as Vector3).is_equal_approx(down_cam_right))
	var prev: Vector3 = (VA.card_basis(Vector3(0.0, 0.0, 1.0), up, down_cam_right)[0] as Vector3)
	var worst := 0.0
	for i in range(1, 181):
		var el := deg_to_rad(i * 0.5)
		var d := Vector3(0.3 * cos(el), sin(el), cos(el)).normalized()
		var cr := Vector3(1, 0, -0.3).normalized()
		var rr: Vector3 = VA.card_basis(d, up, cr)[0]
		if i > 1:
			worst = maxf(worst, rad_to_deg(acos(clampf(rr.dot(prev), -1.0, 1.0))))
		prev = rr
	_chk(r, "climbing to overhead in 0.5 deg steps the card's right never jumps (worst step %.2f deg)" % worst,
			worst < 3.0)
	# The shader carries the same construction.
	var src := FileAccess.get_file_as_string("res://addons/wuifwoud/shaders/tree_billboard.gdshader")
	_chk(r, "tree_billboard.gdshader builds the card from the tree's up (cross(tree_up, to_cam))",
			src.contains("cross(tree_up, to_cam)") and src.contains("smoothstep(0.17, 0.34, tl)"))
	_chk(r, "an orthographic pass (a shadow cascade) faces along the camera's back axis",
			src.contains("PROJECTION_MATRIX[3][3] > 0.5") and src.contains("INV_VIEW_MATRIX[2].xyz"))
	return r
