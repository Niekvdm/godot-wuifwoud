# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends MenuButton
## The 3D editor's "Forest" menu: show or hide the forest preview, re-grow it, and open the Species dialog. Writes
## ForestPreview.visible; `changed` tells the plugin to keep it in the project's
## editor metadata.

## The preview switch moved: the plugin keeps it.
signal changed
## Re-grow chosen.
signal regrow_requested
## Species… chosen.
signal species_requested

## The editor preview's switch.
const ForestPreviewRes := preload("res://addons/wuifwoud/forest_preview.gd")
## Show forest's id.
const ID_SHOW := 0
## Re-grow's id.
const ID_REGROW := 1
## Species…'s id.
const ID_SPECIES := 2


func _init() -> void:
	text = "Forest"
	tooltip_text = "The forest preview in the editor (Wuifwoud)"
	flat = true
	var p := get_popup()
	p.add_check_item("Show forest", ID_SHOW)
	p.add_item("Re-grow", ID_REGROW)
	p.add_separator()
	p.add_item("Species…", ID_SPECIES)
	p.id_pressed.connect(_on_id)
	sync()


## The menu's check from ForestPreview.
func sync() -> void:
	var p := get_popup()
	p.set_item_checked(p.get_item_index(ID_SHOW), ForestPreviewRes.visible)


func _on_id(id: int) -> void:
	if id == ID_SHOW:
		ForestPreviewRes.visible = not ForestPreviewRes.visible
		sync()
		changed.emit()
	elif id == ID_REGROW:
		regrow_requested.emit()
	elif id == ID_SPECIES:
		species_requested.emit()
