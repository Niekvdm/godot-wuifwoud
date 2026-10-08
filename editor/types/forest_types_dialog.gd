# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Control
## The Types dialog: centred and modal over the editor, the edited scene's flora profile as forest types: the list on
## the left (ForestTypeList), the selected type's settings in the middle (ForestTypePanel), its lanes and the species
## strip on the right (ForestTypeLanes); a Bands tab. Every change is one undo step: the profile (ForestProfile) is
## snapshotted, changed and written at once, then `changed` lets the plugin reload the scene's forest; a write that
## fails is said and undone. A forest without a profile, a read-only profile (one inside Wuifwoud) and one that does
## not read are shown with what to do. Built in code with ForestKit.

## The dialog closed.
signal closed
## The profile was written: the plugin reloads the scene's forest.
signal changed

## The profile as data.
const ProfileRes := preload("res://addons/wuifwoud/forest_profile.gd")
## The left column.
const ListRes := preload("res://addons/wuifwoud/editor/types/forest_type_list.gd")
## The middle column.
const PanelRes := preload("res://addons/wuifwoud/editor/types/forest_type_panel.gd")
## The right column.
const LanesRes := preload("res://addons/wuifwoud/editor/types/forest_type_lanes.gd")
## The species strip (its drag kind).
const StripRes := preload("res://addons/wuifwoud/editor/types/forest_species_strip.gd")
## The species pictures.
const PicturesRes := preload("res://addons/wuifwoud/editor/common/forest_pictures.gd")
## The type icons.
const TypeTileRes := preload("res://addons/wuifwoud/editor/common/forest_type_tile.gd")
## The forest's species.
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
## The forest node (its fallback flora).
const SpawnerRes := preload("res://addons/wuifwoud/forest_spawner.gd")
## The drag kind of a type row's handle.
const TYPE_KIND := "wuifwoud_type"
## The drag kind of a lane's species tile.
const LANE_KIND := "wuifwoud_lane_tile"
## A type row's menu: Duplicate.
const MENU_DUPLICATE := 0
## A type row's menu: Delete.
const MENU_DELETE := 1
## Undo steps kept at most.
const UNDO_MAX := 100
## The dialog's size.
const SIZE := Vector2(1200, 720)
## The backdrop over the editor.
const BACKDROP := Color(0.0, 0.0, 0.0, 0.45)
## Secondary text.
const DIM := Color(1.0, 1.0, 1.0, 0.55)
## Errors.
const ERROR := Color("ff8a80")
## Warnings.
const AMBER := Color("ffcc80")
## The panel's opacity.
const PANEL_ALPHA := 0.94
## Terrain3D Extended's modal group: while the dialog is in it, the overlay hides and the terrain takes no 3D input.
const UX_MODAL_GROUP := &"terrain_3d_ux_modal"

## ForestKit.
var kit = null
## The accent.
var accent := Color("8bc34a")
## Whether the edited scene has a forest.
var has_forest := false
## The edited scene's name.
var scene := ""
## Its folder (Create a profile… starts there).
var scene_dir := "res://"
## The fallback flora's pools ({"species", "dead"}).
var fallback := {}
## The flora Create a profile… copies (the config's default flora, else the starter's).
var default_flora := ""
## The profile (ForestProfile).
var profile = ProfileRes.new()
## "ok" | "read_only" | "no_forest" | "no_profile" | "missing" | "broken".
var state := ""
## "types" | "bands".
var tab := "types"
## The row selected: a type's id, 0 for the Defaults row.
var selected := 0
## The lane tile clicked, its weight shown: {"lane", "id"} ({}: none).
var lane_pick := {}
## The lane a click on the species strip adds to ("": the first lane shown).
var lane_focus := ""
## The species strip's search.
var strip_search := ""
## The species strip's filter: "all" | "trees" | "bushes".
var strip_filter := "all"
## A question asked: {"text", "action", "do": Callable} ({}: none).
var asking := {}
## What went wrong ("": nothing).
var error := ""
## What the last change did that is worth saying ("": nothing).
var note := ""
## What the forest refuses in the profile as it is (ForestTypes' errors).
var problems := PackedStringArray()
## (title, filters: PackedStringArray, start path, on_pick: Callable(path)) -> void: the plugin's save picker.
var pick_save := Callable()
## (path) -> void: the scene's forest takes this profile (one undo step in the scene's history).
var set_profile := Callable()
## () -> Array: the scene's import mapping's rules.
var rules_of := Callable()
var _undo: Array = []
var _redo: Array = []
var _panel: PanelContainer
var _content: VBoxContainer
var _rebuilding := false
var _pending: Array = []           # [id, key, value] handed to set_value during a rebuild: applied after it
var _type_menu: PopupMenu = null


