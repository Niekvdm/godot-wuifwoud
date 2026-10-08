# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## The editor dialogs' building blocks: Terrain3D Extended's overlay components (ux_components.gd) when it is installed,
## each one it has, and plain Godot controls for the rest (an older overlay lacks the newest; a project without it has
## none). The names, arguments and children are the overlay's, so a dialog never asks which it got.

## The overlay's components.
const UX := "res://addons/terrain_3d_extended/src/ux_components.gd"

## The overlay's component script, or null.
var ux = null
var _has := {}


## The overlay's component script when it is installed, else null (for new()).
static func overlay():
	return load(UX) if ResourceLoader.exists(UX) else null


func _init(p_ux = null) -> void:
	ux = p_ux
	if ux != null:
		for m in (ux as Script).get_script_method_list():
			_has[String(m["name"])] = true


## Whether `component` comes from the overlay.
func has(component: String) -> bool:
	return _has.has(component)


## The panel a dialog sits on.
func glass_panel() -> PanelContainer:
	if has("glass_panel"):
		return ux.glass_panel()
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.115, 0.13, 0.97)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12.0)
	p.add_theme_stylebox_override("panel", sb)
	return p


## A pill button.
func chip(text: String, favourite: bool, accent: Color, into: Button = null) -> Button:
	if has("chip"):
		return ux.chip(text, favourite, accent, into)
	var b := into if into != null else Button.new()
	b.text = ("★ " if favourite else "") + text
	b.focus_mode = Control.FOCUS_NONE
	return b


## A pill that toggles.
func toggle_chip(text: String, on: bool, accent: Color) -> Button:
	if has("toggle_chip"):
		return ux.toggle_chip(text, on, accent)
	var b := chip(text, false, accent)
	b.toggle_mode = true
	b.button_pressed = on
	return b


## A picture tile: the picture filling it, the name along the bottom (child "Name"), a "Star" child.
func tile(picture: Texture2D, item: String, accent: Color, px := 64, into: Button = null) -> Button:
	if has("tile"):
		return ux.tile(picture, item, accent, px, into)
	var b := into if into != null else Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(px, px)
	b.tooltip_text = item
	b.icon = picture
	b.expand_icon = true
	b.set_meta("accent", accent)
	var l := Label.new()
	l.name = "Name"
	l.text = item
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", 9)
	l.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	b.add_child(l)
	var star := Label.new()
	star.name = "Star"
	star.visible = false
	b.add_child(star)
	return b


## A tile's selection frame.
func set_tile_selected(t: Button, on: bool) -> void:
	if has("set_tile_selected"):
		ux.set_tile_selected(t, on)
		return
	if on:
		var sb := StyleBoxFlat.new()
		sb.draw_center = false
		sb.set_border_width_all(2)
		sb.border_color = t.get_meta("accent", Color.WHITE)
		t.add_theme_stylebox_override("normal", sb)
	else:
		t.remove_theme_stylebox_override("normal")


## A label, its value and a slider. Children: Head/Label, Head/Value, Slider.
func slider_row(label: String, lo: float, hi: float, step: float, value: float, suffix: String,
		accent: Color) -> VBoxContainer:
	if has("slider_row"):
		return ux.slider_row(label, lo, hi, step, value, suffix, accent)
	var row := VBoxContainer.new()
	var head := HBoxContainer.new()
	head.name = "Head"
	row.add_child(head)
	var lab := Label.new()
	lab.name = "Label"
	lab.text = label
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lab)
	var val := Label.new()
	val.name = "Value"
	head.add_child(val)
	var s := HSlider.new()
	s.name = "Slider"
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.focus_mode = Control.FOCUS_NONE
	row.add_child(s)
	val.text = value_text(s.value, step, suffix)
	s.value_changed.connect(func(v: float) -> void: val.text = value_text(v, step, suffix))
	return row


## A label and a switch. Children: Label, Toggle.
func toggle_row(label: String, on: bool, accent: Color) -> HBoxContainer:
	if has("toggle_row"):
		return ux.toggle_row(label, on, accent)
	var row := HBoxContainer.new()
	var lab := Label.new()
	lab.name = "Label"
	lab.text = label
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lab)
	var cb := CheckBox.new()
	cb.name = "Toggle"
	cb.button_pressed = on
	cb.focus_mode = Control.FOCUS_NONE
	row.add_child(cb)
	return row


