# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Control
## The Species dialog: centred and modal over the editor, every species of every pack the project lists (the tree on
## the left, ForestSpeciesTree) and the selected species (the right column, ForestSpeciesPanel), with its 3D view and
## Inspect (the view at the dialog's width). Packs and species switch on and off (the config's disabled_packs and
## disabled_species), species are edited, added and taken out of their pack, and packs are built: the plugin runs the
## build (`run`) and polls it, this dialog watches it and may close and reopen while it runs. Every change is one undo
## step: what the dialog edits (the config's two lists, every listed pack's species, each species' settings) is
## snapshotted, changed, the files it touched written, the view rebuilt; a write that fails is said and undone.
## Read-only while a build runs. Built in code with ForestKit.

## The dialog closed.
signal closed
## Something the forest grows from changed (a species, a pack, the config): the plugin regrows the scene's forest.
signal changed

## The pack build (its states).
const BuildRes := preload("res://addons/wuifwoud/species/forest_pack_build.gd")
## The left column.
const TreeRes := preload("res://addons/wuifwoud/editor/species/forest_species_tree.gd")
## The right column.
const PanelRes := preload("res://addons/wuifwoud/editor/species/forest_species_panel.gd")
## The species pictures.
const PicturesRes := preload("res://addons/wuifwoud/editor/common/forest_pictures.gd")
## Undo steps kept at most.
const UNDO_MAX := 100
## The dialog's size.
const SIZE := Vector2(1120, 700)
## The backdrop over the editor.
const BACKDROP := Color(0.0, 0.0, 0.0, 0.45)
## Secondary text.
const DIM := Color(1.0, 1.0, 1.0, 0.55)
## Errors.
const ERROR := Color("ff8a80")
## Warnings.
const AMBER := Color("ffcc80")
## Built.
const GOOD := Color("aed581")
## The panel's opacity.
const PANEL_ALPHA := 0.94
## Terrain3D Extended's modal group: while the dialog is in it, the overlay hides and the terrain takes no 3D input.
const UX_MODAL_GROUP := &"terrain_3d_ux_modal"
## What a change attempted while a build runs says.
const READ_ONLY := "Read-only while a build runs: that change was not made."
## A build phase as the progress line says it.
const VERB := {"prepare": "Preparing", "bake": "Baking", "store": "Storing", "land": "Built"}
## A species' settings, as a snapshot keeps them.
const FIELDS := ["display_name", "kind", "crown", "trunk_radius", "mature", "young", "alpha_cut", "mesh",
	"foliage_materials", "bark_albedo", "bark_normal", "bark_mtao", "foliage_albedo", "foliage_normal", "foliage_mtao"]
## The header's ⋯: Rebuild all.
const MENU_REBUILD_ALL := 1

## ForestKit.
var kit = null
## The accent.
var accent := Color("8bc34a")
## The project's config (the object the forest reads).
var config: ForestConfig = null
## Where it is written ("" never: a config with no file is written here first).
var config_path := ""
## The packs as listed: config.listed_sources() (or the context's `sources_of`).
var sources: Array = []
## The species selected ("": none).
var selected := ""
## The view at the dialog's width (Task 11).
var inspecting := false
## The search field's text.
var search := ""
## "all" | "trees" | "bushes" | "build" | "disabled".
var filter := "all"
## Pack key -> open.
var open := {}
## A question the panel asks: {"text", "action", "do": Callable} ({} : none).
var asking := {}
## What went wrong ("": nothing).
var error := ""
## What the last change did that is worth saying ("": nothing).
var note := ""
## The last build's report, until the next one or the dialog closes.
var report := {}
## (packs: Array, options: Dictionary) -> String: "" when started, else why not.
var run := Callable()
## () -> the running or last build, or null.
var job_of := Callable()
## (title, filters: PackedStringArray, dir: bool, on_pick: Callable(path)) -> void.
var pick_file := Callable()
## (path) -> void: the FileSystem dock shows it.
var show_file := Callable()
## () -> {species id: PackedStringArray}: what uses each species (ForestSpeciesUse.of for the scene's forest).
var uses := Callable()
## (id) -> {"out0", "out1"}: a species' mesh-to-card hand-over.
var handover_of := Callable()
var _sources_of := Callable()
var _states := {}                  # pack key -> ForestPackBuild.states([pack])[0]
var _undo: Array = []
var _redo: Array = []
var _watch = null
var _panel: PanelContainer
var _content: VBoxContainer
var _rebuilding := false


