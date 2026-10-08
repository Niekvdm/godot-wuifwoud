# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The selected type's settings: its name, style and numbers, the far colour from the bake, a footer of what it grows
## and the rules that paint it; a name written on Enter, an empty one refused; a slider let go written and undone; a
## share shown in % written 0-1; an icon picked (the list's tile follows) and taken out; a colour; the far colour off and
## back on the bake; Grid shows the pitch; a mix and a bushes type their own numbers; an edit handed over during a
## rebuild is applied after it; the Defaults row says who inherits it.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/types_fixture.gd")
const ROOT := "user://wf_e2_type_panel"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## Type `id` as it is on disk ({}: none).
static func _on_disk(path: String, id: int) -> Dictionary:
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	for t in (v.get("types", []) if v is Dictionary else []):
		if t is Dictionary and t.has("id") and int(t["id"]) == id:
			return t
	return {}


static func _text(n: Node, nm: String) -> String:
	if n == null:
		return ""
	var l := n.find_child(nm, true, false) as Label
	return l.text if l != null else ""


static func _slider(d: Node, nm: String) -> HSlider:
	var row: Node = d.find_child(nm, true, false)
	return row.get_node("Slider") as HSlider if row != null else null


static func run() -> Dictionary:
	var r := {"name": "forest_type_panel", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	var made: Array = Fix.dialog(fx)
	var d = made[0]
	var pl = made[1]
	var path: String = fx["profile"]
	pl.rules = [{"match": {}, "type": 1}]
	d.select(1)
	var name_field := d.find_child("TypeName", true, false) as LineEdit
	var style: Node = d.find_child("Style", true, false)
	_chk(r, "Wood's panel: its name, Natural, its numbers, the far colour from the bake",
		name_field != null and name_field.text == "Wood" and (style.get_node("Seg0") as Button).button_pressed
		and _slider(d, "Density") != null and _slider(d, "DeadShare") != null and _slider(d, "WallMult") != null
		and (d.find_child("FarFromBake", true, false) as Button).button_pressed)
	_chk(r, "the footer: what it grows and the rules that paint it (%s)" % _text(d, "Footer"),
		_text(d, "Footer") == "One tree every 5.0 m · painted by import rule 1")
	name_field.text = "Old wood"
	name_field.text_submitted.emit("Old wood")
	_chk(r, "a name written on Enter", _on_disk(path, 1).get("name") == "Old wood")
	(d.find_child("TypeName", true, false) as LineEdit).text_submitted.emit("   ")
	_chk(r, "an empty name refused, said, not written (%s)" % d.error, d.error != ""
		and _on_disk(path, 1).get("name") == "Old wood")
	var clump := _slider(d, "Clump")
	clump.value = 0.8
	clump.drag_ended.emit(true)
	_chk(r, "a slider let go writes", is_equal_approx(float(_on_disk(path, 1).get("clump", 0.0)), 0.8))
	d.undo()
	_chk(r, "undo writes it back", is_equal_approx(float(_on_disk(path, 1).get("clump", 0.0)), 0.5))
	var dead := _slider(d, "DeadShare")
	dead.value = 10.0
	dead.drag_ended.emit(true)
	_chk(r, "a share shown in % is written 0-1", is_equal_approx(float(_on_disk(path, 1).get("dead_frac", 0.0)), 0.1))
	(d.find_child("IconPick", true, false) as OptionButton).item_selected.emit(1)
	var row_icon: Node = d.find_child("Type_1", true, false).find_child("Icon", true, false)
	_chk(r, "an icon picked is written, and the list's tile wears it",
		_on_disk(path, 1).get("icon") == "conifer" and row_icon != null and row_icon.get_meta("icon") == "conifer")
	(d.find_child("IconPick", true, false) as OptionButton).item_selected.emit(0)
	_chk(r, "By style takes it out again", not _on_disk(path, 1).has("icon"))
	var cp := d.find_child("Colour", true, false) as ColorPickerButton
	cp.color = Color("aa3300")
	cp.popup_closed.emit()
	_chk(r, "a colour picked is written #rrggbb", _on_disk(path, 1).get("colour") == "#aa3300")
	(d.find_child("FarFromBake", true, false) as Button).toggled.emit(false)
	_chk(r, "the far colour off the bake writes the picker's colour",
		String(_on_disk(path, 1).get("far_color", "")).begins_with("#"))
	(d.find_child("FarFromBake", true, false) as Button).toggled.emit(true)
	_chk(r, "back on the bake takes it out", not _on_disk(path, 1).has("far_color"))
	(d.find_child("Style", true, false).get_node("Seg2") as Button).pressed.emit()
	_chk(r, "Grid: written; the panel shows the pitch, not the forest's numbers", _on_disk(path, 1).get("style") == "grid"
		and _slider(d, "Pitch") != null and _slider(d, "Clump") == null)
	d.undo()
	d.select(3)
	_chk(r, "a mix: density and tree share", _slider(d, "TreeShare") != null and _slider(d, "Density") != null
		and _slider(d, "Clump") == null)
	d.select(2)
	_chk(r, "bushes: density and clump; the footer says bushes (%s)" % _text(d, "Footer"),
		_slider(d, "Clump") != null and _slider(d, "Understory") == null and _text(d, "Footer").begins_with("One bush every"))
	# ── a field's edit made while the dialog rebuilds is kept ──
	d._rebuilding = true
	d.set_value(2, "name", "Heath")
	d._rebuilding = false
	d._apply_pending()
	_chk(r, "an edit handed over during a rebuild is applied after it", _on_disk(path, 2).get("name") == "Heath")
	d.select(0)
	_chk(r, "the Defaults row: what it is and who inherits it (%s)" % _text(d, "Inheritors"),
		_text(d, "Title") == "Defaults (every type)" and _text(d, "Inheritors").contains("Old wood (mid, high, bush)"))
	d.free()
	Fix.clean(ROOT)
	return r
