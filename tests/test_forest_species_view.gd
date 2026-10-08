# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The species' 3D view, headless: the camera orbits its target at its distance; a built species is drawn as the forest
## draws it, a level at a time; the alpha cut moves the leaves only; the trunk ring follows the trunk radius (none at 0);
## the card modes say why there is no card (none baked, a bush) or that it is the last bake's; Compare shows both views;
## Sheets the two sheets; a missing mesh draws nothing and says so; the view's sheet cell is the baker's; the dialog keeps
## one view across rebuilds and frees it with its world when it closes.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const ViewRes := preload("res://addons/wuifwoud/editor/species/forest_species_view.gd")
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
const BakerRes := preload("res://addons/wuifwoud/species/forest_impostor_baker.gd")
const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const ROOT := "user://wf_e1_view"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_species_view", "passed": 0, "failed": 0, "details": []}
	var t := ViewRes.orbit(35.0, 18.0, 20.0, Vector3(0, 5, 0))
	_chk(r, "orbit: at its distance, looking at its target",
		is_equal_approx(t.origin.distance_to(Vector3(0, 5, 0)), 20.0)
		and (-t.basis.z).angle_to(Vector3(0, 5, 0) - t.origin) < 1e-4 and t.origin.y > 5.0)
	var fx := Fix.make(ROOT)
	var pack: ForestSpeciesPack = fx["fixture"]
	var dir := pack.built_dir()
	var man := BuildRes.read_manifest(dir)
	var v = ViewRes.new()
	v.show_species(pack.species[0], dir, man, "built")
	var model := v.find_child("Model", true, false) as MeshInstance3D
	_chk(r, "a built species drawn as the forest draws it", model != null and model.mesh == v.levels()[0] and v.tris(0) > 0)
	v.set_alpha_cut(0.2)
	var c: ArrayMesh = v.parts["combined"]
	_chk(r, "the alpha cut moves the leaves only",
		is_equal_approx(float((c.surface_get_material(1) as ShaderMaterial).get_shader_parameter("alpha_cut")), 0.2)
		and is_equal_approx(float((c.surface_get_material(0) as ShaderMaterial).get_shader_parameter("alpha_cut")), 0.0))
	v.set_trunk(0.5)
	var ring := v.find_child("Ring", true, false) as MeshInstance3D
	_chk(r, "the trunk ring at the trunk radius", ring.visible and is_equal_approx((ring.mesh as CylinderMesh).top_radius, 0.5))
	v.set_trunk(0.0)
	_chk(r, "no ring at 0", not ring.visible)
	v.set_mode("card")
	_chk(r, "Card without a bake: why, and no card", v.card_note() == "Build to make the card."
		and not (v.find_child("Card", true, false) as MeshInstance3D).visible
		and (v.find_child("Note", true, false) as Label).text == "Build to make the card.")
	v.parts["ring"] = {"albedo": ImageTexture.create_from_image(Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)),
		"normal": ImageTexture.create_from_image(Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)),
		"grid": 8, "cols": 8, "rows": 8, "span": 10.0, "w": 5.0, "h": 9.0}
	v._state = "needs"
	v._place()
	_chk(r, "a stale bake: its card, said to be the last bake's",
		(v.find_child("Card", true, false) as MeshInstance3D).visible and v.card_note().begins_with("Changed since the bake"))
	v.set_mode("compare")
	_chk(r, "Compare shows both views", (v.find_child("Right", true, false) as Control).visible)
	v.set_mode("sheets")
	var sheets := v.find_child("Sheets", true, false) as Control
	_chk(r, "Sheets: the albedo and the normal sheet", sheets.visible and sheets.find_children("*", "TextureRect", true, false).size() == 2)
	_chk(r, "the sheet cell is the baker's for the camera's direction",
		v.view_cell() == BakerRes.view_cell((v._cam_l.transform.origin - v._target()).normalized()))
	v.set_mode("model")
	v.show_species(pack.species[1], dir, man, "unbuilt")
	_chk(r, "an unbuilt species is prepared and drawn", (v.find_child("Model", true, false) as MeshInstance3D).mesh != null)
	v.show_species(pack.species[2], dir, man, "unbuilt")
	v.set_mode("card")
	_chk(r, "a bush has no card", v.card_note() == "A bush has no card.")
	v.show_species(pack.species[3], dir, man, "missing")
	_chk(r, "a missing mesh draws nothing and says so",
		(v.find_child("Model", true, false) as MeshInstance3D).mesh == null and v.card_note() == "Nothing to draw: the mesh is missing.")
	v.free()

	# ── the dialog keeps one view ──
	var made: Array = Fix.dialog(fx)
	var d = made[0]
	d.select("W_Tree")
	var first = d.view
	d.rebuild()
	_chk(r, "one view across rebuilds", first != null and is_same(d.view, first) and first.get_parent() != null)
	var ref := weakref(first)
	d.close()
	if not d.is_queued_for_deletion():
		d.free()
	_chk(r, "freed with its world when the dialog closes", ref.get_ref() == null or (ref.get_ref() as Node).is_queued_for_deletion())
	Fix.TreeFix.rm_tree(ROOT)
	return r