## The context (context_for's and the plugin's callables); reads the profile, builds the view.
func setup(p: Dictionary) -> void:
	kit = p["kit"]
	accent = p.get("accent", accent)
	has_forest = bool(p.get("has_forest", false))
	scene = String(p.get("scene", ""))
	scene_dir = String(p.get("scene_dir", "res://"))
	fallback = p.get("fallback", {})
	default_flora = String(p.get("default_flora", ""))
	pick_save = p.get("pick_save", Callable())
	set_profile = p.get("set_profile", Callable())
	rules_of = p.get("rules_of", Callable())
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
	load_profile(String(p.get("profile_path", "")))
	rebuild()


## The context for the edited scene's forest (`forest`, null: none) built with `p_kit` (a ForestKit): its scene's name and
## folder, its profile, the fallback flora's pools and the flora Create a profile… copies.
static func context_for(forest: Node, p_kit) -> Dictionary:
	var cfg := ForestConfig.current()
	var flora := cfg.default_profile_path
	if flora == "" or not FileAccess.file_exists(flora):
		flora = cfg.starter_flora_path()
	var ctx := {"kit": p_kit, "has_forest": forest != null, "scene": "", "scene_dir": "res://", "profile_path": "",
		"fallback": SpawnerRes._fallback_pools(), "default_flora": flora}
	if forest == null:
		return ctx
	var root: Node = forest.owner if forest.owner != null else forest
	var sp := root.scene_file_path
	ctx["scene"] = sp.get_file().get_basename() if sp != "" else String(root.name)
	ctx["scene_dir"] = sp.get_base_dir() if sp != "" else "res://"
	ctx["profile_path"] = String(forest.profile_path)
	return ctx


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		add_to_group(UX_MODAL_GROUP)
		top_level = true
		set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	elif what == NOTIFICATION_RESIZED and _panel != null and is_inside_tree():
		_panel.custom_minimum_size = SIZE.min(get_viewport_rect().size - Vector2(40.0, 40.0))


# --- the model ---

## Read profile `path` again: its state, the forest's problems with it, the first type selected; what its first write
## converts, said.
func load_profile(path: String) -> void:
	profile = ProfileRes.new()
	profile.path = path
	problems = PackedStringArray()
	note = ""
	selected = 0
	lane_pick = {}
	lane_focus = ""
	if not has_forest:
		state = "no_forest"
		return
	if path == "":
		state = "no_profile"
		return
	if not FileAccess.file_exists(path):
		state = "missing"
		return
	if profile.open(path, fallback) != OK:
		state = "broken"
		return
	state = "read_only" if ProfileRes.is_read_only(path) else "ok"
	problems = profile.load_errors()
	var ids: PackedInt32Array = profile.type_ids()
	selected = ids[0] if not ids.is_empty() else 0
	if state == "ok" and not profile.converted.is_empty():
		note = "Its first change also converts: %s." % "; ".join(profile.converted)


## Whether the profile can be changed here.
func editable() -> bool:
	return state == "ok"


# --- every change one undo step ---

## One undo step: `fn` changes the profile and returns "" (done) or why not (nothing changed then). The profile is
## written at once; a failed write is said and undone. Ignored while rebuilding; refused while the profile cannot be
## changed here.
func change(fn: Callable) -> bool:
	if _rebuilding:
		return false
	if not editable():
		error = "Read-only: save a copy for this map first." if state == "read_only" else "There is no profile to change."
		rebuild()
		return false
	var before: Dictionary = profile.snapshot()
	var why: String = fn.call()
	if why != "":
		profile.restore(before)
		error = why
		rebuild()
		return false
	if profile.doc == before:
		rebuild()
		return false
	if profile.write() != OK:
		profile.restore(before)
		error = "Not written: %s." % profile.problem
		rebuild()
		return false
	error = ""
	note = ("Converted on this first write: %s." % "; ".join(profile.converted)) if not profile.converted.is_empty() else ""
	profile.converted = PackedStringArray()
	_undo.append(before)
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()
	_redo.clear()
	_changed()
	return true


