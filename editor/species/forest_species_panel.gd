# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Species dialog's right column: the selected species' 3D view (the dialog's, kept across rebuilds), then, scrolling,
## its name and id, its state, its Build and its switch, the question asked before it is switched off, its settings
## (shape and files; none for the read-only starter), what uses it and its pack's credits.

## The tile's caption rule.
const TileCaption := preload("res://addons/wuifwoud/editor/common/forest_species_tile.gd")
## The species' assets (mesh_surfaces).
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
## The texture fields, with their labels.
const TEXTURES := [["bark_albedo", "Bark albedo"], ["bark_normal", "Bark normal"], ["bark_mtao", "Bark MTAO"],
	["foliage_albedo", "Foliage albedo"], ["foliage_normal", "Foliage normal"], ["foliage_mtao", "Foliage MTAO"]]
## What an empty albedo means.
const EMPTY_ALBEDO := {"bark_albedo": "No bark albedo: the bark draws untextured.",
	"foliage_albedo": "No foliage albedo: the leaves draw untextured."}
## The mesh files a species takes.
const MESH_FILTERS := ["*.gltf, *.glb, *.fbx, *.FBX, *.blend ; Meshes", "*.tscn, *.scn ; Scenes"]
## The texture files a species takes.
const TEX_FILTERS := ["*.png, *.jpg, *.jpeg, *.tga, *.webp, *.exr, *.dds, *.ktx ; Textures"]



## The column for the dialog `d`.
static func build(d) -> Control:
	var row: Dictionary = d.row_of(d.selected) if d.selected != "" else {}
	if row.is_empty():
		var empty := VBoxContainer.new()
		empty.name = "Species"
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		empty.add_child(d.hint("Select a species."))
		return empty
	var sp = row["s"]
	var outer: BoxContainer = HBoxContainer.new() if d.inspecting else VBoxContainer.new()
	outer.name = "Species"
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("separation", 10)
	outer.add_child(_view_block(d, sp))
	var sc := ScrollContainer.new()
	sc.name = "SettingsScroll"
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 6)
	sc.add_child(v)
	outer.add_child(sc)
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
	var pack = row["pack"]
	if d.is_read_only(pack):
		var ro: Label = d.hint("The starter pack ships with Wuifwoud, so it is read-only here (an update of Wuifwoud would overwrite a change). Switch it off, or copy it into your project to change it.")
		ro.name = "ReadOnly"
		v.add_child(ro)
	else:
		if String(row["src"]["kind"]) == "addon":
			var an: Label = d.hint("In pack addon %s: updating that addon overwrites a change made here." % row["src"]["name"])
			an.name = "AddonNote"
			v.add_child(an)
		_settings(d, v, sp)
	var used: PackedStringArray = d.uses_of(String(sp.id))
	v.add_child(d.kit.section("Used by"))
	var ul: Label = d.hint("\n".join(used) if not used.is_empty() else
		("Switched off: it grows nowhere." if d.config.disabled_species.has(String(sp.id)) else "Nothing in this scene's forest."))
	ul.name = "UsedBy"
	v.add_child(ul)
	if String(pack.credits) != "":
		var cr: Label = d.hint(String(pack.credits))
		cr.name = "Credits"
		v.add_child(cr)
	return outer