## The context (context_for's, the plugin's callables); builds the view.
func setup(p: Dictionary) -> void:
	kit = p["kit"]
	accent = p.get("accent", accent)
	config = p["config"]
	config_path = String(p.get("config_path", ""))
	_sources_of = p.get("sources_of", func() -> Array: return config.listed_sources())
	run = p.get("run", Callable())
	job_of = p.get("job_of", Callable())
	pick_file = p.get("pick_file", Callable())
	show_file = p.get("show_file", Callable())
	uses = p.get("uses", Callable())
	handover_of = p.get("handover_of", Callable())
	var j = job_of.call() if job_of.is_valid() else null
	if j != null and j.is_running():
		_watch = j
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	var back := ColorRect.new()
	back.color = BACKDROP
	back.mouse_filter = MOUSE_FILTER_IGNORE
	back.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(back)
	var center := CenterContainer.new()
	center.mouse_filter = MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)
	_panel = kit.glass_panel()
	var base = _panel.get_theme_stylebox("panel")
	if base is StyleBoxFlat:
		var sb := (base as StyleBoxFlat).duplicate() as StyleBoxFlat
		sb.bg_color.a = PANEL_ALPHA
		_panel.add_theme_stylebox_override("panel", sb)
	_panel.custom_minimum_size = SIZE
	center.add_child(_panel)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 8)
	_panel.add_child(_content)
	refresh_states()
	rebuild()


## The context for the editor: the overlay's components (`p_kit`, a ForestKit), the project's config and where it is.
static func context_for(p_kit) -> Dictionary:
	return {"kit": p_kit, "config": ForestConfig.current(),
		"config_path": String(ProjectSettings.get_setting(ForestConfig.SETTING, ForestConfig.DEFAULT_PATH))}


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		add_to_group(UX_MODAL_GROUP)
		top_level = true
		set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	elif what == NOTIFICATION_RESIZED and _panel != null and is_inside_tree():
		_panel.custom_minimum_size = SIZE.min(get_viewport_rect().size - Vector2(40.0, 40.0))


## The build shown here, every frame: its progress while it runs; when it ends, its report, the pictures and the states
## read again.
func _process(_dt: float) -> void:
	if _watch == null:
		return
	if _watch.is_running():
		_show_progress()
		return
	report = _watch.report
	_watch = null
	PicturesRes.forget()
	refresh_states()
	rebuild()


# --- the model ---

## The packs listed and their species' states, read again (a change or a build moves them).
func refresh_states() -> void:
	sources = _sources_of.call()
	_states = {}
	for pr in all_packs():
		var st: Array = BuildRes.states([pr["pack"]])
		_states[pack_key(pr["pack"])] = st[0] if not st.is_empty() else {"species": []}


## Every listed pack: [{pack, enabled, src}], in listed order.
func all_packs() -> Array:
	var out := []
	for src in sources:
		for row in src["packs"]:
			out.append({"pack": row["pack"], "enabled": bool(row["enabled"]), "src": src})
	return out


## A pack's key: its file, or its object for one that is not a file.
func pack_key(pack) -> String:
	return String(pack.resource_path) if String(pack.resource_path) != "" else str(pack.get_instance_id())


## A pack's name in the tree.
func pack_label(pack) -> String:
	return String(pack.name) if String(pack.name) != "" else String(pack.resource_path).get_file()


## The listed pack with key `key`, or null.
func pack_by_key(key: String):
	for pr in all_packs():
		if pack_key(pr["pack"]) == key:
			return pr["pack"]
	return null


