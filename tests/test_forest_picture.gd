# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The species picture, headless: the camera frames the whole tree (every corner of its bounds inside the view); the
## stored picture is box-filtered in premultiplied alpha (a half-covered texel keeps its colour) and PX square; a baked
## pack's species without a picture needs building, as does one whose picture file is gone; a removed species' picture
## goes with it. The picture itself (rendered, the same bytes in two folders) is the windowed suite's.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const PictureRes := preload("res://addons/wuifwoud/species/forest_picture.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const TreeFix := preload("res://addons/wuifwoud/tests/fixtures/tree_fixture.gd")
const ROOT := "user://wf_e1_picture"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_picture", "passed": 0, "failed": 0, "details": []}
	# ── the framing ──
	var ab := AABB(Vector3(-2.0, 0.0, -1.5), Vector3(4.0, 11.0, 3.0))
	var t := PictureRes.camera_for(ab)
	var fwd := -t.basis.z
	var half := deg_to_rad(PictureRes.FOV_DEG) * 0.5 + 1e-4
	var inside := true
	for i in 8:
		var corner := ab.get_endpoint(i)
		inside = inside and fwd.angle_to(corner - t.origin) <= half
	_chk(r, "the camera frames every corner of the tree's bounds", inside)
	_chk(r, "from above the horizon, looking at the tree's centre",
		t.origin.y > ab.get_center().y and fwd.angle_to(ab.get_center() - t.origin) < 1e-3)

	# ── the stored picture ──
	var src := Image.create_empty(PictureRes.RENDER_PX, PictureRes.RENDER_PX, false, Image.FORMAT_RGBA8)
	for y in src.get_height():
		for x in src.get_width():
			src.set_pixel(x, y, Color(1, 0, 0, 1) if x % 2 == 0 else Color(0, 0, 0, 0))
	var out := PictureRes.finish(src)
	var px := out.get_pixel(10, 10)
	_chk(r, "PX square, a half-covered texel keeps its colour (%s)" % str(px),
		out.get_width() == PictureRes.PX and out.get_height() == PictureRes.PX
		and absf(px.a - 0.5) < 1.5 / 255.0 and px.r > 0.98 and px.g < 0.02)
	_chk(r, "no render, no picture", PictureRes.finish(null) == null)

	# ── built.json asks for it ──
	TreeFix.rm_tree(ROOT)
	TreeFix.scene(ROOT + "/m/tree.tscn", [TreeFix.tree_mesh(4, "Bark", "Leaves")], ["Tree"])
	var p := ForestSpeciesPack.new()
	var sl: Array[ForestSpecies] = [TreeFix.species("W_A", ROOT + "/m/tree.tscn"), TreeFix.species("W_B", ROOT + "/m/tree.tscn")]
	p.species = sl
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/pack"))
	ResourceSaver.save(p, ROOT + "/pack/pack.tres")
	var pack := ResourceLoader.load(ROOT + "/pack/pack.tres", "", ResourceLoader.CACHE_MODE_REPLACE) as ForestSpeciesPack
	BuildRes.new([pack]).run_now()
	var dir := pack.built_dir()
	var man := BuildRes.read_manifest(dir)
	_chk(r, "an unbaked build (the tests', the command line without a bake) asks for no picture",
		String(BuildRes.state_of(pack.species[0], dir, man)["state"]) == "built")
	var baked := man.duplicate(true)
	baked["bake"] = {"grid": 8}
	var st := BuildRes.state_of(pack.species[0], dir, baked)
	_chk(r, "a baked pack's species without a picture needs building (%s)" % str(st),
		String(st["state"]) == "needs" and String(st["why"]) == "it has no picture yet")
	baked["species"]["W_A"]["picture"] = true
	st = BuildRes.state_of(pack.species[0], dir, baked)
	_chk(r, "one whose picture file is gone needs building (%s)" % str(st),
		String(st["state"]) == "needs" and String(st["why"]) == "its picture is gone")
	var pic := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	ResourceSaver.save(pic, dir.path_join("W_A_picture.res"))
	_chk(r, "with its picture it is built", String(BuildRes.state_of(pack.species[0], dir, baked)["state"]) == "built")

	# ── a removed species' picture goes with it ──
	ResourceSaver.save(pic, dir.path_join("W_B_picture.res"))
	var one: Array[ForestSpecies] = [pack.species[0]]
	pack.species = one
	var rep: Dictionary = BuildRes.new([pack]).run_now()
	_chk(r, "a species taken out of its pack: its built files and picture removed (%s)" % str(rep.get("removed")),
		rep.get("removed") == ["W_B"] and not FileAccess.file_exists(dir.path_join("W_B_picture.res")))
	TreeFix.rm_tree(ROOT)
	return r