## The 3D view, its mode and its level.
static func _view_block(d, sp) -> Control:
	var vb := VBoxContainer.new()
	vb.name = "ViewBlock"
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var view: Control = d.view_for_selected()
	vb.size_flags_stretch_ratio = 2.1 if d.inspecting else 1.0
	view.custom_minimum_size.y = 420.0 if d.inspecting else 190.0
	for c in view.camera_moved.get_connections():
		view.camera_moved.disconnect(c["callable"])       # the kept view must not pile up a rebuild's readouts
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(view)
	var bar := HBoxContainer.new()
	bar.name = "ViewBar"
	var modes: Array = ["model", "card", "compare", "sheets"] if d.inspecting else ["model", "card"]
	var labels: Array = ["Model", "Card", "Compare", "Sheets"] if d.inspecting else ["Model", "Card"]
	var seg: HBoxContainer = d.kit.segmented(labels, maxi(modes.find(view.mode), 0), d.accent, func(i: int) -> void:
		view.set_mode(modes[i])
		d.rebuild())
	seg.name = "Modes"
	bar.add_child(seg)
	if view.levels().size() > 1:
		var names := []
		for i in view.levels().size():
			names.append("LOD%d" % i)
		var ls: HBoxContainer = d.kit.segmented(names, view.lod, d.accent, func(i: int) -> void:
			view.set_lod(i)
			d.rebuild())
		ls.name = "Lods"
		bar.add_child(ls)
	var tl := Label.new()
	tl.name = "Tris"
	tl.text = "%s tris" % String.num_int64(view.tris(view.lod))
	tl.modulate = d.DIM
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(tl)
	var ins: Button = d.kit.chip("⤡ Back to the list" if d.inspecting else "⤢ Inspect", false, d.accent)
	ins.name = "Inspect"
	ins.pressed.connect(d.inspect.bind(not d.inspecting))
	bar.add_child(ins)
	vb.add_child(bar)
	if d.inspecting and (view.mode == "compare" or view.mode == "card"):
		var band: Dictionary = d.handover_for(String(sp.id))
		var out1 := float(band.get("out1", 300.0))
		var drow: VBoxContainer = d.kit.slider_row("Distance", 2.0, out1 * 1.4, 1.0, view.distance(), "m", d.accent)
		drow.name = "Distance"
		var ro := Label.new()
		ro.name = "Readout"
		var say := func() -> void:
			ro.text = "%d m · hand-over %d m · elev %d°" % [roundi(view.distance()), roundi(out1), roundi(view.elevation_deg())]
		say.call()
		(drow.get_node("Slider") as HSlider).value_changed.connect(func(x: float) -> void:
			view.dist = x
			view._aim()
			say.call())
		view.camera_moved.connect(say)
		vb.add_child(drow)
		vb.add_child(ro)
	return vb


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


