# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The dialogs' building blocks: ForestKit gives the overlay's components when installed and plain controls with the same
## names and children when not (a slider row, a switch row, a segmented choice, a banner, a dropdown, a menu chip, a
## tile); ForestPictures gives a species' built picture, else its crown's glyph, and forgets on asking; the species tile
## names it, dots it (on, off and dimmed), badges its state, folds a bush, and drags its id.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const KitRes := preload("res://addons/wuifwoud/editor/common/forest_kit.gd")
const PicturesRes := preload("res://addons/wuifwoud/editor/common/forest_pictures.gd")
const TileRes := preload("res://addons/wuifwoud/editor/common/forest_species_tile.gd")
const ROOT := "user://wf_e1_tile"
const ACC := Color("8bc34a")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _sp(id: String, kind := "tree", crown := "broadleaf", display := "") -> ForestSpecies:
	var s := ForestSpecies.new()
	s.id = id
	s.kind = kind
	s.crown = crown
	s.display_name = display
	return s


static func run() -> Dictionary:
	var r := {"name": "forest_species_tile", "passed": 0, "failed": 0, "details": []}
	# ── the plain kit ──
	var k = KitRes.new(null)
	var sr: VBoxContainer = k.slider_row("Trunk radius", 0.0, 3.0, 0.01, 0.32, "m", ACC)
	_chk(r, "plain: a slider row's children and value (%s)" % (sr.get_node("Head/Value") as Label).text,
		(sr.get_node("Head/Value") as Label).text == "0.32 m" and is_equal_approx((sr.get_node("Slider") as HSlider).value, 0.32))
	sr.free()
	var tr: HBoxContainer = k.toggle_row("Young", true, ACC)
	_chk(r, "plain: a switch row", (tr.get_node("Toggle") as CheckBox).button_pressed and (tr.get_node("Label") as Label).text == "Young")
	tr.free()
	var hit := [-1]
	var sg: HBoxContainer = k.segmented(["Tree", "Bush"], 1, ACC, func(i: int) -> void: hit[0] = i)
	(sg.get_node("Seg0") as Button).pressed.emit()
	_chk(r, "plain: a segmented choice", (sg.get_node("Seg1") as Button).button_pressed and hit[0] == 0)
	sg.free()
	var bn: PanelContainer = k.banner("It is used", "Disable", ACC)
	_chk(r, "plain: a banner", bn.find_child("Text", true, false) != null and (bn.find_child("Action", true, false) as Button).text == "Disable")
	bn.free()
	var dd: OptionButton = k.dropdown(["A", "B"], 1, ACC, func(i: int) -> void: hit[0] = i)
	dd.item_selected.emit(0)
	_chk(r, "plain: a dropdown", dd.item_count == 2 and dd.selected == 1 and hit[0] == 0)
	dd.free()
	var mc: MenuButton = k.menu_chip("⋯", [{"id": 3, "text": "Build"}], ACC, func(id: int) -> void: hit[0] = id)
	mc.get_popup().id_pressed.emit(3)
	_chk(r, "plain: a menu chip", mc.get_popup().item_count == 1 and hit[0] == 3)
	mc.free()
	var tl: Button = k.tile(null, "Oak", ACC, 70)
	_chk(r, "plain: a tile names its item", (tl.get_node("Name") as Label).text == "Oak" and tl.custom_minimum_size == Vector2(70, 70))
	tl.free()
	_chk(r, "value_text as the overlay's", KitRes.value_text(40.0, 0.5, "m") == "40.0 m" and KitRes.value_text(3.0, 1.0, "") == "3")

	# ── the overlay's kit, when installed ──
	var ux = KitRes.overlay()
	if ux != null:
		var ko = KitRes.new(ux)
		var ch: Button = ko.chip("Build", false, ACC)
		_chk(r, "with the overlay: its components (a 22 px chip)", ko.has("chip") and ch.custom_minimum_size.y == 22.0)
		ch.free()
	else:
		_chk(r, "no overlay here: plain controls only", not KitRes.new(null).has("chip"))

	# ── pictures ──
	PicturesRes.forget()
	var oak := _sp("W_Oak")
	var g: Texture2D = PicturesRes.of(oak, "")
	_chk(r, "no picture: its crown's glyph", g != null and g == PicturesRes.glyph("broadleaf") and not PicturesRes.has_picture(oak, ""))
	_chk(r, "a bush's glyph is the bush; a palm's the palm",
		PicturesRes.glyph_name(_sp("b", "bush", "palm")) == "bush" and PicturesRes.glyph_name(_sp("p", "tree", "palm")) == "palm")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	var img := Image.create_empty(256, 256, false, Image.FORMAT_RGBA8)
	ResourceSaver.save(img, PicturesRes.picture_path(ROOT, "W_Oak"))
	_chk(r, "cached until forgotten", PicturesRes.of(oak, ROOT) != null)
	PicturesRes.forget()
	var pic: Texture2D = PicturesRes.of(oak, ROOT)
	_chk(r, "a built picture once forgotten and asked again", pic != null and pic.get_width() == 256 and PicturesRes.has_picture(oak, ROOT))

	# ── the tile ──
	var t = TileRes.new().setup(k, _sp("W_Fir_06", "tree", "conifer"), "", "needs", true, true, ACC)
	_chk(r, "a tile: its caption, its badge, a green dot",
		(t.get_node("Name") as Label).text == "W Fir 06" and (t.get_node("Badge") as Label).text == "build"
		and ((t.get_node("Dot") as Panel).get_theme_stylebox("panel") as StyleBoxFlat).bg_color == TileRes.ON)
	_chk(r, "a tile drags its id", t._get_drag_data(Vector2.ZERO) == {"kind": TileRes.KIND, "id": "W_Fir_06"})
	var acts := [0]
	t.activated.connect(func() -> void: acts[0] += 1)
	var dbl := InputEventMouseButton.new()
	dbl.button_index = MOUSE_BUTTON_LEFT
	dbl.pressed = true
	dbl.double_click = true
	t._gui_input(dbl)
	_chk(r, "a double click activates it", acts[0] == 1)
	t.free()
	var off = TileRes.new().setup(k, _sp("W_B", "bush", "broadleaf", "Holly"), "", "missing", false, false, ACC)
	_chk(r, "switched off: dimmed, a hollow dot; a missing mesh's badge; a bush's fold; its display name",
		is_equal_approx(off.modulate.a, TileRes.OFF_ALPHA) and (off.get_node("Badge") as Label).text == "mesh missing"
		and off.get_node_or_null("Fold") != null and (off.get_node("Name") as Label).text == "Holly"
		and ((off.get_node("Dot") as Panel).get_theme_stylebox("panel") as StyleBoxFlat).bg_color.a == 0.0)
	off.free()
	_chk(r, "a built species wears no badge", TileRes.badge_of("built") == "")
	PicturesRes.forget()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PicturesRes.picture_path(ROOT, "W_Oak")))
	return r