## Every row of species `id`, one a pack that lists it: [{id, s, state, why, pack, dir, enabled, src}].
func rows_of(id: String) -> Array:
	var out := []
	for pr in all_packs():
		var st: Dictionary = _states.get(pack_key(pr["pack"]), {"species": []})
		for row in st["species"]:
			if String(row["id"]) == id:
				out.append({"id": id, "s": row["s"], "state": row["state"], "why": row["why"], "pack": pr["pack"],
					"dir": pr["pack"].built_dir(), "enabled": bool(pr["enabled"]), "src": pr["src"]})
	return out


## The first row of species `id` ({} : none).
func row_of(id: String) -> Dictionary:
	var rows := rows_of(id)
	return rows[0] if not rows.is_empty() else {}


## Whether species `id` of `pack` grows: its pack on, and the id not switched off.
func grows(id: String, pack) -> bool:
	for pr in all_packs():
		if pr["pack"] == pack:
			return bool(pr["enabled"]) and not config.disabled_species.has(id)
	return false


## A pack that ships inside Wuifwoud (the starter): shown, switched on and off, never edited.
func is_read_only(pack) -> bool:
	var dir := ForestConfig._addon_dir() + "/"
	return String(pack.resource_path).begins_with(dir)


## The species of `pack` the search and the filter let through: its state rows.
func shown_species(pack) -> Array:
	var st: Dictionary = _states.get(pack_key(pack), {"species": []})
	var q := search.strip_edges().to_lower()
	return (st["species"] as Array).filter(func(row) -> bool:
		var s = row["s"]
		if q != "" and not String(s.id).to_lower().contains(q) and not String(s.display_name).to_lower().contains(q):
			return false
		match filter:
			"trees":
				return String(s.kind) != "bush"
			"bushes":
				return String(s.kind) == "bush"
			"build":
				return String(row["state"]) in ["needs", "unbuilt"]
			"disabled":
				return not grows(String(row["id"]), pack)
		return true)


## "47 · 44 on · 3 to build", or "9 · off".
func counts_text(pack) -> String:
	var st: Dictionary = _states.get(pack_key(pack), {"species": []})
	var rows: Array = st["species"]
	var on := rows.filter(func(row): return grows(String(row["id"]), pack)).size()
	var build := rows.filter(func(row): return String(row["state"]) in ["needs", "unbuilt"]).size()
	if on == 0 and not rows.is_empty():
		return "%d · off" % rows.size()
	return "%d · %d on%s" % [rows.size(), on, (" · %d to build" % build) if build > 0 else ""]


## Where a pack comes from, for its row.
func pack_where(src: Dictionary, pack) -> String:
	match String(src["kind"]):
		"wuifwoud":
			return "ships with Wuifwoud · read-only"
		"addon":
			return "pack addon %s" % src["name"]
	return String(pack.resource_path).get_base_dir()


# --- every change one undo step ---

## What the dialog edits, as it is now.
func snapshot() -> Dictionary:
	var packs := {}
	var sps := {}
	for pr in all_packs():
		var pack = pr["pack"]
		packs[pack_key(pack)] = Array(pack.species)
		for sp in pack.species:
			if sp == null:
				continue
			var f := {}
			for k in FIELDS:
				var v = sp.get(k)
				f[k] = (v as PackedStringArray).duplicate() if v is PackedStringArray else v
			sps[sp.get_instance_id()] = f
	return {"disabled_packs": PackedStringArray(config.disabled_packs),
		"disabled_species": PackedStringArray(config.disabled_species), "packs": packs, "species": sps}


## Put a snapshot back (in memory; _write writes it).
func restore(s: Dictionary) -> void:
	config.disabled_packs = PackedStringArray(s["disabled_packs"])
	config.disabled_species = PackedStringArray(s["disabled_species"])
	for key in s["packs"]:
		var pack = pack_by_key(String(key))
		if pack != null:
			var arr: Array[ForestSpecies] = []
			arr.assign(s["packs"][key])
			pack.species = arr
	for sid in s["species"]:
		var sp = instance_from_id(int(sid))
		if sp == null:
			continue
		for k in FIELDS:
			sp.set(k, (s["species"][sid] as Dictionary)[k])


