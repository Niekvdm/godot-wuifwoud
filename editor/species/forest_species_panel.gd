# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Species dialog's right column: the selected species, its name and id, its state and its Build. (The settings, the
## files, what uses it, the switch and the 3D view join it.)

## The tile's caption rule.
const TileCaption := preload("res://addons/wuifwoud/editor/common/forest_species_tile.gd")


## The column for the dialog `d`.
static func build(d) -> Control:
	var v := VBoxContainer.new()
	v.name = "Species"
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 6)
	var row: Dictionary = d.row_of(d.selected) if d.selected != "" else {}
	if row.is_empty():
		v.add_child(d.hint("Select a species."))
		return v
	var sp = row["s"]
	var head := HBoxContainer.new()
	head.name = "Head"
	head.add_theme_constant_override("separation", 8)
	var nm := Label.new()
	nm.name = "SpeciesName"
	nm.text = TileCaption.caption(sp)
	nm.add_theme_font_size_override("font_size", 15)
	head.add_child(nm)
	var id := Label.new()
	id.name = "SpeciesId"
	id.text = String(sp.id)
	id.modulate = d.DIM
	id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(id)
	var st := Label.new()
	st.name = "State"
	st.text = state_text(row)
	st.add_theme_color_override("font_color", state_colour(d, String(row["state"])))
	head.add_child(st)
	var b: Button = d.kit.chip("Build", false, d.accent)
	b.name = "BuildSpecies"
	b.disabled = d.busy() or String(row["state"]) == "missing" or String(row["dir"]) == ""
	b.pressed.connect(d.build_species.bind(String(sp.id)))
	head.add_child(b)
	var on := CheckButton.new()
	on.name = "Enabled"
	on.button_pressed = not d.config.disabled_species.has(String(sp.id))
	on.focus_mode = Control.FOCUS_NONE
	on.tooltip_text = "Grow this species"
	on.toggled.connect(func(t: bool) -> void: d.set_species_enabled(String(sp.id), t))
	head.add_child(on)
	v.add_child(head)
	if not d.asking.is_empty():
		var q: PanelContainer = d.kit.banner(String(d.asking["text"]), String(d.asking.get("action", "")), d.ERROR)
		q.name = "Question"
		(q.find_child("Action", true, false) as Button).pressed.connect(d.confirm_question)
		var keep: Button = d.kit.chip("Keep it", false, d.accent)
		keep.name = "KeepIt"
		keep.pressed.connect(d.cancel_question)
		q.get_child(0).add_child(keep)
		v.add_child(q)
	if not bool(row["enabled"]):
		v.add_child(d.hint("Its pack is switched off: it grows nowhere."))
	var used: PackedStringArray = d.uses_of(String(sp.id))
	v.add_child(d.kit.section("Used by"))
	var ul: Label = d.hint("\n".join(used) if not used.is_empty() else
		("Switched off: it grows nowhere." if d.config.disabled_species.has(String(sp.id)) else "Nothing in this scene's forest."))
	ul.name = "UsedBy"
	v.add_child(ul)
	return v


## "built", "needs building: <why>", "not built", "mesh missing: <why>".
static func state_text(row: Dictionary) -> String:
	var t: String = {"built": "built", "needs": "needs building", "unbuilt": "not built",
		"missing": "mesh missing"}.get(String(row["state"]), String(row["state"]))
	var why := String(row.get("why", ""))
	return t + (": " + why if why != "" and why != t and String(row["state"]) != "built" else "")


## The colour a state is said in: built green, a missing mesh red, the rest amber.
static func state_colour(d, state: String) -> Color:
	match state:
		"built":
			return d.GOOD
		"missing":
			return d.ERROR
	return d.AMBER
