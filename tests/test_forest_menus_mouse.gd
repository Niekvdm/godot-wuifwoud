# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Right-click menus under the mouse: a species tile's and a drop target's `menu_requested` say where the mouse is on
## the screen, the coordinates a popup takes, not in their own canvas. Under a canvas layer moved by OFFSET (what a
## floating editor window adds between a control and the screen is the same kind of transform) the two differ, and the
## menu must open at the mouse.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const TileRes := preload("res://addons/wuifwoud/editor/common/forest_species_tile.gd")
const DropRes := preload("res://addons/wuifwoud/editor/common/forest_drop_target.gd")
const KitRes := preload("res://addons/wuifwoud/editor/common/forest_kit.gd")
const OFFSET := Vector2(300, 200)


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _frames(n: int) -> void:
	for i in n:
		await (Engine.get_main_loop() as SceneTree).process_frame


## A right click at `at` (the viewport's coordinates): moved there, pressed, released.
static func _right(vp: SubViewport, at: Vector2) -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = at
	mv.global_position = at
	vp.push_input(mv, true)
	for down in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_RIGHT
		ev.pressed = down
		ev.position = at
		ev.global_position = at
		ev.button_mask = MOUSE_BUTTON_MASK_RIGHT if down else 0
		vp.push_input(ev, true)
		await _frames(1)


static func run() -> Dictionary:
	var r := {"name": "forest_menus_mouse", "passed": 0, "failed": 0, "details": []}
	var vp := SubViewport.new()
	vp.size = Vector2i(1200, 800)
	vp.gui_embed_subwindows = true
	(Engine.get_main_loop() as SceneTree).root.add_child(vp)
	var layer := CanvasLayer.new()
	layer.offset = OFFSET
	vp.add_child(layer)
	var box := HBoxContainer.new()
	box.position = Vector2(100, 100)
	layer.add_child(box)
	var sp := ForestSpecies.new()
	sp.id = "W_Menu"
	var tile = TileRes.new().setup(KitRes.new(null), sp, "", "built", true, false, Color.WHITE, 70)
	box.add_child(tile)
	var drop = DropRes.new().setup([], Callable(), null, null)
	(drop as Control).custom_minimum_size = Vector2(120, 70)
	box.add_child(drop)
	await _frames(3)
	var got := {}
	tile.menu_requested.connect(func(at: Vector2) -> void: got["tile"] = at)
	drop.menu_requested.connect(func(at: Vector2) -> void: got["drop"] = at)
	var t_at: Vector2 = OFFSET + (tile as Control).get_global_rect().get_center()
	var d_at: Vector2 = OFFSET + (drop as Control).get_global_rect().get_center()
	await _right(vp, t_at)
	await _right(vp, d_at)
	var t_got: Vector2 = got.get("tile", Vector2(-1, -1))
	var d_got: Vector2 = got.get("drop", Vector2(-1, -1))
	_chk(r, "a species tile's right click asks for its menu where the mouse is on the screen (%s; the mouse at %s)" % [
		str(t_got), str(t_at)], t_got.distance_to(t_at) < 1.0)
	_chk(r, "a drop target's right click asks for its menu where the mouse is on the screen (%s; the mouse at %s)" % [
		str(d_got), str(d_at)], d_got.distance_to(d_at) < 1.0)
	vp.queue_free()
	await _frames(1)
	return r