static func _settings(d, v: VBoxContainer, sp) -> void:
	var dn := LineEdit.new()
	dn.name = "DisplayName"
	dn.text = String(sp.display_name)
	dn.placeholder_text = String(sp.id).replace("_", " ")
	dn.text_submitted.connect(func(t: String) -> void: d.set_field(sp, "display_name", t))
	dn.focus_exited.connect(func() -> void: d.set_field(sp, "display_name", dn.text))
	v.add_child(dn)
	v.add_child(d.kit.section("Shape"))
	var kind: HBoxContainer = d.kit.segmented(["Tree", "Bush"], 1 if String(sp.kind) == "bush" else 0, d.accent,
		func(i: int) -> void: d.set_field(sp, "kind", ["tree", "bush"][i]))
	kind.name = "Kind"
	v.add_child(kind)
	var crowns := ["broadleaf", "conifer", "palm"]
	var crown: HBoxContainer = d.kit.segmented(["Broadleaf", "Conifer", "Palm"], maxi(crowns.find(String(sp.crown)), 0),
		d.accent, func(i: int) -> void: d.set_field(sp, "crown", crowns[i]))
	crown.name = "Crown"
	v.add_child(crown)
	v.add_child(_slider(d, sp, "TrunkRadius", "Trunk radius", "trunk_radius", 0.0, 3.0, 0.01, "m"))
	v.add_child(_slider(d, sp, "AlphaCut", "Alpha cut", "alpha_cut", 0.0, 1.0, 0.01, ""))
	var ages := HBoxContainer.new()
	ages.name = "Ages"
	for pair in [["Young", "young"], ["Mature", "mature"]]:
		var b: Button = d.kit.toggle_chip(String(pair[0]), bool(sp.get(pair[1])), d.accent)
		b.name = String(pair[0])
		var f := String(pair[1])
		b.toggled.connect(func(on: bool) -> void: d.set_field(sp, f, on))
		ages.add_child(b)
	v.add_child(ages)
	v.add_child(d.kit.section("Files"))
	var mrow := HBoxContainer.new()
	var me := LineEdit.new()
	me.name = "MeshPath"
	me.text = String(sp.mesh)
	me.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	me.text_submitted.connect(func(t: String) -> void: d.set_field(sp, "mesh", t))
	mrow.add_child(me)
	var mp: Button = d.kit.chip("…", false, d.accent)
	mp.name = "MeshPick"
	mp.tooltip_text = "Pick the mesh"
	mp.pressed.connect(func() -> void: d.pick("The species' mesh", PackedStringArray(MESH_FILTERS), false,
		func(p: String) -> void: d.set_field(sp, "mesh", p)))
	mrow.add_child(mp)
	v.add_child(mrow)
	var surfaces: Array = VA.mesh_surfaces(ForestSpecies.resolve(String(sp.mesh)))
	if not surfaces.is_empty():
		v.add_child(d.hint("Leaf materials (none on: the names decide)"))
		var leaf := HFlowContainer.new()
		leaf.name = "LeafMaterials"
		for s in surfaces:
			var nm := String(s["name"])
			if nm == "":
				continue
			var b: Button = d.kit.toggle_chip(nm, (sp.foliage_materials as PackedStringArray).has(nm), d.accent)
			b.name = "Leaf_" + nm.validate_node_name()
			b.tooltip_text = "%s (the names say %s)" % [nm, "leaves" if bool(s["foliage"]) else "bark"]
			b.toggled.connect(func(on: bool) -> void:
				var names := PackedStringArray(sp.foliage_materials)
				if on and not names.has(nm):
					names.append(nm)
				elif not on:
					while names.has(nm):
						names.remove_at(names.find(nm))
				d.set_field(sp, "foliage_materials", names))
			leaf.add_child(b)
		v.add_child(leaf)
	for pair in TEXTURES:
		v.add_child(_texture_row(d, sp, String(pair[0]), String(pair[1])))
		if EMPTY_ALBEDO.has(pair[0]) and String(sp.get(pair[0])) == "":
			var e: Label = d.hint(String(EMPTY_ALBEDO[pair[0]]))
			e.name = "Empty_" + String(pair[0])
			e.modulate = Color.WHITE
			e.add_theme_color_override("font_color", d.ERROR)
			v.add_child(e)


static func _slider(d, sp, nm: String, label: String, field: String, lo: float, hi: float, step: float,
		suffix: String) -> Control:
	var row: VBoxContainer = d.kit.slider_row(label, lo, hi, step, float(sp.get(field)), suffix, d.accent)
	row.name = nm
	var s := row.get_node("Slider") as HSlider
	s.drag_ended.connect(func(moved: bool) -> void:
		if moved:
			d.set_field(sp, field, s.value))
	return row


static func _texture_row(d, sp, field: String, label: String) -> Control:
	var h := HBoxContainer.new()
	h.name = "Tex_" + field
	var path := String(sp.get(field))
	var pic := TextureRect.new()
	pic.custom_minimum_size = Vector2(20, 20)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var res := ForestSpecies.resolve(path)
	if res != "" and ResourceLoader.exists(res):
		pic.texture = load(res) as Texture2D
	h.add_child(pic)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 96.0
	h.add_child(l)
	var e := LineEdit.new()
	e.name = "Path"
	e.text = path
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.text_submitted.connect(func(t: String) -> void: d.set_field(sp, field, t))
	h.add_child(e)
	var p: Button = d.kit.chip("…", false, d.accent)
	p.name = "Pick"
	p.pressed.connect(func() -> void: d.pick(label, PackedStringArray(TEX_FILTERS), false,
		func(f: String) -> void: d.set_field(sp, field, f)))
	h.add_child(p)
	var x: Button = d.kit.chip("✕", false, d.accent)
	x.name = "Clear"
	x.disabled = path == ""
	x.pressed.connect(func() -> void: d.set_field(sp, field, ""))
	h.add_child(x)
	return h