## Undo the last change (the file written back).
func undo() -> void:
	_step(_undo, _redo)


## Redo the last undone change.
func redo() -> void:
	_step(_redo, _undo)


func _step(from: Array, to: Array) -> void:
	if from.is_empty() or not editable():
		return
	var now: Dictionary = profile.snapshot()
	var was: Dictionary = from.pop_back()
	profile.restore(was)
	if profile.write() != OK:
		profile.restore(now)
		from.append(was)
		error = "Not written: %s." % profile.problem
		rebuild()
		return
	error = ""
	note = ""
	to.append(now)
	_changed()


func _changed() -> void:
	problems = profile.load_errors()
	changed.emit()
	rebuild()


## The selection after a change: a type that is gone falls back to the first (the Defaults row when there is none); a
## picked lane tile whose lane or species is gone is let go.
func _fix_selection() -> void:
	if selected != 0 and profile.type_of(selected).is_empty():
		var ids: PackedInt32Array = profile.type_ids()
		selected = ids[0] if not ids.is_empty() else 0
	if not lane_pick.is_empty():
		var lane := String(lane_pick["lane"])
		var shown: Array = ProfileRes.with_dead(lanes_shown())
		if not shown.has(lane) or not ProfileRes.names_in(profile.lane_of(selected, lane)["entries"]).has(String(lane_pick["id"])):
			lane_pick = {}


## The lanes the selected row shows: a type's by its style, the Defaults row's every default pool.
func lanes_shown() -> Array:
	if selected == 0:
		return ProfileRes.DEFAULT_LANES.duplicate()
	return ProfileRes.lanes_for(str(profile.value_of(selected, "style")))


# --- the list ---

## Select row `id` (0: the Defaults row).
func select(id: int) -> void:
	selected = id
	lane_pick = {}
	lane_focus = ""
	rebuild()


## The Types or the Bands tab.
func set_tab(t: String) -> void:
	tab = t
	rebuild()


## + New type: one undo step, the new type selected.
func new_type() -> void:
	var id: int = profile.next_id()
	if id == 0:
		error = "Every type id (1-255) is taken."
		rebuild()
		return
	var keep := selected
	selected = id
	if not change(func() -> String:
		profile.add_type()
		return ""):
		selected = keep
		rebuild()


## Type `id` duplicated right after it; the copy selected.
func duplicate_type(id: int) -> void:
	var nid: int = profile.next_id()
	if nid == 0 or profile.type_of(id).is_empty():
		return
	var keep := selected
	selected = nid
	if not change(func() -> String:
		profile.duplicate_type(id)
		return ""):
		selected = keep
		rebuild()


## Delete type `id`: asks first, saying what its painted texels do and which import rules paint it.
func delete_type(id: int, confirmed := false) -> void:
	var t: Dictionary = profile.type_of(id)
	if t.is_empty():
		return
	if not confirmed:
		var rules := rules_painting(id)
		asking = {"text": "Delete %s (id %d)? Texels painted with it keep id %d and grow nothing until a type takes that id again.%s" % [
			str(t.get("name", "")), id, id, (" Painted by %s." % ", ".join(rules)) if not rules.is_empty() else ""],
			"action": "Delete", "do": delete_type.bind(id, true)}
		rebuild()
		return
	asking = {}
	var keep := selected
	if selected == id:
		selected = _neighbour(id)
	if not change(func() -> String: return profile.delete_type(id)):
		selected = keep
		rebuild()


## The type next to `id` in the list (the one after it, else before it; 0 when it is the only one).
func _neighbour(id: int) -> int:
	var ids := Array(profile.type_ids())
	var i := ids.find(id)
	if ids.size() <= 1 or i < 0:
		return 0
	return int(ids[i + 1]) if i + 1 < ids.size() else int(ids[i - 1])


