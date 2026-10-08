# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The Types dialog's middle column: the selected type's settings. Its name, icon, colour and id; its style; the numbers
## that style uses, within the forest's ranges; a natural type's far colour (from the bake, or a colour); a footer saying
## what it grows and which import rules paint it. For the Defaults row: what the map's default lanes are and which types
## inherit them. A slider writes when it is let go, a text field on Enter or when it loses focus.

## The forest types (their styles).
const TypesRes := preload("res://addons/wuifwoud/forest_types.gd")
## The type icons.
const TypeTileRes := preload("res://addons/wuifwoud/editor/common/forest_type_tile.gd")
## The styles as the style chips name them, in ForestTypes.STYLES' order.
const STYLE_NAMES := ["Natural", "Bushes", "Grid", "Mix"]
## Each style's numbers: [node name, label, key, low, high, step, suffix, shown ×].
const NUMBERS := {
	"natural": [["Density", "Density", "density_per_m2", 0.0005, 0.2, 0.0005, "/m²", 1.0],
		["Clump", "Clump", "clump", 0.0, 1.0, 0.01, "", 1.0],
		["Understory", "Understory", "understory", 0.0, 2.0, 0.01, "", 1.0],
		["DeadShare", "Dead share", "dead_frac", 0.0, 100.0, 1.0, "%", 100.0],
		["EdgeWall", "Road edge wall", "edge_wall_m", 0.0, 100.0, 1.0, "m", 1.0],
		["WallMult", "Wall density ×", "edge_wall_mult", 1.0, 6.0, 0.1, "", 1.0]],
	"bushes": [["Density", "Density", "density_per_m2", 0.0005, 0.2, 0.0005, "/m²", 1.0],
		["Clump", "Clump", "clump", 0.0, 1.0, 0.01, "", 1.0]],
	"grid": [["Pitch", "Pitch", "pitch_m", 1.0, 40.0, 0.5, "m", 1.0]],
	"mix": [["Density", "Density", "density_per_m2", 0.0005, 0.2, 0.0005, "/m²", 1.0],
		["TreeShare", "Tree share", "tree_share", 0.0, 100.0, 1.0, "%", 100.0]],
}
## A far colour picker's colour while the far colour comes from the bake.
const FAR_DEFAULT := Color(0.25, 0.38, 0.22)


## The column for the dialog `d`.
static func build(d) -> Control:
	var v := VBoxContainer.new()
	v.name = "TypePanel"
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sc := ScrollContainer.new()
	sc.name = "PanelScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var col := VBoxContainer.new()
	col.name = "Settings"
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	sc.add_child(col)
	v.add_child(sc)
	if d.selected == 0:
		_defaults(d, col)
	else:
		_type(d, col, d.selected)
	return v


static func _type(d, col: VBoxContainer, id: int) -> void:
	var t: Dictionary = d.profile.type_of(id)
	var head := HBoxContainer.new()
	head.name = "Head"
	head.add_theme_constant_override("separation", 8)
	head.add_child(TypeTileRes.tile(d.icon_for(id), d.colour_for(id), 34))
	var title := Label.new()
	title.name = "Title"
	title.text = str(t.get("name", ""))
	title.add_theme_font_size_override("font_size", 15)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	head.add_child(title)
	var idl := Label.new()
	idl.name = "Id"
	idl.text = "id %d" % id
	idl.modulate = d.DIM
	head.add_child(idl)
	col.add_child(head)
	var nm := LineEdit.new()
	nm.name = "TypeName"
	nm.text = str(t.get("name", ""))
	nm.text_submitted.connect(func(s: String) -> void: d.set_value(id, "name", s))
	nm.focus_exited.connect(func() -> void: d.set_value(id, "name", nm.text))
	col.add_child(nm)
	col.add_child(_identity(d, id, t))
	col.add_child(d.kit.section("Style"))
	var style := str(t.get("style", "natural"))
	var seg: HBoxContainer = d.kit.segmented(STYLE_NAMES, maxi(TypesRes.STYLES.find(style), 0), d.accent,
		func(i: int) -> void: d.set_style(id, String(TypesRes.STYLES[i])))
	seg.name = "Style"
	col.add_child(seg)
	for n in NUMBERS.get(style, []):
		col.add_child(_number(d, id, n))
	if style == "natural":
		col.add_child(_far(d, id, t))
	var foot: Label = d.hint(d.footer_text(id))
	foot.name = "Footer"
	col.add_child(foot)


