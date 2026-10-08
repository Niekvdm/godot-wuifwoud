# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Types dialog's right column: the selected row's lanes (a type's by its style, the Defaults row's every default
## pool), a band's with its dead trees under it. A lane that inherits is dimmed and says from where. A lane shows a
## stacked bar of its shares and a tile a species: its picture and weight, a red frame when the species is switched off
## or in no pack. Drop a species from the strip to add it; drag a tile onto another lane to move it, or out of the lanes
## to take it out; click a tile for its weight and ✕. Copy from… and Reset on each lane. The species strip under them.

## A lane row and the column are drop targets.
const DropRes := preload("res://addons/wuifwoud/editor/common/forest_drop_target.gd")
## A lane's species tile (a drag tile).
const TileRes := preload("res://addons/wuifwoud/editor/forest_value_tile.gd")
## The species strip.
const StripRes := preload("res://addons/wuifwoud/editor/types/forest_species_strip.gd")
## The profile (its lanes).
const ProfileRes := preload("res://addons/wuifwoud/forest_profile.gd")
## The lanes' names.
const LANE_TITLES := {"coast": "Coast", "mid": "Mid", "high": "High", "bush": "Bushes", "grid": "Grid trees",
	"trees": "Trees"}
## A lane tile's size.
const TILE := Vector2(48, 62)
## A lane row's fill.
const FILL := Color(1.0, 1.0, 1.0, 0.035)
## An inheriting lane's opacity.
const INHERITED_ALPHA := 0.5


## The column for the dialog `d`: a drop target taking a lane tile out of its lane, the lanes, the strip.
static func build(d) -> Control:
	var outer: PanelContainer = DropRes.new().setup([d.LANE_KIND], d.drop_out, d.box(Color(0, 0, 0, 0)),
		d.box(Color(d.ERROR, 0.08), d.ERROR))
	outer.name = "Lanes"
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_stretch_ratio = 1.6
	outer.tooltip_text = "Drop a lane's species here to take it out of its lane"
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_theme_constant_override("separation", 6)
	var sc := ScrollContainer.new()
	sc.name = "LaneScroll"
	sc.mouse_filter = Control.MOUSE_FILTER_PASS
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var col := VBoxContainer.new()
	col.name = "LaneList"
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	for lane in d.lanes_shown():
		col.add_child(_lane(d, String(lane)))
	sc.add_child(col)
	v.add_child(sc)
	v.add_child(StripRes.build(d))
	outer.add_child(v)
	return outer


## A lane's name: "Coast", "Dead (mid)", "Grid trees".
static func lane_title(lane: String) -> String:
	if ProfileRes.is_dead(lane):
		return "Dead (%s)" % lane.substr(5)
	return String(LANE_TITLES.get(lane, lane.capitalize()))


## A stacked bar of a lane's shares: a segment a species, as wide as its weight.
static func bar(entries: Array) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.name = "Bar"
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.custom_minimum_size = Vector2(0, 8)
	h.add_theme_constant_override("separation", 0)
	for e in entries:
		var nm := str(e[0]) if typeof(e) == TYPE_ARRAY else str(e)
		var c := ColorRect.new()
		c.color = shade(nm)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.size_flags_stretch_ratio = maxf(float(e[1]) if typeof(e) == TYPE_ARRAY and (e as Array).size() > 1 else 1.0, 0.01)
		c.tooltip_text = nm
		h.add_child(c)
	return h


## A species' colour in a bar: a fixed hue per id.
static func shade(id: String) -> Color:
	return Color.from_hsv(fposmod(float(hash(id) % 997) / 997.0, 1.0), 0.45, 0.62)


static func _lane(d, lane: String) -> Control:
	var box := VBoxContainer.new()
	box.name = "Lane_" + lane
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_theme_constant_override("separation", 3)
	var head := HBoxContainer.new()
	head.name = "Head"
	head.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.name = "Title"
	title.text = lane_title(lane)
	head.add_child(title)
	var rng := Label.new()
	rng.name = "Range"
	rng.text = d.lane_range(lane)
	rng.modulate = d.DIM
	rng.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(rng)
	head.add_child(_copy_menu(d, lane))
	if not d.inheriting(lane):
		var rs: Button = d.kit.chip("Reset", false, d.accent)
		rs.name = "Reset"
		rs.tooltip_text = "Drop this lane's own mix: it inherits again"
		rs.disabled = not d.editable()
		rs.pressed.connect(d.reset_lane.bind(lane))
		head.add_child(rs)
	box.add_child(head)
	box.add_child(_row(d, lane))
	if lane in ["coast", "mid", "high"]:
		box.add_child(_row(d, ProfileRes.dead_lane(lane)))
	return box