## One undo step: `fn` changes what the dialog edits and returns "" (done) or why not (nothing changed then). The files
## it touched are written; a failed write is said and the change undone. Ignored while rebuilding; refused while a
## build runs.
func change(fn: Callable) -> bool:
	if _rebuilding:
		return false
	if busy():
		error = READ_ONLY
		rebuild()
		return false
	var before := snapshot()
	var why: String = fn.call()
	if why != "":
		restore(before)
		error = why
		rebuild()
		return false
	var after := snapshot()
	if after == before:
		rebuild()
		return false
	var w := _write(before, after)
	if w != "":
		restore(before)
		_write(after, before)
		error = w
		rebuild()
		return false
	error = ""
	_undo.append(before)
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()
	_redo.clear()
	_changed()
	return true


## Undo the last change.
func undo() -> void:
	_step(_undo, _redo)


## Redo the last undone change.
func redo() -> void:
	_step(_redo, _undo)


func _step(from: Array, to: Array) -> void:
	if from.is_empty() or busy():
		return
	var now := snapshot()
	var was: Dictionary = from.pop_back()
	restore(was)
	var w := _write(now, was)
	if w != "":
		restore(now)
		from.append(was)
		error = w
		rebuild()
		return
	to.append(now)
	_changed()


func _changed() -> void:
	refresh_states()
	changed.emit()
	rebuild()


## The files a change from `before` to `after` touched, written: the config when its lists moved (written first to
## config_path when it has no file), a pack whose species moved, a species whose settings moved (its own file, or its
## pack's when it has none). "" when all were written, else what failed.
func _write(before: Dictionary, after: Dictionary) -> String:
	var fails := PackedStringArray()
	if before["disabled_packs"] != after["disabled_packs"] or before["disabled_species"] != after["disabled_species"]:
		var path := config.resource_path if config.resource_path != "" else config_path
		var created := not ResourceLoader.exists(path)
		var e := ResourceSaver.save(config, path, ResourceSaver.FLAG_CHANGE_PATH)
		if e != OK:
			fails.append("%s (%s)" % [path, error_string(e)])
		elif created:
			note = "Created the Wuifwoud config at %s." % path
	var packs := {}
	for key in after["packs"]:
		if before["packs"].get(key) != after["packs"][key]:
			packs[key] = true
	for sid in after["species"]:
		if before["species"].get(sid) == after["species"][sid]:
			continue
		var sp = instance_from_id(int(sid))
		var own := sp != null and String(sp.resource_path) != "" and not String(sp.resource_path).contains("::")
		if own:
			var e2 := ResourceSaver.save(sp, sp.resource_path)
			if e2 != OK:
				fails.append("%s (%s)" % [sp.resource_path, error_string(e2)])
		elif sp != null:
			for pr in all_packs():
				if (pr["pack"].species as Array).has(sp):
					packs[pack_key(pr["pack"])] = true
	for key in packs:
		var pack = pack_by_key(String(key))
		if pack == null or String(pack.resource_path) == "":
			continue
		var e3 := ResourceSaver.save(pack, pack.resource_path)
		if e3 != OK:
			fails.append("%s (%s)" % [pack.resource_path, error_string(e3)])
	return "" if fails.is_empty() else "Could not write " + ", ".join(fails)


# --- what the tree and the panel ask ---

## The tile menu: Enable / Disable.
const TILE_TOGGLE := 0
## The tile menu: Build.
const TILE_BUILD := 1
## The tile menu: Remove from pack.
const TILE_REMOVE := 2
## The tile menu: Show in FileSystem.
const TILE_SHOW := 3

var _tile_menu: PopupMenu = null


## What uses species `id` in the scene's forest.
func uses_of(id: String) -> PackedStringArray:
	var u = uses.call() if uses.is_valid() else {}
	return (u as Dictionary).get(id, PackedStringArray()) if u is Dictionary else PackedStringArray()


## Switch species `id` (every pack's row of it) on or off. Off while something uses it asks first, naming what loses it.
func set_species_enabled(id: String, on: bool, confirmed := false) -> void:
	var users := uses_of(id)
	if not on and not confirmed and not users.is_empty():
		asking = {"text": "%s is used by %s: those lose it (the rest of each mix share its weight; a single tree pinned to it grows its type's pick)." % [id, "; ".join(users)],
			"action": "Disable", "do": set_species_enabled.bind(id, false, true)}
		rebuild()
		return
	asking = {}
	change(func() -> String:
		var ds := config.disabled_species
		if on:
			while ds.has(id):
				ds.remove_at(ds.find(id))
		elif not ds.has(id):
			ds.append(id)
		config.disabled_species = ds
		return "")