## Type `src` dropped on type `onto`'s row: it takes that row's place in the list.
func move_type(src: int, onto: int) -> void:
	if src == onto:
		return
	change(func() -> String: return profile.move_type(src, profile.index_of(onto)))


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


## A type row's menu at screen position `at`: Duplicate, Delete.
func open_type_menu(id: int, at: Vector2) -> void:
	if _type_menu != null and is_instance_valid(_type_menu):
		_type_menu.queue_free()
	_type_menu = PopupMenu.new()
	_type_menu.add_item("Duplicate", MENU_DUPLICATE)
	_type_menu.add_item("Delete", MENU_DELETE)
	for i in _type_menu.item_count:
		_type_menu.set_item_disabled(i, not editable())
	_type_menu.id_pressed.connect(func(item: int) -> void: type_menu_action(id, item))
	add_child(_type_menu)
	_type_menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


## A type row's menu item picked.
func type_menu_action(id: int, item: int) -> void:
	if item == MENU_DUPLICATE:
		duplicate_type(id)
	elif item == MENU_DELETE:
		delete_type(id)


## The scene's import rules that paint type `id`: "import rule 2", ….
func rules_painting(id: int) -> PackedStringArray:
	var out := PackedStringArray()
	var rules = rules_of.call() if rules_of.is_valid() else []
	if not (rules is Array):
		return out
	for i in (rules as Array).size():
		var rl = rules[i]
		if rl is Dictionary and typeof(rl.get("type")) in [TYPE_INT, TYPE_FLOAT] and int(rl["type"]) == id:
			out.append("import rule %d" % (i + 1))
	return out


## A type row's second line: "natural · 0.038 /m²", "grid · 7 m".
func type_info(id: int) -> String:
	var style := str(profile.value_of(id, "style"))
	if style == "grid":
		return "grid · %s m" % num(float(profile.value_of(id, "pitch_m")), 2)
	return "%s · %s /m²" % [style, num(float(profile.value_of(id, "density_per_m2")), 4)]


## Type `id`'s icon: its own, else by its style (ForestTypeTile.icon_of).
func icon_for(id: int) -> String:
	return TypeTileRes.icon_of(profile.type_of(id), profile.lane_of(id, "mid")["entries"], crown_of)


## Type `id`'s colour: its own, else its id's.
func colour_for(id: int) -> Color:
	return TypeTileRes.colour_of(profile.type_of(id))


## A species' crown ("" when the forest's packs do not have it).
func crown_of(sp_id: String) -> String:
	var sp = VA.species_of(sp_id)
	return String(sp.crown) if sp != null else ""


## `v` with at most `decimals` decimals, the trailing zeros dropped: 0.04, 7, 0.0029.
static func num(v: float, decimals: int) -> String:
	var s := ("%." + str(decimals) + "f") % v
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s


# --- a type's settings ---

## Type `id`'s setting `key` set to `value` (ForestProfile.set_value): one undo step. A text field losing its focus to
## the rebuild that takes it down hands its edit over here: it is applied once the rebuild is done, not dropped.
func set_value(id: int, key: String, value) -> void:
	if _rebuilding:
		_pending.append([id, key, value])
		if _pending.size() == 1:
			_apply_pending.call_deferred()
		return
	var t: Dictionary = profile.type_of(id)
	if t.has(key) and typeof(t[key]) == typeof(value) and t[key] == value:
		return
	change(func() -> String: return profile.set_value(id, key, value))


## The edits set_value was handed during a rebuild, applied now.
func _apply_pending() -> void:
	var todo := _pending
	_pending = []
	for e in todo:
		set_value(int(e[0]), String(e[1]), e[2])


## Type `id`'s style (ForestProfile.set_style): one undo step.
func set_style(id: int, style: String) -> void:
	lane_pick = {}
	change(func() -> String: return profile.set_style(id, style))