## A lane's row (its trees, or a band's dead trees): a drop target with its bar, its tiles and what it says.
static func _row(d, lane: String) -> Control:
	var cur: Dictionary = d.profile.lane_of(d.selected, lane)
	var entries: Array = cur["entries"]
	var inh: bool = d.inheriting(lane)
	var focus: bool = d.lane_focus == lane
	var target: PanelContainer = DropRes.new().setup([StripRes.KIND, d.LANE_KIND],
		func(kind: String, id: String) -> void: d.drop_on_lane(lane, kind, id),
		d.box(FILL, d.accent if focus else Color(0, 0, 0, 0)), d.box(Color(d.accent, 0.1), d.accent))
	target.name = "Drop_" + lane.replace(".", "_")      # a node name takes no "."
	# Deferred: a click on a tile reaches its row too, and the tile must still be there for its own `pressed`.
	target.pressed.connect(d.focus_lane.bind(lane), CONNECT_DEFERRED)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 3)
	target.add_child(v)
	var dead := ProfileRes.is_dead(lane)
	if dead:
		var dh := HBoxContainer.new()
		dh.name = "DeadHead"
		dh.add_theme_constant_override("separation", 8)
		var dl := Label.new()
		dl.text = "Dead trees"
		dl.modulate = d.DIM
		dl.add_theme_font_size_override("font_size", 10)
		dl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dh.add_child(dl)
		dh.add_child(_copy_menu(d, lane))
		if not inh:
			var rs: Button = d.kit.chip("Reset", false, d.accent)
			rs.name = "Reset"
			rs.tooltip_text = "Drop this row's own dead trees: it inherits again"
			rs.disabled = not d.editable()
			rs.pressed.connect(d.reset_lane.bind(lane))
			dh.add_child(rs)
		v.add_child(dh)
	elif not entries.is_empty():
		v.add_child(bar(entries))
	var flow := HFlowContainer.new()
	flow.name = "Tiles"
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for e in entries:
		flow.add_child(_tile(d, lane, e))
	v.add_child(flow)
	if inh:
		v.add_child(d.hint(d.inherit_text(lane)))
	elif entries.is_empty():
		v.add_child(d.hint("No dead trees here." if dead else "Empty: this lane grows nothing."))
	var bad := PackedStringArray()
	for nm in ProfileRes.names_in(entries):
		var why: String = d.species_why(nm)
		if why != "":
			bad.append("%s is %s" % [nm, why])
	if not bad.is_empty():
		var bl: Label = d.hint("; ".join(bad) + ".")
		bl.name = "Bad"
		bl.modulate = Color.WHITE
		bl.add_theme_color_override("font_color", d.ERROR)
		v.add_child(bl)
	if String(d.lane_pick.get("lane", "")) == lane:
		v.add_child(_pick_row(d, lane, entries))
	target.modulate.a = INHERITED_ALPHA if inh else 1.0
	return target


## A species' tile in a lane: its picture, its weight ("dead" in a dead row), a red frame when it grows nowhere, the
## accent frame when picked. Drag it to move it; click it for its weight and ✕.
static func _tile(d, lane: String, e) -> Button:
	var nm := str(e[0]) if typeof(e) == TYPE_ARRAY else str(e)
	var dead := ProfileRes.is_dead(lane)
	var w := float(e[1]) if typeof(e) == TYPE_ARRAY and (e as Array).size() > 1 else 1.0
	var t: Button = TileRes.new().setup(d.LANE_KIND, lane + "|" + nm, "dead" if dead else d.num(w, 1))
	t.name = "LaneTile_" + nm.validate_node_name()
	t.icon = d.picture_of(nm)
	t.expand_icon = true
	t.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	t.alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.custom_minimum_size = TILE
	t.disabled = not d.editable()
	var why: String = d.species_why(nm)
	var picked: bool = String(d.lane_pick.get("lane", "")) == lane and String(d.lane_pick.get("id", "")) == nm
	t.tooltip_text = nm.replace("_", " ") + ((" · " + why) if why != "" else "")
	if why != "" or picked:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, 0.05)
		sb.set_border_width_all(2)
		sb.border_color = d.ERROR if why != "" else d.accent
		sb.set_corner_radius_all(6)
		for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			t.add_theme_stylebox_override(s, sb)
	if why != "":
		t.set_meta("why", why)
	t.pressed.connect(d.pick_tile.bind(lane, nm))
	return t


## The picked tile's weight (a weighted lane) and ✕.
static func _pick_row(d, lane: String, entries: Array) -> Control:
	var sp := String(d.lane_pick["id"])
	var h := HBoxContainer.new()
	h.name = "Pick"
	h.add_theme_constant_override("separation", 8)
	if not ProfileRes.is_dead(lane):
		var w := 1.0
		for e in entries:
			if typeof(e) == TYPE_ARRAY and str(e[0]) == sp and (e as Array).size() > 1:
				w = float(e[1])
		var row: VBoxContainer = d.kit.slider_row(sp.replace("_", " "), ProfileRes.WEIGHT_MIN, ProfileRes.WEIGHT_MAX, 0.1,
			w, "", d.accent)
		row.name = "Weight"
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var s := row.get_node("Slider") as HSlider
		s.scrollable = false
		s.drag_ended.connect(func(moved: bool) -> void:
			if moved:
				d.set_weight(lane, sp, s.value))
		h.add_child(row)
	else:
		var l := Label.new()
		l.text = sp.replace("_", " ")
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
	var rm: Button = d.kit.chip("✕", false, d.accent)
	rm.name = "Remove"
	rm.tooltip_text = "Take %s out of this lane" % sp
	rm.disabled = not d.editable()
	rm.pressed.connect(d.remove_from_lane.bind(lane, sp))
	h.add_child(rm)
	return h


## Copy from…: the other types' lanes of the same kind, the default first.
static func _copy_menu(d, lane: String) -> Control:
	var srcs: Array = d.copy_sources(lane)
	var items := []
	for i in srcs.size():
		items.append({"id": i, "text": String(srcs[i]["text"])})
	var m = d.kit.menu_chip("Copy from…", items, d.accent, func(i: int) -> void:
		if i >= 0 and i < srcs.size():
			d.copy_lane(lane, int(srcs[i]["id"]), String(srcs[i]["lane"])))
	m.name = "CopyFrom"
	m.disabled = not d.editable() or srcs.is_empty()
	return m
