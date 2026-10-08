# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The Types dialog under the mouse, as the editor drives it (pressed, moved and released through a viewport, the
## controls laid out): a lane tile clicked shows its weight; a type row's ≡ dragged onto another row moves that type; a
## lane tile dragged onto another lane moves it there; a click on a row's empty part selects it.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/types_fixture.gd")
const ROOT := "user://wf_e2_types_mouse"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _frames(n: int) -> void:
	for i in n:
		await (Engine.get_main_loop() as SceneTree).process_frame


static func _button(vp: SubViewport, at: Vector2, down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = down
	ev.position = at
	ev.global_position = at
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	vp.push_input(ev, true)


## A move to `at` by `rel` (a drag starts once the moves' `relative` add up past the threshold).
static func _move(vp: SubViewport, at: Vector2, held: bool, rel := Vector2.ZERO) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = at
	ev.global_position = at
	ev.relative = rel
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	vp.push_input(ev, true)


## A click at `at`: the press and, a frame later, the release.
static func _click(vp: SubViewport, at: Vector2) -> void:
	_move(vp, at, false)
	_button(vp, at, true)
	await _frames(1)
	_button(vp, at, false)
	await _frames(2)


## A drag from `from` to `to`, a frame a step, released there.
static func _drag(vp: SubViewport, from: Vector2, to: Vector2) -> void:
	_move(vp, from, false)
	_button(vp, from, true)
	await _frames(1)
	var at := from
	for i in range(1, 9):
		var next := from.lerp(to, float(i) / 8.0)
		_move(vp, next, true, next - at)
		at = next
		await _frames(1)
	_button(vp, to, false)
	await _frames(2)


static func _centre(d: Node, path: Array) -> Vector2:
	var n: Node = d
	for nm in path:
		n = n.find_child(String(nm), true, false) if n != null else null
	return (n as Control).get_global_rect().get_center() if n is Control else Vector2(-1, -1)


static func _disk_ids(path: String) -> Array:
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	var types: Array = v.get("types", []) if v is Dictionary else []
	return types.filter(func(t): return t is Dictionary and t.has("id")).map(func(t): return int(t["id"]))


static func _mixes(path: String, id: int) -> Dictionary:
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	for t in (v.get("types", []) if v is Dictionary else []):
		if t is Dictionary and t.has("id") and int(t["id"]) == id:
			return t.get("mixes", {})
	return {}


static func run() -> Dictionary:
	var r := {"name": "forest_types_mouse", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	var made: Array = Fix.dialog(fx)
	var d = made[0]
	var path: String = fx["profile"]
	var vp := SubViewport.new()
	vp.size = Vector2i(1600, 1000)
	(Engine.get_main_loop() as SceneTree).root.add_child(vp)
	vp.add_child(d)
	await _frames(3)
	# ── a lane tile clicked ──
	await _click(vp, _centre(d, ["Drop_coast", "LaneTile_W_Tree"]))
	_chk(r, "a lane tile clicked shows its weight (picked %s)" % str(d.lane_pick),
		String(d.lane_pick.get("id", "")) == "W_Tree" and d.find_child("Weight", true, false) != null)
	# ── a row's ≡ dragged onto another row ──
	await _drag(vp, _centre(d, ["Type_7", "Handle"]), _centre(d, ["Type_1"]))
	_chk(r, "a type row's ≡ dragged onto another row moves that type (%s)" % str(_disk_ids(path)),
		_disk_ids(path) == [7, 1, 2, 3, 4])
	# ── a lane tile dragged onto another lane ──
	d.select(1)
	await _frames(2)
	await _drag(vp, _centre(d, ["Drop_coast", "LaneTile_W_Other"]), _centre(d, ["Drop_mid"]))
	var mid: Array = _mixes(path, 1).get("mid", [])
	_chk(r, "a lane tile dragged onto another lane moves there (%s)" % str(mid),
		mid.any(func(e): return e is Array and str(e[0]) == "W_Other"))
	# ── a click on a row's empty part ──
	await _click(vp, _centre(d, ["Type_2", "Name"]))
	_chk(r, "a click on a row selects it", d.selected == 2)
	vp.queue_free()
	await _frames(1)
	Fix.clean(ROOT)
	return r