## What type `id` grows, in words, and which import rules paint it: "One tree every 5.1 m · painted by import rule 2".
func footer_text(id: int) -> String:
	var style := str(profile.value_of(id, "style"))
	var grows := ""
	if style == "grid":
		grows = "A tree every %s m on a grid" % num(float(profile.value_of(id, "pitch_m")), 2)
	else:
		var dn := float(profile.value_of(id, "density_per_m2"))
		grows = ("One %s every %.1f m" % ["bush" if style == "bushes" else "tree", 1.0 / sqrt(dn)]) if dn > 0.0 \
			else "Grows nothing: no density"
	var rules := rules_painting(id)
	return "%s · %s" % [grows, ("painted by " + ", ".join(rules)) if not rules.is_empty() else "no import rule paints it"]


## Which types grow the map's defaults, and in which lanes: "Inherited by: Wood (mid, high), Garden (trees)".
func inheritors_text() -> String:
	var parts := PackedStringArray()
	for id in profile.type_ids():
		var t: Dictionary = profile.type_of(id)
		var lanes := PackedStringArray()
		for lane in ProfileRes.lanes_for(str(t.get("style", ""))):
			if String(profile.lane_of(id, lane)["from"]) != "own":
				lanes.append(lane)
		if not lanes.is_empty():
			parts.append("%s (%s)" % [str(t.get("name", "")), ", ".join(lanes)])
	return "Inherited by: " + (", ".join(parts) if not parts.is_empty() else "no type: every lane has a mix of its own.")


# --- the lanes ---

## Whether lane `lane` of the selected row inherits: a type's without its own mix, a default the profile lacks.
func inheriting(lane: String) -> bool:
	var from := String(profile.lane_of(selected, lane)["from"])
	return from != "map" if selected == 0 else from != "own"


## A lane's band or role: "0-150 m", "the understory", "on a 7 m grid".
func lane_range(lane: String) -> String:
	var b: Dictionary = profile.bands()
	match lane:
		"coast":
			return "0-%d m" % int(b["coast_top_m"])
		"mid":
			return "%d-%d m" % [int(b["coast_top_m"]), int(b["mid_top_m"])]
		"high":
			return "%d-%d m" % [int(b["mid_top_m"]), int(b["treeline_m"])]
		"bush":
			return "the understory" if str(profile.value_of(selected, "style")) == "natural" else ""
		"grid":
			return "on a %s m grid" % num(float(profile.value_of(selected, "pitch_m")), 2) if selected != 0 else "the orchard pool"
	return ""


## What an inheriting lane grows, said: the map's default, the project's, or nothing.
func inherit_text(lane: String) -> String:
	var cur: Dictionary = profile.lane_of(selected, lane)
	var who := str(profile.type_of(selected).get("name", "this type"))
	match String(cur["from"]):
		"map":
			return "The map's default mix (pool %s): add a species to give %s its own." % [cur["pool"], who]
		"fallback":
			if selected == 0:
				return "The project's default (pool %s of the fallback flora): add a species to set this map's own." % cur["pool"]
			return "The project's default (pool %s of the fallback flora): add a species to give %s its own." % [cur["pool"], who]
	if ProfileRes.is_dead(lane):
		return "No dead trees here."
	return "No pool %s in the profile or the fallback flora: add a species to give this lane a mix." % cur["pool"]


## Why species `id` grows nowhere ("" when it grows): "switched off", or "in no species pack".
func species_why(id: String) -> String:
	if VA.species_of(id) != null:
		return ""
	return "switched off" if VA.is_disabled(id) else "in no species pack"


## Species `id`'s picture: its build's, else its crown's glyph; a broadleaf glyph when no pack has it.
func picture_of(id: String) -> Texture2D:
	var sp = VA.species_of(id)
	return PicturesRes.of(sp, VA.built_dir_of(id)) if sp != null else PicturesRes.glyph("broadleaf")


## Species `sp` added to lane `lane` of the selected row: one undo step.
func add_to_lane(lane: String, sp: String) -> void:
	lane_focus = lane
	change(func() -> String: return profile.add_to_lane(selected, lane, sp))


## Species `sp` taken out of lane `lane`: one undo step.
func remove_from_lane(lane: String, sp: String) -> void:
	lane_pick = {}
	change(func() -> String: return profile.remove_from_lane(selected, lane, sp))


## Species `sp`'s weight in lane `lane`: one undo step.
func set_weight(lane: String, sp: String, w: float) -> void:
	change(func() -> String: return profile.set_weight(selected, lane, sp, w))