## The icon picker (By style, or one of the ten) and the colour picker.
static func _identity(d, id: int, t: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.name = "Identity"
	h.add_theme_constant_override("separation", 8)
	var colour: Color = d.colour_for(id)
	var auto := TypeTileRes.icon_of({"style": t.get("style", "")}, d.profile.lane_of(id, "mid")["entries"], d.crown_of)
	var options := [{"text": "By style (%s)" % TypeTileRes.label_of(auto).to_lower()}]
	for ic in TypeTileRes.ICONS:
		options.append({"text": TypeTileRes.label_of(ic), "icon": TypeTileRes.texture(ic, colour, 18)})
	var dd: OptionButton = d.kit.dropdown(options, TypeTileRes.ICONS.find(str(t.get("icon", ""))) + 1, d.accent,
		func(i: int) -> void: d.set_value(id, "icon", "" if i == 0 else String(TypeTileRes.ICONS[i - 1])))
	dd.name = "IconPick"
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(dd)
	var cp := ColorPickerButton.new()
	cp.name = "Colour"
	cp.color = colour
	cp.edit_alpha = false
	cp.custom_minimum_size = Vector2(44, 0)
	cp.tooltip_text = "The type's colour: its icon, the library, the brush"
	cp.popup_closed.connect(func() -> void:
		if cp.color.to_html(false) != colour.to_html(false):
			d.set_value(id, "colour", "#" + cp.color.to_html(false)))
	h.add_child(cp)
	return h


## A number's slider, written when it is let go (`n`: a NUMBERS row).
static func _number(d, id: int, n: Array) -> Control:
	var key := String(n[2])
	var scale := float(n[7])
	var v := float(d.profile.value_of(id, key)) * scale
	var row: VBoxContainer = d.kit.slider_row(String(n[1]), float(n[3]), float(n[4]), float(n[5]), v, String(n[6]), d.accent)
	row.name = String(n[0])
	var s := row.get_node("Slider") as HSlider
	# It writes when a drag ends; the mouse wheel would move it without one (and steal the column's scrolling).
	s.scrollable = false
	if key == "density_per_m2":
		var val := row.get_node("Head/Value") as Label
		if val != null:
			val.text = "%s /m²" % d.num(v, 4)
			s.value_changed.connect(func(x: float) -> void: val.text = "%s /m²" % d.num(x, 4))
	s.drag_ended.connect(func(moved: bool) -> void:
		if moved:
			d.set_value(id, key, s.value / scale))
	return row


## A natural type's far colour: from the bake (no key), or the picker's.
static func _far(d, id: int, t: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.name = "Far"
	h.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = "Far colour"
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	var from_bake := not t.has("far_color")
	var cp := ColorPickerButton.new()
	cp.name = "FarColour"
	cp.edit_alpha = false
	cp.custom_minimum_size = Vector2(44, 0)
	cp.color = FAR_DEFAULT
	if not from_bake and Color.html_is_valid(str(t["far_color"])):
		cp.color = Color.html(str(t["far_color"]))
	cp.disabled = from_bake
	cp.popup_closed.connect(func() -> void: d.set_value(id, "far_color", "#" + cp.color.to_html(false)))
	var bake: Button = d.kit.toggle_chip("From the bake", from_bake, d.accent)
	bake.name = "FarFromBake"
	bake.tooltip_text = "The far forest's colour for this type: its species' bakes, or a colour of its own"
	bake.toggled.connect(func(on: bool) -> void:
		d.set_value(id, "far_color", "" if on else "#" + cp.color.to_html(false)))
	h.add_child(bake)
	h.add_child(cp)
	return h


static func _defaults(d, col: VBoxContainer) -> void:
	var title := Label.new()
	title.name = "Title"
	title.text = "Defaults (every type)"
	title.add_theme_font_size_override("font_size", 15)
	col.add_child(title)
	col.add_child(d.hint("The map's default mixes: the profile's own pools (coast, mid, high, bush, the orchard, and the dead trees by band). A type's lane without a mix of its own grows these; a pool the profile lacks comes from the project's fallback flora, dimmed. A change here changes every type that inherits it."))
	var inh: Label = d.hint(d.inheritors_text())
	inh.name = "Inheritors"
	inh.modulate = Color.WHITE
	col.add_child(inh)