## The question's action.
func confirm_question() -> void:
	var f: Callable = asking.get("do", Callable())
	asking = {}
	if f.is_valid():
		f.call()
	else:
		rebuild()


## The question answered no.
func cancel_question() -> void:
	asking = {}
	rebuild()


## The tile menu of species `id` at screen position `at`.
func open_tile_menu(id: String, at: Vector2) -> void:
	if _tile_menu != null and is_instance_valid(_tile_menu):
		_tile_menu.queue_free()
	var row := row_of(id)
	if row.is_empty():
		return
	_tile_menu = PopupMenu.new()
	_tile_menu.add_item("Disable" if not config.disabled_species.has(id) else "Enable", TILE_TOGGLE)
	_tile_menu.add_item("Build", TILE_BUILD)
	_tile_menu.set_item_disabled(_tile_menu.item_count - 1, busy() or String(row["state"]) == "missing")
	_tile_menu.add_item("Show in FileSystem", TILE_SHOW)
	_tile_menu.id_pressed.connect(func(item: int) -> void: tile_menu_action(id, item))
	add_child(_tile_menu)
	_tile_menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


## A tile menu item picked for species `id`.
func tile_menu_action(id: String, item: int) -> void:
	match item:
		TILE_TOGGLE:
			set_species_enabled(id, config.disabled_species.has(id))
		TILE_BUILD:
			build_species(id)
		TILE_SHOW:
			var row := row_of(id)
			if not row.is_empty() and show_file.is_valid():
				show_file.call(String(row["s"].resource_path) if String(row["s"].resource_path) != ""
					else String(row["pack"].resource_path))


## Select species `id`.
func select(id: String) -> void:
	selected = id
	rebuild()


## Open or close a pack's row.
func toggle_open(key: String) -> void:
	open[key] = not is_open(key)
	rebuild()


## Whether a pack's row is open: as toggled, else the first pack's.
func is_open(key: String) -> bool:
	if open.has(key):
		return bool(open[key])
	var all := all_packs()
	return not all.is_empty() and pack_key(all[0]["pack"]) == key


## Show only some species.
func set_filter(f: String) -> void:
	filter = f
	rebuild()


## A search keystroke: the view is rebuilt after the field's signal (never inside it) and the new field keeps the
## typing.
func search_changed(t: String) -> void:
	search = t
	_apply_search.call_deferred()


func _apply_search() -> void:
	rebuild()
	var f := _content.find_child("Search", true, false) as LineEdit
	if f != null and f.is_inside_tree():
		f.grab_focus()
		f.caret_column = f.text.length()


## Switch `pack` (of source `src`) on or off; on also switches its pack addon back on when the addon was off.
func set_pack_enabled(src: Dictionary, pack, on: bool) -> void:
	change(func() -> String:
		var dp := config.disabled_packs
		var path := String(pack.resource_path)
		if on:
			while dp.has(path):
				dp.remove_at(dp.find(path))
			var sp := String(src["path"])
			if String(src["kind"]) == "addon":
				while dp.has(sp):
					dp.remove_at(dp.find(sp))
		elif not dp.has(path):
			dp.append(path)
		config.disabled_packs = dp
		return "")


## The packs that grow.
func enabled_packs() -> Array:
	return all_packs().filter(func(pr): return bool(pr["enabled"])).map(func(pr): return pr["pack"])


## Build what's needed (the packs that grow).
func build_needed() -> void:
	_launch(enabled_packs(), {"force": false})


## Rebuild every species of the packs that grow.
func rebuild_all() -> void:
	_launch(enabled_packs(), {"force": true})


## Build what `pack` needs.
func build_pack(pack) -> void:
	_launch([pack], {"force": false})


