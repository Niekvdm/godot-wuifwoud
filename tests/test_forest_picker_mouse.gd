# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The species picker under the mouse, as the editor drives it (pressed, moved and released through a viewport that
## holds its popups, the controls laid out, under a canvas layer moved by OFFSET: something between a panel and the
## screen): a click on the face opens the popover right under it; a tile clicked there picks its species and closes it;
## an owner that rebuilds on a pick (the Tree and Row panel, the Import dialog) gets a picker that opens and picks again,
## with no engine error; a long list keeps the popover's size, its grid scrolling.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const PickerRes := preload("res://addons/wuifwoud/editor/common/forest_species_picker.gd")
const PicturesRes := preload("res://addons/wuifwoud/editor/common/forest_pictures.gd")
const KitRes := preload("res://addons/wuifwoud/editor/common/forest_kit.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const ROOT := "user://wf_e3_picker_mouse"
const OFFSET := Vector2(300, 200)


## The engine's errors (not its warnings) while the picker is driven.
class Caught extends Logger:
	var lines: Array[String] = []
	var _mx := Mutex.new()

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		_mx.lock()
		lines.append(rationale if rationale != "" else code)
		_mx.unlock()


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


static func _move(vp: SubViewport, at: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = at
	ev.global_position = at
	vp.push_input(ev, true)


## A click at `at` (the viewport's coordinates): moved there, pressed, and a frame later released.
static func _click(vp: SubViewport, at: Vector2) -> void:
	_move(vp, at)
	_button(vp, at, true)
	await _frames(1)
	_button(vp, at, false)
	await _frames(2)


## Where a control in the popover `pop` is, in the viewport's coordinates (the popover is a window of its own).
static func _in_pop(pop: PopupPanel, c: Control) -> Vector2:
	return Vector2(pop.position) + c.get_global_rect().get_center()


static func run() -> Dictionary:
	var r := {"name": "forest_picker_mouse", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	VA.use_packs([fx["fixture"], fx["other"]], PackedStringArray(["W_Other"]))
	var caught := Caught.new()
	OS.add_logger(caught)
	var vp := SubViewport.new()
	vp.size = Vector2i(1600, 1000)
	vp.gui_embed_subwindows = true
	(Engine.get_main_loop() as SceneTree).root.add_child(vp)
	var layer := CanvasLayer.new()
	layer.offset = OFFSET
	vp.add_child(layer)
	var host := VBoxContainer.new()
	host.position = Vector2(40, 40)
	host.custom_minimum_size = Vector2(260, 0)
	layer.add_child(host)
	var offered: PackedStringArray = PickerRes.choices(PackedStringArray())
	var got := []
	var pk = PickerRes.new().setup(KitRes.new(null), "", offered, Color.WHITE)
	pk.picked.connect(func(id: String) -> void: got.append(id))
	host.add_child(pk)
	await _frames(3)
	# ── the face clicked ──
	var face: Control = pk
	var under: Vector2 = OFFSET + face.get_global_rect().position + Vector2(0.0, face.size.y)
	await _click(vp, OFFSET + face.get_global_rect().get_center())
	var pop: PopupPanel = pk.find_child("SpeciesPop", true, false)
	_chk(r, "a click on the face opens the popover right under it (%s; wanted %s)" % [
		str(pop.position) if pop != null else "none", str(under)],
		pop != null and pop.visible and Vector2(pop.position).distance_to(under) < 2.0)
	# ── a tile clicked ──
	var tile := pk.find_child("Species_W_Tree", true, false) as Control
	if pop != null and tile != null:
		await _click(vp, _in_pop(pop, tile))
	_chk(r, "a tile clicked picks its species and closes the popover (%s)" % str(got),
		got == ["W_Tree"] and pop != null and not pop.visible and String(pk.text) == "W Tree ▾")
	host.remove_child(face)
	face.queue_free()
	# ── an owner that rebuilds on a pick ──
	var made := []
	var hold := [Callable()]
	hold[0] = func(id: String) -> void:
		got.append(id)
		var old: Node = made[-1]
		host.remove_child(old)
		old.queue_free()
		var np = PickerRes.new().setup(KitRes.new(null), id, offered, Color.WHITE)
		np.picked.connect(hold[0])
		host.add_child(np)
		made.append(np)
	var first = PickerRes.new().setup(KitRes.new(null), "", offered, Color.WHITE)
	first.picked.connect(hold[0])
	host.add_child(first)
	made.append(first)
	await _frames(2)
	await _click(vp, OFFSET + (first as Control).get_global_rect().get_center())
	var p1: PopupPanel = first.find_child("SpeciesPop", true, false)
	var t1 := first.find_child("Species_W_Bush", true, false) as Control
	if p1 != null and t1 != null:
		await _click(vp, _in_pop(p1, t1))
	await _frames(2)
	var second: Control = made[-1]
	await _click(vp, OFFSET + second.get_global_rect().get_center())
	var p2: PopupPanel = second.find_child("SpeciesPop", true, false)
	var t2 := second.find_child("SpeciesBy", true, false) as Control
	if p2 != null and t2 != null:
		await _click(vp, _in_pop(p2, t2))
	await _frames(2)
	_chk(r, "an owner that rebuilds on a pick: the new picker opens and picks again, and no engine error (%s; %s)" % [
		str(got), str(caught.lines)],
		got == ["W_Tree", "W_Bush", ""] and made.size() == 3 and String(made[-1].current) == ""
		and caught.lines.is_empty())
	# ── a long list ──
	var many := PackedStringArray()
	for i in 60:
		many.append("W_L%02d" % i)
	var big = PickerRes.new().setup(KitRes.new(null), "", many, Color.WHITE, "Big")
	host.add_child(big)
	await _frames(2)
	await _click(vp, OFFSET + (big as Control).get_global_rect().get_center())
	var bp: PopupPanel = big.find_child("BigSpeciesPop", true, false)
	var grid := big.find_child("BigSpeciesGrid", true, false) as Control
	var sc := big.find_child("BigSpeciesScroll", true, false) as Control
	_chk(r, "a long list (60) keeps the popover's size, its grid scrolling (%s; grid %s, scroll %s)" % [
		str(bp.size) if bp != null else "none", str(grid.size) if grid != null else "none",
		str(sc.size) if sc != null else "none"],
		bp != null and bp.visible and bp.size == PickerRes.POP_SIZE and grid != null and sc != null
		and grid.get_child_count() == 61 and grid.size.y > sc.size.y)
	if bp != null:
		bp.hide()
	OS.remove_logger(caught)
	vp.queue_free()
	await _frames(1)
	PicturesRes.forget()
	VA.forget_packs()
	VA.reset()
	Fix.TreeFix.rm_tree(ROOT)
	return r