## Species `sp` moved from lane `from_lane` to `to_lane` (onto its own lane: nothing): one undo step.
func move_tile(from_lane: String, to_lane: String, sp: String) -> void:
	if from_lane == to_lane:
		return
	lane_pick = {}
	change(func() -> String: return profile.move_between(selected, from_lane, to_lane, sp))


## Lane `lane` set to a copy of lane `from_lane` of type `from_id` (0: the default): one undo step.
func copy_lane(lane: String, from_id: int, from_lane: String) -> void:
	change(func() -> String: return profile.copy_lane(selected, lane, from_id, from_lane))


## Lane `lane` back to what it inherits: one undo step.
func reset_lane(lane: String) -> void:
	lane_pick = {}
	change(func() -> String: return profile.reset_lane(selected, lane))


## A drop on lane `lane`: a species from the strip joins it, a lane's tile moves to it.
func drop_on_lane(lane: String, kind: String, id: String) -> void:
	if kind == StripRes.KIND:
		add_to_lane(lane, id)
	elif kind == LANE_KIND:
		move_tile(id.get_slice("|", 0), lane, id.get_slice("|", 1))


## A lane's tile dropped outside every lane: it leaves its lane.
func drop_out(kind: String, id: String) -> void:
	if kind == LANE_KIND:
		remove_from_lane(id.get_slice("|", 0), id.get_slice("|", 1))


## A lane's tile clicked: its weight and ✕ (clicked again: hidden); its lane takes the focus.
func pick_tile(lane: String, sp: String) -> void:
	var same := String(lane_pick.get("lane", "")) == lane and String(lane_pick.get("id", "")) == sp
	lane_pick = {} if same else {"lane": lane, "id": sp}
	lane_focus = lane
	rebuild()


## The lane a click on the strip adds to.
func focus_lane(lane: String) -> void:
	lane_focus = lane
	rebuild()


## The lane in focus by name ("Coast", "Dead (mid)"): the first lane shown when none is.
func focus_title() -> String:
	var lanes := lanes_shown()
	if not ProfileRes.with_dead(lanes).has(lane_focus):
		return LanesRes.lane_title(String(lanes[0])) if not lanes.is_empty() else "a lane"
	return LanesRes.lane_title(lane_focus)


## Lanes of the same kind as `lane` that Copy from… offers, [{"text", "id", "lane"}]: the default first (a type
## selected), then every other type's.
func copy_sources(lane: String) -> Array:
	var kind := ProfileRes.kind_of(lane)
	var out := []
	if selected != 0:
		out.append({"text": "The default (pool %s)" % ProfileRes.default_pool(lane), "id": 0, "lane": lane})
	for id in profile.type_ids():
		if id == selected:
			continue
		var t: Dictionary = profile.type_of(id)
		for l in ProfileRes.with_dead(ProfileRes.lanes_for(str(t.get("style", "")))):
			if ProfileRes.kind_of(String(l)) == kind:
				out.append({"text": "%s · %s" % [str(t.get("name", "")), LanesRes.lane_title(String(l))], "id": id,
					"lane": String(l)})
	return out


# --- the species strip ---

## The species the strip shows: every species the forest grows (its packs' minus the switched-off ones), narrowed by
## the search (id or display name) and the filter.
func strip_ids() -> PackedStringArray:
	var q := strip_search.strip_edges().to_lower()
	var out := PackedStringArray()
	for id in VA.species_ids():
		var sp = VA.species_of(id)
		if sp == null:
			continue
		if q != "" and not String(id).to_lower().contains(q) and not String(sp.display_name).to_lower().contains(q):
			continue
		if strip_filter == "trees" and String(sp.kind) == "bush":
			continue
		if strip_filter == "bushes" and String(sp.kind) != "bush":
			continue
		out.append(id)
	return out


## A strip tile clicked: it joins the lane in focus (the first lane shown when none is).
func strip_click(id: String) -> void:
	var lanes := lanes_shown()
	if not ProfileRes.with_dead(lanes).has(lane_focus):
		lane_focus = String(lanes[0]) if not lanes.is_empty() else ""
	if lane_focus != "":
		add_to_lane(lane_focus, id)


