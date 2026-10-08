# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends PanelContainer
## Where a dragged value, a rule's handle, a type's handle or a species can be dropped in Wuifwoud's dialogs: it
## takes the drag kinds in `kinds` and calls `on_drop(kind, id)`, wearing its hover style while one it takes is over
## it. A click emits `pressed` when the button is let go (a rule row selects its rule), a right click
## `menu_requested`. Its children must be MOUSE_FILTER_IGNORE or PASS: Godot stops looking for a drop target at a STOP
## control.

## Clicked (a rule row selects its rule).
signal pressed
## Right-clicked, at the screen position `at` (a type row's menu).
signal menu_requested(at: Vector2)

## Empty: takes nothing (a clickable panel)
var kinds: Array = []
## (kind: String, id: String)
var on_drop := Callable()
var _normal: StyleBox = null
var _hover: StyleBox = null


## The drag kinds it takes, what a drop calls, and its normal and hover styles; returns itself.
func setup(p_kinds: Array, p_on_drop: Callable, p_normal: StyleBox, p_hover: StyleBox) -> PanelContainer:
	kinds = p_kinds
	on_drop = p_on_drop
	_normal = p_normal
	_hover = p_hover
	if _normal != null:
		add_theme_stylebox_override("panel", _normal)
	return self


func _can_drop_data(_at: Vector2, p_data: Variant) -> bool:
	var ok: bool = p_data is Dictionary and kinds.has(String(p_data.get("kind", "")))
	_highlight(ok)
	return ok


func _drop_data(_at: Vector2, p_data: Variant) -> void:
	_highlight(false)
	if on_drop.is_valid():
		on_drop.call(String(p_data["kind"]), String(p_data["id"]))


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT or what == NOTIFICATION_DRAG_END:
		_highlight(false)


func _gui_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		# On the release, not the press: a press on a tile or a handle inside reaches this too (a Button does not take
		# it), and a dialog rebuilt then would take that tile away before its own release (its click) or its drag.
		# A tile whose click rebuilds the dialog leaves the tree first, so its release never gets here.
		pressed.emit()
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		menu_requested.emit(get_global_mouse_position())
		accept_event()


func _highlight(on: bool) -> void:
	if _hover != null and _normal != null:
		add_theme_stylebox_override("panel", _hover if on else _normal)