## Build species `id` (its first pack), forced.
func build_species(id: String) -> void:
	var row := row_of(id)
	if not row.is_empty():
		_launch([row["pack"]], {"force": true, "only": [id]})


func _launch(packs: Array, options: Dictionary) -> void:
	if busy() or not run.is_valid():
		return
	var why: String = run.call(packs, options)
	error = why
	if why == "":
		report = {}
		_watch = job_of.call() if job_of.is_valid() else null
	rebuild()


## Whether the build shown here runs.
func busy() -> bool:
	return _watch != null and _watch.is_running()


## Cancel the running build (the species already built stay).
func cancel_run() -> void:
	if busy():
		_watch.cancel()


## The running build's phase.
func phase_text() -> String:
	if _watch == null:
		return ""
	var p: Dictionary = _watch.progress()
	var verb: String = VERB.get(String(p.get("phase", "")), "")
	if verb == "":
		return ""
	return "%s %s · %d of %d" % [verb, String(p.get("species", "")), int(p.get("done", 0)), int(p.get("total", 0))]


## Species that need building in the packs that grow.
func needed_count() -> int:
	var n := 0
	for pack in enabled_packs():
		var st: Dictionary = _states.get(pack_key(pack), {"species": []})
		n += (st["species"] as Array).filter(func(row): return String(row["state"]) in ["needs", "unbuilt"]).size()
	return n


## Species listed in all.
func species_count() -> int:
	var n := 0
	for pr in all_packs():
		n += (_states.get(pack_key(pr["pack"]), {"species": []})["species"] as Array).size()
	return n


# --- the view ---

## Rebuilds the view from the model. Scroll positions are kept.
func rebuild() -> void:
	_rebuilding = true
	var scrolls := {}
	for sc in _content.find_children("*", "ScrollContainer", true, false):
		scrolls[String(sc.name)] = (sc as ScrollContainer).scroll_vertical
	_detach_kept()
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	_content.add_child(_header())
	if error != "":
		var e := hint(error)
		e.name = "Error"
		e.modulate = Color.WHITE
		e.add_theme_color_override("font_color", ERROR)
		_content.add_child(e)
	if note != "":
		var n := hint(note)
		n.name = "Note"
		_content.add_child(n)
	var body := HBoxContainer.new()
	body.name = "Body"
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	if not inspecting:
		body.add_child(TreeRes.build(self))
	body.add_child(PanelRes.build(self))
	_content.add_child(body)
	_content.add_child(_run_bar())
	for sc in _content.find_children("*", "ScrollContainer", true, false):
		if scrolls.has(String(sc.name)):
			(sc as ScrollContainer).set_deferred("scroll_vertical", scrolls[String(sc.name)])
	_rebuilding = false
	if busy():
		_show_progress()


## Nodes kept across rebuilds (the 3D view, Task 10) taken out of the old tree first.
func _detach_kept() -> void:
	pass


func _header() -> Control:
	var h := HBoxContainer.new()
	h.name = "Header"
	h.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "SPECIES"
	title.add_theme_color_override("font_color", accent)
	title.add_theme_font_size_override("font_size", 13)
	h.add_child(title)
	var n := needed_count()
	var info := Label.new()
	info.name = "Info"
	info.text = "· this project · %d species in %d packs%s" % [species_count(), all_packs().size(),
		(" · %d need building" % n) if n > 0 else ""]
	info.modulate = DIM
	info.clip_text = true
	info.size_flags_horizontal = SIZE_EXPAND_FILL
	h.add_child(info)
	var bn: Button = kit.chip("Build what's needed", false, accent)
	bn.name = "BuildNeeded"
	bn.disabled = n == 0 or busy() or not run.is_valid()
	bn.pressed.connect(build_needed)
	h.add_child(bn)
	var more = kit.menu_chip("⋯", [{"id": MENU_REBUILD_ALL, "text": "Rebuild all", "disabled": busy() or not run.is_valid()}],
		accent, func(id: int) -> void:
			if id == MENU_REBUILD_ALL:
				rebuild_all())
	more.name = "More"
	h.add_child(more)
	h.add_child(_button("Undo", "↶", undo, _undo.is_empty() or busy()))
	h.add_child(_button("Redo", "↷", redo, _redo.is_empty() or busy()))
	h.add_child(_button("Close", "✕", close, false))
	return h


