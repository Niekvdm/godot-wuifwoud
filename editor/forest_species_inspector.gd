# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends EditorInspectorPlugin
## A species or a species pack in the inspector: its built state (a species': built, needs building and why, mesh
## missing; a pack's: how many species need building) and "Open in the Species dialog", which opens the dialog on it.

## The pack build (its states).
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
## The species panel (its state words).
const PanelRes := preload("res://addons/wuifwoud/editor/species/forest_species_panel.gd")

## (id) -> void: the plugin opens the dialog ("" : on no species).
var open := Callable()


func _can_handle(p_object: Object) -> bool:
	return handles(p_object)


## Whether the inspector box is for `obj`: a species or a species pack.
static func handles(obj: Object) -> bool:
	return obj is ForestSpecies or obj is ForestSpeciesPack


func _parse_begin(p_object: Object) -> void:
	add_custom_control(panel_for(p_object, open))


## The inspector's box for `obj` (a ForestSpecies or a ForestSpeciesPack): its state and Open.
static func panel_for(obj: Object, p_open: Callable) -> Control:
	var box := VBoxContainer.new()
	var state := Label.new()
	state.name = "State"
	state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(state)
	var id := ""
	if obj is ForestSpeciesPack:
		var rows: Array = BuildRes.states([obj])
		var sp_rows: Array = rows[0]["species"] if not rows.is_empty() else []
		var n := sp_rows.filter(func(row): return String(row["state"]) in ["needs", "unbuilt"]).size()
		state.text = ("%d of %d species need building" % [n, sp_rows.size()]) if n > 0 else "Every species is built."
	else:
		id = String(obj.id)
		state.text = _species_state(obj)
	var b := Button.new()
	b.name = "Open"
	b.text = "Open in the Species dialog"
	b.pressed.connect(func() -> void:
		if p_open.is_valid():
			p_open.call(id))
	box.add_child(b)
	return box


## A species' state, found in the pack that lists it (a pack is looked for beside the species' own file: its folder's
## parent holds the pack); "" when no pack is found.
static func _species_state(sp) -> String:
	for pack in ForestConfig.current().resolved_packs() + _packs_beside(sp):
		if (pack.species as Array).has(sp):
			var st: Dictionary = BuildRes.state_of(sp, pack.built_dir(), BuildRes.read_manifest(pack.built_dir()))
			st["id"] = String(sp.id)
			return PanelRes.state_text(st)
	return ""


static func _packs_beside(sp) -> Array:
	var out := []
	var dir := String(sp.resource_path).get_base_dir().get_base_dir()
	if dir == "":
		return out
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".tres"):
			var p = load(dir.path_join(f))
			if p is ForestSpeciesPack:
				out.append(p)
	return out
