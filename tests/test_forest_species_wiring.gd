# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The Species dialog in the editor: Forest → Species… asks the plugin for it (Build packs… is gone); the workspace's ⋯
## has Species… first; the inspector shows a species' or a pack's built state and opens the dialog on it.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const MenuRes := preload("res://addons/wuifwoud/editor/forest_preview_menu.gd")
const ProviderRes := preload("res://addons/wuifwoud/editor/forest_paint_provider.gd")
const InspRes := preload("res://addons/wuifwoud/editor/forest_species_inspector.gd")
const Fix := preload("res://addons/wuifwoud/tests/fixtures/species_fixture.gd")
const ROOT := "user://wf_e1_wiring"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_species_wiring", "passed": 0, "failed": 0, "details": []}
	var m = MenuRes.new()
	var asked := [0]
	m.species_requested.connect(func() -> void: asked[0] += 1)
	m._on_id(MenuRes.ID_SPECIES)
	var pop: PopupMenu = m.get_popup()
	var texts := []
	for i in pop.item_count:
		texts.append(pop.get_item_text(i))
	_chk(r, "Forest → Species… asks for the dialog; Build packs… is gone (%s)" % str(texts),
		asked[0] == 1 and texts.has("Species…") and not texts.has("Build packs…"))
	m.free()
	var p = ProviderRes.new()
	var opened := [0]
	p.species_requested.connect(func() -> void: opened[0] += 1)
	var acts: Array = p.workspace_actions().map(func(a): return a["id"])
	p.workspace_action("species")
	_chk(r, "the workspace's ⋯ has Species… after Types… (%s)" % str(acts),
		acts == ["types", "species", "import", "restore", "regrow"] and opened[0] == 1)
	var fx := Fix.make(ROOT)
	var got := ["?"]
	var panel: Control = InspRes.panel_for(fx["fixture"].species[0], func(id: String) -> void: got[0] = id)
	var state := panel.find_child("State", true, false) as Label
	(panel.find_child("Open", true, false) as Button).pressed.emit()
	_chk(r, "a species in the inspector: its state, and Open selects it (%s)" % (state.text if state != null else "none"),
		state != null and state.text == "built" and got[0] == "W_Tree")
	panel.free()
	var pp: Control = InspRes.panel_for(fx["fixture"], func(id: String) -> void: got[0] = id)
	(pp.find_child("Open", true, false) as Button).pressed.emit()
	_chk(r, "a pack: what it needs, and Open opens the dialog",
		(pp.find_child("State", true, false) as Label).text == "2 of 4 species need building" and got[0] == "")
	pp.free()
	_chk(r, "it handles species and packs only",
		InspRes.handles(fx["fixture"]) and InspRes.handles(fx["fixture"].species[0])
		and not InspRes.handles(ForestConfig.new()))
	Fix.TreeFix.rm_tree(ROOT)
	return r
