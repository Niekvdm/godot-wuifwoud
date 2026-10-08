# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Button
## A thing the Import dialog drags: a source value (its text and area, a stripe in the colour of the rule it falls
## under) or a rule row's ≡ handle. Dragging it carries {kind, id} to a drop target; a click is
## `pressed`.

## The tile's border.
const FRAME := Color(1.0, 1.0, 1.0, 0.1)
## The tile's fill.
const FILL := Color(1.0, 1.0, 1.0, 0.05)

## What it drags: a value or a rule.
var drag_kind := ""
## Its id in that kind.
var drag_id := ""


## Its kind, id, caption and stripe colour; returns itself.
func setup(p_kind: String, p_id: String, p_caption: String, p_stripe := Color(0, 0, 0, 0)) -> Button:
	drag_kind = p_kind
	drag_id = p_id
	text = p_caption
	tooltip_text = p_caption
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_PASS
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_theme_font_size_override("font_size", 11)
	var sb := StyleBoxFlat.new()
	sb.bg_color = FILL
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(1)
	sb.border_color = FRAME
	sb.content_margin_left = 10.0 if p_stripe.a > 0.0 else 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 3.0
	sb.content_margin_bottom = 3.0
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(s, sb)
	if p_stripe.a > 0.0:
		var st := ColorRect.new()
		st.name = "Stripe"
		st.color = p_stripe
		st.mouse_filter = Control.MOUSE_FILTER_IGNORE
		st.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
		st.offset_right = 4.0
		add_child(st)
	return self


func _get_drag_data(_at: Vector2) -> Variant:
	if drag_kind == "" or disabled:
		return null
	if is_inside_tree():
		var ghost := Label.new()
		ghost.text = text.get_slice("\n", 0)
		set_drag_preview(ghost)
	return {"kind": drag_kind, "id": drag_id}