## A search keystroke: the view is rebuilt after the field's signal (never inside it) and the new field keeps the typing.
func strip_search_changed(t: String) -> void:
	strip_search = t
	_apply_strip_search.call_deferred()


func _apply_strip_search() -> void:
	rebuild()
	var f := _content.find_child("StripSearch", true, false) as LineEdit
	if f != null and f.is_inside_tree():
		f.grab_focus()
		f.caret_column = f.text.length()


## Show only some species in the strip.
func set_strip_filter(f: String) -> void:
	strip_filter = f
	rebuild()


# --- a profile of its own ---

## Create a profile… (none, or its file is missing) and Save a copy for this map… (a read-only one): the plugin's save
## picker in the scene's folder, then copy_profile_to.
func save_copy() -> void:
	if not pick_save.is_valid():
		return
	var nm := scene if scene != "" else "forest"
	var start: String = profile.path if state == "missing" else scene_dir.path_join("%s_flora.json" % nm)
	pick_save.call("A flora profile for %s" % nm, PackedStringArray(["*.json ; Flora profiles"]), start, copy_profile_to)


## The profile shown when it is read-only, else the default flora, copied to `dst`, set as the scene's forest's profile
## (one undo step in the scene's history) and opened. False when it could not be (said).
func copy_profile_to(dst: String) -> bool:
	var src: String = profile.path if state == "read_only" else default_flora
	if src == "" or not FileAccess.file_exists(src):
		error = "No flora to copy (%s)." % (src if src != "" else "none")
		rebuild()
		return false
	if ProfileRes.is_read_only(dst) or not dst.ends_with(".json"):
		error = "%s: pick a .json file in the project, outside Wuifwoud." % dst
		rebuild()
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst.get_base_dir()))
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		error = "Could not write %s (%s)." % [dst, error_string(FileAccess.get_open_error())]
		rebuild()
		return false
	f.store_string(FileAccess.get_file_as_string(src))
	f.close()
	if set_profile.is_valid():
		set_profile.call(dst)
	_undo.clear()
	_redo.clear()
	error = ""
	load_profile(dst)
	note = "Wrote %s, a copy of %s, and set it as this forest's profile.%s" % [dst, src.get_file(),
		(" " + note) if note != "" else ""]
	rebuild()
	return true


## Read the profile from its file again (after an edit outside the dialog); the undo steps go.
func reopen() -> void:
	_undo.clear()
	_redo.clear()
	error = ""
	load_profile(profile.path)
	rebuild()


# --- the view ---

## Rebuilds the view from the model. Scroll positions are kept.
func rebuild() -> void:
	_rebuilding = true
	_fix_selection()
	var scrolls := {}
	for sc in _content.find_children("*", "ScrollContainer", true, false):
		scrolls[String(sc.name)] = Vector2i((sc as ScrollContainer).scroll_horizontal, (sc as ScrollContainer).scroll_vertical)
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	_content.add_child(_header())
	if error != "":
		var e: Label = hint(error)
		e.name = "Error"
		e.modulate = Color.WHITE
		e.add_theme_color_override("font_color", ERROR)
		_content.add_child(e)
		if profile.problem.contains("changed on disk"):
			var ro: Button = kit.chip("Reopen", false, accent)
			ro.name = "Reopen"
			ro.size_flags_horizontal = SIZE_SHRINK_BEGIN
			ro.pressed.connect(reopen)
			_content.add_child(ro)
	if note != "":
		var n: Label = hint(note)
		n.name = "Note"
		_content.add_child(n)
	if not problems.is_empty():
		var pr: Label = hint("The forest refuses: " + "; ".join(problems))
		pr.name = "Problems"
		pr.modulate = Color.WHITE
		pr.add_theme_color_override("font_color", AMBER)
		_content.add_child(pr)
	if not asking.is_empty():
		var q: PanelContainer = kit.banner(String(asking["text"]), String(asking.get("action", "")), ERROR)
		q.name = "Question"
		(q.find_child("Action", true, false) as Button).pressed.connect(confirm_question)
		var no: Button = kit.chip("Cancel", false, accent)
		no.name = "Cancel"
		no.pressed.connect(cancel_question)
		q.get_child(0).add_child(no)
		_content.add_child(q)
	_content.add_child(_body())
	for sc in _content.find_children("*", "ScrollContainer", true, false):
		if scrolls.has(String(sc.name)):
			(sc as ScrollContainer).set_deferred("scroll_horizontal", scrolls[String(sc.name)].x)
			(sc as ScrollContainer).set_deferred("scroll_vertical", scrolls[String(sc.name)].y)
	_rebuilding = false


