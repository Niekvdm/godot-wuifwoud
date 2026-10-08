# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Import dialog's Rules tab: the source's values for one property key (drag one onto a rule, onto "a new rule",
## or back here to take it out of its rules), the rules in priority order (the first rule a
## feature matches paints it; drag a row's ≡ onto another row to move it there), No rule last, and the selected rule
## (the inspector).

## A drop target.
const DropRes := preload("res://addons/wuifwoud/editor/forest_drop_target.gd")
## A value tile.
const TileRes := preload("res://addons/wuifwoud/editor/forest_value_tile.gd")
## The rule inspector.
const InspectorRes := preload("res://addons/wuifwoud/editor/forest_rule_inspector.gd")
## The drag kind of a value.
const VALUE_KIND := "wuifwoud_value"
## The drag kind of a rule row.
const RULE_KIND := "wuifwoud_rule"
## A rule row's background.
const ROW := Color(1.0, 1.0, 1.0, 0.04)
## A rule row's border.
const EDGE := Color(1.0, 1.0, 1.0, 0.16)
## No colour.
const NONE := Color(0.0, 0.0, 0.0, 0.0)
## Inactive text.
const GREY := Color(0.62, 0.62, 0.62)
## Secondary text.
const DIM := Color(1.0, 1.0, 1.0, 0.55)
## Errors.
const ERROR := Color("ff8a80")
## The Values column's tiles at most; the rest are counted.
const MAX_TILES := 200


## The tab for the dialog `d`.
static func build(d) -> Control:
	var cols := HBoxContainer.new()
	cols.name = "RulesTab"
	cols.add_theme_constant_override("separation", 10)
	var vals := _values(d)
	vals.custom_minimum_size.x = 250.0
	cols.add_child(vals)
	cols.add_child(_rules(d))
	var insp: Control = InspectorRes.build(d, d.selected)
	insp.custom_minimum_size.x = 300.0
	cols.add_child(insp)
	return cols


## The Values column: the key chips, All / Unmatched, the chosen key's values as tiles, largest first (by area, then
## metres of lines, then points); the MAX_TILES largest, and how many more. A value
## dropped back here leaves every rule that names it on this key.
static func _values(d) -> Control:
	var key: String = d.current_key()
	var col: PanelContainer = DropRes.new().setup([VALUE_KIND],
		func(kind: String, id: String) -> void: _on_back(kind, id, d, key), d.box(NONE),
		d.box(Color(d.accent, 0.12), d.accent))
	col.name = "Values"
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(v)
	if not d.read_ready():
		v.add_child(d.kit.section("Values"))
		v.add_child(d.hint("reading the source…"))
		return col
	var vals: Array = d.values_of_key(key)
	v.add_child(d.kit.section(("Values of %s · %d" % [key, vals.size()]) if key != "" else "Values"))
	var keys := HFlowContainer.new()
	keys.name = "Keys"
	keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var group := ButtonGroup.new()
	for k in d.ordered_keys():
		var kb: Button = d.kit.toggle_chip(String(k), String(k) == key, d.accent)
		kb.button_group = group
		kb.mouse_filter = Control.MOUSE_FILTER_PASS
		if d.unique_key(String(k)):
			kb.modulate = DIM
			kb.tooltip_text = "Every feature has its own %s: no use for rules" % k
		kb.pressed.connect(d.pick_key.bind(String(k)))
		keys.add_child(kb)
	v.add_child(keys)
	var free := vals.filter(func(x): return d.mapping.rule_of_value(key, String(x)) < 0)
	var chips := HBoxContainer.new()
	chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fg := ButtonGroup.new()
	for pair in [["All", "all"], ["Unmatched · %d" % free.size(), "unmatched"]]:
		var fb: Button = d.kit.toggle_chip(pair[0], d.value_filter == pair[1], d.accent)
		fb.name = "Filter" + String(pair[1]).capitalize()
		fb.button_group = fg
		fb.mouse_filter = Control.MOUSE_FILTER_PASS
		fb.pressed.connect(d.set_filter.bind(String(pair[1])))
		chips.add_child(fb)
	v.add_child(chips)
	var sc := ScrollContainer.new()
	sc.name = "ValuesScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.mouse_filter = Control.MOUSE_FILTER_PASS
	var flow := HFlowContainer.new()
	flow.name = "Tiles"
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shown := 0
	var hidden := 0
	for val in vals:
		var ri: int = d.mapping.rule_of_value(key, String(val))
		if d.value_filter == "unmatched" and ri >= 0:
			continue
		if shown >= MAX_TILES:
			hidden += 1
			continue
		shown += 1
		var stripe: Color = d.type_colour(int(d.mapping.rules()[ri].get("type", 0))) if ri >= 0 else GREY
		var t: Button = TileRes.new().setup(VALUE_KIND, String(val), "%s\n%s" % [val, d.measure_text(key, String(val))],
			stripe)
		t.name = "Tile_" + String(val).validate_node_name()
		flow.add_child(t)
	if hidden > 0:
		var more: Button = TileRes.new().setup("", "", "%d more" % hidden)
		more.name = "TileMore"
		more.tooltip_text = "The %d smallest values are not shown: drag from the largest, or pick another key" % hidden
		flow.add_child(more)
	sc.add_child(flow)
	v.add_child(sc)
	v.add_child(d.hint("Drag onto a rule · back here to take it out"))
	return col


