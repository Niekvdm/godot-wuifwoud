# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## A forest type's icon: one of ten glyphs, white on the type's colour in a rounded tile (drawn here from SVG: no import
## step), and the rules for a type's icon and colour when its entry names none (by style; today's colour for its id).

## The glyphs: white, 24 units square.
const GLYPHS := {
	"conifer": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M12 2 6 10h3l-4 6h4l-3 4h12l-3-4h4l-4-6h3z M11 20h2v3h-2z" fill="#fff"/></svg>',
	"broadleaf": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><circle cx="12" cy="9" r="7" fill="#fff"/><rect x="11" y="14" width="2" height="9" fill="#fff"/></svg>',
	"palm": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M12 23c0-6 1-10 1-14M13 9C9 6 5 7 3 10M13 9c3-3 7-3 9 0M13 9c-1-4-4-6-7-6M13 9c2-4 5-5 8-4" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round"/></svg>',
	"bush": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M3 20c0-4 3-6 5-6 0-3 2-5 4-5s4 2 4 5c2 0 5 2 5 6z" fill="#fff"/></svg>',
	"mixed": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M7 3 3 11h2.5L2 17h10L8.5 11H11z M6 17h2v4H6z" fill="#fff"/><circle cx="17" cy="10" r="5" fill="#fff"/><rect x="16" y="14" width="2" height="7" fill="#fff"/></svg>',
	"orchard": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><g fill="#fff"><circle cx="5" cy="5" r="3"/><circle cx="12" cy="5" r="3"/><circle cx="19" cy="5" r="3"/><circle cx="5" cy="12" r="3"/><circle cx="12" cy="12" r="3"/><circle cx="19" cy="12" r="3"/><circle cx="5" cy="19" r="3"/><circle cx="12" cy="19" r="3"/><circle cx="19" cy="19" r="3"/></g></svg>',
	"garden": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><circle cx="8" cy="8" r="5" fill="#fff"/><rect x="7" y="12" width="2" height="9" fill="#fff"/><path d="M12 21c0-3 2-5 4-5 0-2 1.5-3 3-3s3 1 3 3c0 0 0 5 0 5z" fill="#fff"/></svg>',
	"dead_wood": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M12 23V6M12 12 7 7M12 9l5-5M12 15l4-3M7 7 6 3" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round"/></svg>',
	"bamboo": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M7 2v20M12 1v22M17 3v19" stroke="#fff" stroke-width="2.4"/><path d="M5 8h4M10 6h4M15 10h4M5 15h4M10 14h4M15 16h4" stroke="#1d1e22" stroke-width="1.4"/></svg>',
	"wetland": '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M6 18V6M10 18V3M14 18V7M18 18V5" stroke="#fff" stroke-width="2" stroke-linecap="round"/><path d="M 2 20c3-2 5 2 8 0s5 2 8 0 4 1 4 1" stroke="#fff" stroke-width="1.6" fill="none"/></svg>',
}
## The glyphs in the order the icon picker lists them.
const ICONS := ["conifer", "broadleaf", "palm", "bush", "mixed", "orchard", "garden", "dead_wood", "bamboo", "wetland"]
## The glyph's share of its tile.
const GLYPH_SHARE := 0.75

static var _cache := {}


## What the icon picker calls glyph `icon`: "Dead wood".
static func label_of(icon: String) -> String:
	var words := icon.replace("_", " ")
	return words.left(1).to_upper() + words.substr(1)


## Glyph `icon` white on `colour`, `px` square, its corners rounded; made once per icon, colour and size.
static func texture(icon: String, colour: Color, px := 32) -> Texture2D:
	var key := "%s|%s|%d" % [icon, colour.to_html(true), px]
	if _cache.has(key):
		return _cache[key]
	var glyph := Image.new()
	glyph.load_svg_from_string(String(GLYPHS.get(icon, GLYPHS["broadleaf"])), float(px) * GLYPH_SHARE / 24.0)
	glyph.convert(Image.FORMAT_RGBA8)
	var img := Image.create_empty(px, px, false, Image.FORMAT_RGBA8)
	var rad := maxi(px / 5, 2)
	for y in px:
		for x in px:
			var dx := maxi(maxi(rad - x, x - (px - 1 - rad)), 0)
			var dy := maxi(maxi(rad - y, y - (px - 1 - rad)), 0)
			if dx * dx + dy * dy <= rad * rad:
				img.set_pixel(x, y, Color(colour, 1.0))
	img.blend_rect(glyph, Rect2i(Vector2i.ZERO, glyph.get_size()), (Vector2i(px, px) - glyph.get_size()) / 2)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## A type's icon tile: texture(), `px` square, named "Icon", its glyph in the meta "icon".
static func tile(icon: String, colour: Color, px := 30) -> TextureRect:
	var r := TextureRect.new()
	r.name = "Icon"
	r.texture = texture(icon, colour, px)
	r.custom_minimum_size = Vector2(px, px)
	r.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_meta("icon", icon)
	return r


## Type `t`'s icon (a profile entry or a resolved type): its `icon` when that is one of ICONS, else by style: bushes a
## bush, grid an orchard, mix mixed, natural a broadleaf, a conifer when most of `mid` (its mid lane, [[id, weight], …])
## by weight is conifer crowns (`crown_of(id)` says a species' crown).
static func icon_of(t: Dictionary, mid: Array, crown_of: Callable) -> String:
	var own := str(t.get("icon", ""))
	if ICONS.has(own):
		return own
	match str(t.get("style", "")):
		"bushes":
			return "bush"
		"grid":
			return "orchard"
		"mix":
			return "mixed"
	var tot := 0.0
	var con := 0.0
	for e in mid:
		var w := float(e[1]) if typeof(e) == TYPE_ARRAY and (e as Array).size() > 1 else 1.0
		var nm := str(e[0]) if typeof(e) == TYPE_ARRAY else str(e)
		tot += w
		if crown_of.is_valid() and str(crown_of.call(nm)) == "conifer":
			con += w
	return "conifer" if tot > 0.0 and con > tot * 0.5 else "broadleaf"


## A type's colour by its id alone: a fixed hue per id, the same in every session (the library's colour before types
## had their own).
static func colour_for_id(id: int) -> Color:
	return Color.from_hsv(fposmod(float(id) * 0.618034, 1.0), 0.55, 0.85)


## Type `t`'s colour (a resolved type's `colour`, a profile entry's "#rrggbb"), else its id's.
static func colour_of(t: Dictionary) -> Color:
	var c = t.get("colour")
	if c is Color:
		return c
	if c is String and String(c).begins_with("#") and Color.html_is_valid(String(c)):
		return Color.html(String(c))
	return colour_for_id(int(t.get("id", 0)))