## One pill per option, one pressed at a time. Children: Seg0..SegN; `on_pick(index)`.
func segmented(options: Array, selected: int, accent: Color, on_pick := Callable()) -> HBoxContainer:
	if has("segmented"):
		return ux.segmented(options, selected, accent, on_pick)
	var row := HBoxContainer.new()
	var group := ButtonGroup.new()
	for i in options.size():
		var b := Button.new()
		b.name = "Seg%d" % i
		b.text = String(options[i])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == selected
		b.focus_mode = Control.FOCUS_NONE
		if on_pick.is_valid():
			var at := i
			b.pressed.connect(func() -> void: on_pick.call(at))
		row.add_child(b)
	return row


## A warm box with its text and, when `action` is given, a button. Descendants: Text, Action.
func banner(text: String, action: String, accent: Color) -> PanelContainer:
	if has("banner"):
		return ux.banner(text, action, accent)
	var p := PanelContainer.new()
	var col := VBoxContainer.new()
	p.add_child(col)
	var t := Label.new()
	t.name = "Text"
	t.text = text
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(t)
	var b := Button.new()
	b.name = "Action"
	b.text = action
	b.visible = action != ""
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_child(b)
	return p


## A small dimmed wrapping line.
func description(text: String) -> Label:
	if has("description"):
		return ux.description(text)
	var l := Label.new()
	l.name = "Description"
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = Color(1.0, 1.0, 1.0, 0.7)
	return l


## A section label.
func section(text: String) -> Label:
	if has("section"):
		return ux.section(text)
	var l := Label.new()
	l.text = text.to_upper()
	l.modulate = Color(1.0, 1.0, 1.0, 0.55)
	return l


## A search field.
func search_field(placeholder: String) -> LineEdit:
	if has("search_field"):
		return ux.search_field(placeholder)
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.clear_button_enabled = true
	return e


## A drop-down of `options` (Strings or {"text", "icon"}); `on_pick(index)`.
func dropdown(options: Array, selected: int, accent: Color, on_pick := Callable()) -> OptionButton:
	if has("dropdown"):
		return ux.dropdown(options, selected, accent, on_pick)
	var b := OptionButton.new()
	b.focus_mode = Control.FOCUS_NONE
	for o in options:
		if o is Dictionary and (o as Dictionary).get("icon") != null:
			b.add_icon_item(o["icon"], String(o.get("text", "")))
		else:
			b.add_item(String(o.get("text", "")) if o is Dictionary else String(o))
	b.selected = selected if selected >= 0 and selected < options.size() else -1
	if on_pick.is_valid():
		b.item_selected.connect(func(i: int) -> void: on_pick.call(i))
	return b


## A button that opens a menu of `items` ({"id", "text", "disabled"?} or {"separator": true}); `on_pick(id)`.
func menu_chip(text: String, items: Array, accent: Color, on_pick := Callable()) -> MenuButton:
	if has("menu_chip"):
		return ux.menu_chip(text, items, accent, on_pick)
	var b := MenuButton.new()
	b.text = text
	b.flat = false
	b.focus_mode = Control.FOCUS_NONE
	var pop := b.get_popup()
	for it in items:
		if bool((it as Dictionary).get("separator", false)):
			pop.add_separator()
			continue
		pop.add_item(String(it.get("text", "")), int(it.get("id", 0)))
		pop.set_item_disabled(pop.item_count - 1, bool(it.get("disabled", false)))
	if on_pick.is_valid():
		pop.id_pressed.connect(func(id: int) -> void: on_pick.call(id))
	return b


## "0.32 m", "40.0 m", "3": as many decimals as the step has, the suffix after a space (the overlay's rule).
static func value_text(value: float, step: float, suffix: String) -> String:
	var decimals := 0 if step >= 1.0 else (1 if step >= 0.1 else 2)
	return (("%." + str(decimals) + "f") % value) + ((" " + suffix) if suffix != "" else "")
