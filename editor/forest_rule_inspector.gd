# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Rules tab's right column: the selected rule, its type (the profile's types and No
## forest; a type the profile lacks shown, so the rule can be moved off it), its match (a line a key; every key must
## match; ✕ takes a value out), Density and Age, and for points and lines Spacing, Clearance and the species
## (written on release), and Delete.

## Errors.
const ERROR := Color("ff8a80")


## The inspector of rule `i` for the dialog `d`.
static func build(d, i: int) -> Control:
	var sc := ScrollContainer.new()
	sc.name = "InspectorScroll"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := VBoxContainer.new()
	v.name = "Inspector"
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	sc.add_child(v)
	if i < 0 or i >= d.mapping.rules().size():
		v.add_child(d.kit.section("Rule"))
		v.add_child(d.hint("Select a rule, or drop a value on \"a new rule\"."))
		return sc
	var r: Dictionary = d.mapping.rules()[i]
	v.add_child(d.kit.section("Rule %d · type" % (i + 1)))
	v.add_child(_types(d, i, int(r.get("type", 0))))
	v.add_child(d.kit.section("Match"))
	v.add_child(_match(d, i, r))
	v.add_child(_slider(d, i, "density", "Density", 0.0, 1.0, float(r.get("density", 1.0))))
	v.add_child(_slider(d, i, "age", "Age", -1.0, 1.0, float(r.get("age", 0.0))))
	v.add_child(d.kit.section("Single trees and rows (points and lines)"))
	v.add_child(_slider(d, i, "spacing_m", "Spacing", 1.0, 50.0, float(r.get("spacing_m", 8.0)), 0.5, "m"))
	v.add_child(_slider(d, i, "clear_m", "Clearance", 0.0, 20.0, float(r.get("clear_m", 2.5)), 0.5, "m"))
	if r.has("clear_m"):
		var dflt: Button = d.kit.chip("Clearance by kind (3 m a tree, 2.5 m a row)", false, d.accent)
		dflt.name = "ClearDefault"
		dflt.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		dflt.pressed.connect(func() -> void: d.change(func() -> void: d.mapping.set_field(i, "clear_m", -1.0)))
		v.add_child(dflt)
	v.add_child(_species(d, i, str(r.get("species", ""))))
	var del: Button = d.kit.chip("Delete rule", false, ERROR)
	del.name = "DeleteRule"
	del.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	del.pressed.connect(func() -> void: _delete(d, i))
	v.add_child(del)
	return sc


static func _types(d, i: int, ty: int) -> Control:
	var flow := HFlowContainer.new()
	flow.name = "Types"
	var group := ButtonGroup.new()
	var ids: Array = [0]
	for t in d.types:
		ids.append(int(t["id"]))
	if not ids.has(ty):
		ids.append(ty)
	for id in ids:
		var text: String = d.type_name(id) if id == 0 or not d.has_type(id) else "%s (%d)" % [d.type_name(id), id]
		var b: Button = d.kit.toggle_chip(text, id == ty, d.accent)
		b.name = "Type%d" % id
		b.button_group = group
		b.icon = d.swatch(d.type_colour(id))
		if not d.has_type(id):
			b.add_theme_color_override("font_color", ERROR)
		var at: int = id
		b.pressed.connect(func() -> void: _set_type(d, i, at, ty))
		flow.add_child(b)
	return flow


static func _set_type(d, i: int, to: int, was: int) -> void:
	if to != was:
		d.change(func() -> void: d.mapping.set_field(i, "type", to))


static func _match(d, i: int, r: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.name = "Match"
	var mt: Dictionary = r.get("match", {})
	if mt.is_empty():
		v.add_child(d.hint("Matches nothing yet: drag values onto it from the left."))
	for k in mt:
		var h := HFlowContainer.new()
		h.name = "Key_" + String(k).validate_node_name()
		var kl := Label.new()
		kl.text = "%s:" % k
		h.add_child(kl)
		for val in d.mapping.values_of(i, String(k)):
			var b: Button = d.kit.chip("%s ✕" % val, false, d.accent)
			b.name = "Value_" + String(val).validate_node_name()
			b.tooltip_text = "Take %s out of this rule" % val
			var kk := String(k)
			var vv := String(val)
			b.pressed.connect(func() -> void: d.change(func() -> void: d.mapping.remove_value(i, kk, vv)))
			h.add_child(b)
		v.add_child(h)
	if mt.size() > 1:
		v.add_child(d.hint("Every key must match."))
	return v


static func _slider(d, i: int, field: String, label: String, lo: float, hi: float, value: float, step := 0.05,
		suffix := "") -> Control:
	var row: VBoxContainer = d.kit.slider_row(label, lo, hi, step, value, suffix, d.accent)
	row.name = label
	var s := row.get_node("Slider") as HSlider
	s.drag_ended.connect(func(changed: bool) -> void: _commit_slider(d, i, field, s, changed))
	return row


## A slider let go: its value written (one undo step).
static func _commit_slider(d, i: int, field: String, s: HSlider, changed: bool) -> void:
	if changed:
		var val := s.value
		d.change(func() -> void: d.mapping.set_field(i, field, val))


## The species a rule's points and lines grow: By type (the type picks) or one of the profile's.
static func _species(d, i: int, sp: String) -> Control:
	var flow := HFlowContainer.new()
	flow.name = "Species"
	var group := ButtonGroup.new()
	var by: Button = d.kit.toggle_chip("By type", sp == "", d.accent)
	by.name = "SpeciesBy"
	by.button_group = group
	by.pressed.connect(func() -> void: _set_species(d, i, "", sp))
	flow.add_child(by)
	for nm in d.species:
		var b: Button = d.kit.toggle_chip(String(nm), String(nm) == sp, d.accent)
		b.name = "Species_" + String(nm).validate_node_name()
		b.button_group = group
		var at := String(nm)
		b.pressed.connect(func() -> void: _set_species(d, i, at, sp))
		flow.add_child(b)
	return flow


static func _set_species(d, i: int, to: String, was: String) -> void:
	if to != was:
		d.change(func() -> void: d.mapping.set_field(i, "species", to))


static func _delete(d, i: int) -> void:
	d.selected = mini(i, d.mapping.rules().size() - 2)
	d.change(func() -> void: d.mapping.delete_rule(i))