func _run_bar() -> Control:
	var v := VBoxContainer.new()
	v.name = "RunBar"
	if busy():
		v.add_child(HSeparator.new())
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		var bar := ProgressBar.new()
		bar.name = "Progress"
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 8)
		bar.size_flags_horizontal = SIZE_EXPAND_FILL
		bar.size_flags_vertical = SIZE_SHRINK_CENTER
		h.add_child(bar)
		var ph := Label.new()
		ph.name = "Phase"
		ph.text = phase_text()
		h.add_child(ph)
		var c: Button = kit.chip("Cancel", false, accent)
		c.name = "Cancel"
		c.pressed.connect(cancel_run)
		h.add_child(c)
		v.add_child(h)
		v.add_child(hint("The editor is free while it builds; closing this dialog does not stop it. Cancel keeps the species already built."))
	elif not report.is_empty():
		v.add_child(HSeparator.new())
		v.add_child(_report())
	return v


func _report() -> Control:
	var v := VBoxContainer.new()
	v.name = "Report"
	var failed: Dictionary = report.get("failed", {})
	var sl := hint("%s%d built, %d up to date, %d failed, %d removed · %.1f s" % [
		"Cancelled: the species built before it stay. " if bool(report.get("cancelled", false)) else "",
		(report.get("built", []) as Array).size(), (report.get("skipped", []) as Array).size(), failed.size(),
		(report.get("removed", []) as Array).size(), float(report.get("ms", 0)) / 1000.0])
	sl.name = "Summary"
	v.add_child(sl)
	for id in failed:
		var l := hint("%s: %s" % [id, failed[id]])
		l.modulate = Color.WHITE
		l.add_theme_color_override("font_color", ERROR)
		v.add_child(l)
	var warns: Dictionary = report.get("warnings", {})
	var ids := warns.keys()
	for id in ids.slice(0, 6):
		var l := hint("%s: %s" % [id, "; ".join(PackedStringArray(warns[id]))])
		l.modulate = Color.WHITE
		l.add_theme_color_override("font_color", AMBER)
		v.add_child(l)
	if ids.size() > 6:
		v.add_child(hint("(+%d more with warnings)" % (ids.size() - 6)))
	return v


func _show_progress() -> void:
	var p: Dictionary = _watch.progress()
	var bar := _content.find_child("Progress", true, false) as ProgressBar
	if bar != null:
		bar.max_value = maxi(int(p.get("total", 0)), 1)
		bar.value = int(p.get("done", 0))
	var ph := _content.find_child("Phase", true, false) as Label
	if ph != null:
		ph.text = phase_text()


func _button(nm: String, text: String, fn: Callable, off: bool) -> Button:
	var b: Button = kit.chip(text, false, accent)
	b.name = nm
	b.tooltip_text = nm
	b.disabled = off
	b.pressed.connect(fn)
	return b


## A secondary, wrapping label.
func hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = DIM
	l.add_theme_font_size_override("font_size", 11)
	return l


## A flat style box.
static func box(bg: Color, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(8)
	if border.a > 0.0:
		sb.set_border_width_all(1)
		sb.border_color = border
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


## Close the dialog (a running build carries on).
func close() -> void:
	closed.emit()
	queue_free()


func _input(ev: InputEvent) -> void:
	if not (ev is InputEventKey) or not ev.pressed or ev.echo:
		return
	var k := ev as InputEventKey
	var vp := get_viewport()
	var typing := vp != null and vp.gui_get_focus_owner() is LineEdit
	if k.keycode == KEY_ESCAPE:
		if not asking.is_empty():
			asking = {}
			rebuild()
		elif inspecting:
			inspecting = false
			rebuild()
		else:
			close()
	elif not typing and k.ctrl_pressed and k.keycode == KEY_Z:
		if k.shift_pressed:
			redo()
		else:
			undo()
	elif not typing and k.ctrl_pressed and k.keycode == KEY_Y:
		redo()
	else:
		return
	if vp != null:
		vp.set_input_as_handled()