## A value dropped back on the Values column: it leaves every rule's match on `key`.
static func _on_back(_kind: String, id: String, d, key: String) -> void:
	d.change(func() -> void: d.mapping.take_out(key, id))


static func _rules(d) -> Control:
	var v := VBoxContainer.new()
	v.name = "Rules"
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var head := HBoxContainer.new()
	var lab: Label = d.kit.section("Rules · %d" % d.mapping.rules().size())
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lab)
	var add: Button = d.kit.chip("+ New rule", false, d.accent)
	add.name = "NewRule"
	add.pressed.connect(func() -> void: d.change(func() -> void: d.selected = d.mapping.add_rule(d.default_type())))
	head.add_child(add)
	v.add_child(head)
	v.add_child(d.hint("The first rule a feature matches paints it: drag a row's ≡ onto another row to move it there."))
	var sc := ScrollContainer.new()
	sc.name = "RulesScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.name = "RuleList"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	for i in d.mapping.rules().size():
		list.add_child(_row(d, i))
	var zone: PanelContainer = DropRes.new().setup([VALUE_KIND],
		func(kind: String, id: String) -> void: _on_new(kind, id, d),
		d.box(Color(d.accent, 0.05), Color(d.accent, 0.5)), d.box(Color(d.accent, 0.16), d.accent))
	zone.name = "NewRuleZone"
	zone.custom_minimum_size.y = 34.0
	var zl := Label.new()
	zl.text = "drop a value here → a new rule"
	zl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zl.add_theme_font_size_override("font_size", 11)
	zl.modulate = DIM
	zone.add_child(zl)
	list.add_child(zone)
	list.add_child(_no_rule(d))
	sc.add_child(list)
	v.add_child(sc)
	return v


## A value dropped on "a new rule": a rule of the profile's first type matching it, last.
static func _on_new(_kind: String, id: String, d) -> void:
	var k: String = d.current_key()
	d.change(func() -> void: d.selected = d.mapping.new_rule_from(k, id, d.default_type()))


## A rule's row: its ≡ handle, its type's dot and name, its match, density and age when set, the area it wins (≈). A
## click selects it; a value dropped on it joins its match; a handle dropped on it moves that rule here.
static func _row(d, i: int) -> Control:
	var r: Dictionary = d.mapping.rules()[i]
	var ty := int(r.get("type", 0))
	var sel: bool = d.selected == i
	var row: PanelContainer = DropRes.new().setup([VALUE_KIND, RULE_KIND],
		func(kind: String, id: String) -> void: _on_drop(kind, id, d, i),
		d.box(Color(d.accent, 0.14) if sel else ROW, d.accent if sel else NONE), d.box(Color(d.accent, 0.2), d.accent))
	row.name = "Rule%d" % i
	row.pressed.connect(func() -> void: d.select(i))
	var handle: Button = TileRes.new().setup(RULE_KIND, str(i), "≡")
	handle.name = "Handle%d" % i
	handle.custom_minimum_size = Vector2(22, 22)
	handle.tooltip_text = "Drag onto another rule to move this one there"
	row.add_child(_row_body(d, i, r, ty, handle))
	return row


static func _on_drop(kind: String, id: String, d, i: int) -> void:
	var k: String = d.current_key()
	if kind == VALUE_KIND:
		d.selected = i
		d.change(func() -> void: d.mapping.add_value(i, k, id))
	elif kind == RULE_KIND and int(id) != i:
		d.selected = i
		d.change(func() -> void: d.mapping.move_rule(int(id), i))


## The row's contents, `handle` first.
static func _row_body(d, i: int, r: Dictionary, ty: int, handle: Control) -> Control:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 7)
	if handle != null:
		h.add_child(handle)
	h.add_child(d.dot(d.type_colour(ty)))
	var nm := Label.new()
	nm.name = "Type"
	nm.text = d.type_name(ty)
	nm.custom_minimum_size.x = 120.0
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.tooltip_text = nm.text
	if not d.has_type(ty):
		nm.add_theme_color_override("font_color", ERROR)
	h.add_child(nm)
	var mt := Label.new()
	mt.name = "Match"
	mt.text = d.match_text(i)
	mt.clip_text = true
	mt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mt.modulate = DIM
	h.add_child(mt)
	var extra := PackedStringArray()
	if r.has("density"):
		extra.append("×%.2f" % float(r["density"]))
	if r.has("age"):
		extra.append("age %+.2f" % float(r["age"]))
	if not extra.is_empty():
		h.add_child(d.note(" ".join(extra)))
	h.add_child(d.note(d.rule_area(i)))
	return h


static func _no_rule(d) -> Control:
	var row := PanelContainer.new()
	row.name = "NoRule"
	row.add_theme_stylebox_override("panel", d.box(ROW, EDGE))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 7)
	h.add_child(d.dot(GREY))
	var l := Label.new()
	l.text = "No rule"
	l.custom_minimum_size.x = 120.0
	h.add_child(l)
	var what := Label.new()
	what.name = "Unmatched"
	what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	what.modulate = DIM
	what.text = d.unmatched_text()
	h.add_child(what)
	row.add_child(h)
	return row