func _header() -> Control:
	var h := HBoxContainer.new()
	h.name = "Header"
	h.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "FOREST TYPES"
	title.add_theme_color_override("font_color", accent)
	title.add_theme_font_size_override("font_size", 13)
	h.add_child(title)
	var info := Label.new()
	info.name = "Info"
	info.text = "· %s · %s" % [scene if scene != "" else "no scene", profile.path if profile.path != "" else "no profile"]
	info.modulate = DIM
	info.clip_text = true
	info.size_flags_horizontal = SIZE_EXPAND_FILL
	h.add_child(info)
	var g := ButtonGroup.new()
	for pair in [["Types", "types"], ["Bands", "bands"]]:
		var b: Button = kit.toggle_chip(String(pair[0]), tab == String(pair[1]), accent)
		b.name = "Tab_" + String(pair[1])
		b.button_group = g
		b.disabled = not (state in ["ok", "read_only"])
		b.pressed.connect(set_tab.bind(String(pair[1])))
		h.add_child(b)
	h.add_child(_button("Undo", "↶", undo, _undo.is_empty()))
	h.add_child(_button("Redo", "↷", redo, _redo.is_empty()))
	h.add_child(_button("Close", "✕", close, false))
	return h


func _body() -> Control:
	match state:
		"no_forest":
			return _message("No forest in this scene: add a ForestSpawner node (Wuifwoud) to edit its types.", "")
		"no_profile":
			return _message("This forest names no flora profile, so its maps grow nothing. Create a profile… writes a copy of the project's default flora (%s) beside the scene and sets it." % default_flora.get_file(), "Create a profile…")
		"missing":
			return _message("The forest's profile %s does not exist. Create a profile… writes a copy of the project's default flora and sets it." % profile.path, "Create a profile…")
		"broken":
			return _message("%s does not read: %s. Fix it in a text editor: this dialog never writes it." % [profile.path, profile.problem], "")
	var v := VBoxContainer.new()
	v.name = "Main"
	v.size_flags_vertical = SIZE_EXPAND_FILL
	if state == "read_only":
		v.add_child(_message("%s ships inside Wuifwoud, so it is read-only here. Save a copy for this map… writes a copy beside the scene and sets it." % profile.path.get_file(), "Save a copy for this map…"))
	if tab == "bands":
		v.add_child(_bands())
		return v
	var body := HBoxContainer.new()
	body.name = "Body"
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	body.add_child(ListRes.build(self))
	body.add_child(_panel_column())
	body.add_child(_lanes_column())
	v.add_child(body)
	return v


## The middle column: the selected row's settings.
func _panel_column() -> Control:
	return PanelRes.build(self)


## The right column: the selected row's lanes and the species strip.
func _lanes_column() -> Control:
	return LanesRes.build(self)


## The Bands tab: empty until it is built.
func _bands() -> Control:
	var v := VBoxContainer.new()
	v.name = "Bands"
	return v


## A message in place of the columns, with Create a profile… or Save a copy… as its action ("": none).
func _message(text: String, action: String) -> Control:
	var v := VBoxContainer.new()
	v.name = "Message"
	var l: Label = hint(text)
	l.name = "MessageText"
	l.modulate = Color.WHITE
	v.add_child(l)
	if action != "":
		var b: Button = kit.chip(action, false, accent)
		b.name = "MessageAction"
		b.size_flags_horizontal = SIZE_SHRINK_BEGIN
		b.disabled = not pick_save.is_valid()
		b.pressed.connect(save_copy)
		v.add_child(b)
	return v


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


## Close the dialog.
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
		elif not lane_pick.is_empty():
			lane_pick = {}
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
