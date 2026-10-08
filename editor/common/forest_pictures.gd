# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## A species' picture for the editor: its pack build's (built/<id>_picture.res), else its crown's glyph (a broadleaf,
## conifer or palm tree, or a bush, drawn here from SVG: no import step), loaded once and kept until forget().

## The glyphs: white on clear, 24 units square.
const GLYPHS := {
	"broadleaf": '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 24 24"><circle cx="12" cy="9" r="7" fill="#fff"/><rect x="11" y="14" width="2" height="9" fill="#fff"/></svg>',
	"conifer": '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 24 24"><path d="M12 2 6 10h3l-4 6h4l-3 4h12l-3-4h4l-4-6h3z M11 20h2v3h-2z" fill="#fff"/></svg>',
	"palm": '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 24 24"><path d="M12 23c0-6 1-10 1-14M13 9C9 6 5 7 3 10M13 9c3-3 7-3 9 0M13 9c-1-4-4-6-7-6M13 9c2-4 5-5 8-4" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round"/></svg>',
	"bush": '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 24 24"><path d="M3 20c0-4 3-6 5-6 0-3 2-5 4-5s4 2 4 5c2 0 5 2 5 6z" fill="#fff"/></svg>',
}
## Under a glyph (alone it would vanish on a light strip).
const GLYPH_BG := Color(0.20, 0.27, 0.22)

static var _cache := {}
static var _glyphs := {}


## Where species `id`'s picture lives in its pack's built folder `dir` ("" for a pack that is not a file).
static func picture_path(dir: String, id: String) -> String:
	return dir.path_join(id + "_picture.res") if dir != "" else ""


## Whether species `sp` (of the pack built in `dir`) has a picture.
static func has_picture(sp, dir: String) -> bool:
	var p := picture_path(dir, String(sp.id))
	return p != "" and ResourceLoader.exists(p)


## Species `sp`'s picture (its pack built in `dir`), else its glyph.
static func of(sp, dir: String) -> Texture2D:
	var key := dir + "|" + String(sp.id)
	if _cache.has(key):
		return _cache[key]
	var tex: Texture2D = null
	var p := picture_path(dir, String(sp.id))
	if p != "" and ResourceLoader.exists(p):
		var img = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REPLACE)
		if img is Image:
			tex = ImageTexture.create_from_image(img)
	if tex == null:
		tex = glyph(glyph_name(sp))
	_cache[key] = tex
	return tex


## The glyph a species falls back on: "bush" for a bush, else its crown.
static func glyph_name(sp) -> String:
	if String(sp.kind) == "bush":
		return "bush"
	return String(sp.crown) if GLYPHS.has(String(sp.crown)) else "broadleaf"


## Glyph `nm` (one of GLYPHS) on GLYPH_BG.
static func glyph(nm: String) -> Texture2D:
	if not _glyphs.has(nm):
		var img := Image.new()
		img.load_svg_from_string(String(GLYPHS.get(nm, GLYPHS["broadleaf"])), 1.0)
		img.convert(Image.FORMAT_RGBA8)
		var bg := Image.create_empty(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
		bg.fill(GLYPH_BG)
		bg.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
		_glyphs[nm] = ImageTexture.create_from_image(bg)
	return _glyphs[nm]


## Drop every picture (a build landed).
static func forget() -> void:
	_cache.clear()
