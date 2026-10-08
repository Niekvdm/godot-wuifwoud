# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## THE IMPOSTOR BAKE: a tree species' hemi-octahedral G-buffer atlases (albedo, and normal + transmission) rendered
## from its real mesh with its own materials' inputs, GRID × GRID views over the upper hemisphere, ONE ROW A ROUND, BOTH
## CHANNELS AT ONCE: a SubViewport a view of the row and a channel (2 × GRID), all sharing one World3D (the linear
## environment, and the subject twice, once a channel, each on its own render layer under its channel's cameras' cull
## mask), each with its own camera. A round waits SETTLE drawn
## frames and is then read back; the caller draws the frames (the editor's own, the command line's, a render suite's forced draws)
## and calls step() once after each.
##
## HEMI-OCTAHEDRAL, not a view ring: aircraft see trees from above, and a ring has no top view; the grid's centre is
## straight down, its border the horizon, so straight down is a real baked frame at full resolution. UNSHADED: the atlas
## holds albedo and the runtime applies the sun: baking the sun in would freeze one time of day into every distant tree
## (and ambient_light_energy measures no response at all). RENDERED at 4x the stored tile and box-filtered down
## premultiplied: that is the edge antialiasing, with MSAA off, whose resolve against the transparent-black background
## would darken every edge texel. See impostor_bake.gdshader.

## The bake's shader.
const BAKE_SHADER := "res://addons/wuifwoud/tools/impostor_bake.gdshader"
## The G-buffer channels a view renders (impostor_bake.gdshader `channel`): 0 albedo, 1 normal + transmission.
const CHANNELS := 2
## Frames drawn before a round is read: three once the cameras move (two leave whole rounds stale now and then,
## measured); SETTLE_FIRST for a species' first round, whose mesh and materials are new to the renderer. At these the
## sheets are the same byte for byte from one bake to the next and as at ten frames a round (measured).
const SETTLE := 3
## Frames before a species' first round is read.
const SETTLE_FIRST := 6
## Frames a round waits at most for a view that came back empty: past them it is taken as it is (a mesh that draws
## nothing).
const UNREADY_FRAMES := 600
## The rendered resolution of a view; stored at OUT_TILE (store_image).
const TILE := 512
## A view's stored size in pixels.
const OUT_TILE := 128
## GRID × GRID views over the upper hemisphere: 8 → 64. A tree at the hand-over is ~25 px tall and 8 is measurably enough
## there, at a quarter of the texels 16 would cost. View (i, j) is baked at uv = (i/(grid-1), j/(grid-1)) so the
## EXTREMES are represented: the horizon ring on the atlas border, straight up in its centre; the runtime blend is exact
## at both.
const GRID := 8

var _world: World3D = null
var _vps: Array[SubViewport] = []
var _cams: Array[Camera3D] = []
var _subjects: Array[MeshInstance3D] = []   # a channel's subject: on render layer 1 << channel
var _atlas: Image = null
var _atlas_n: Image = null
var _meta := {}
var _round := 0
var _wait := 0
## Frames drawn before a round is read: a species' first round, the rest (SETTLE_FIRST, SETTLE by default).
var settle_first := SETTLE_FIRST
## Frames before a round is read (tests may lower it).
var settle := SETTLE
## Frames a round has waited so far for a view that came back empty (see step()).
var _unready := 0
## A species' first round is aimed again on the first drawn frame (see begin()).
var _reaim := false
var _busy := false


## The bake's settings, as built.json records them (ForestAssets._impostor_ring reads grid, cols and rows).
static func settings() -> Dictionary:
	return {"grid": GRID, "cols": GRID, "rows": GRID, "views": GRID * GRID, "tile": OUT_TILE, "render_tile": TILE,
		"projection": "hemi_oct", "gbuffer": true}


## The row of viewports under `host` (the editor's base control, the command line's root, a render suite's host).
func setup(host: Node) -> void:
	_world = World3D.new()
	# No lights: the subject renders unshaded. The environment only pins the tonemapper to LINEAR at exposure 1.0, which
	# makes the bake an identity on the source texels; any filmic curve would bend the albedo.
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0
	_world.environment = env
	for i in CHANNELS * GRID:              # viewport c + GRID × channel
		var vp := SubViewport.new()
		vp.size = Vector2i(TILE, TILE)
		vp.world_3d = _world
		vp.transparent_bg = true          # the atlas needs real alpha
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		host.add_child(vp)
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.cull_mask = 1 << (i / GRID)   # its channel's subject only
		vp.add_child(cam)
		cam.current = true
		_vps.append(vp)
		_cams.append(cam)
	for ch in CHANNELS:
		var sub := MeshInstance3D.new()
		sub.layers = 1 << ch
		_vps[0].add_child(sub)            # in the shared world: every viewport sees it, its channel's cameras draw it
		_subjects.append(sub)


## Starts baking `dressed` (a species' combined mesh with its own materials: ForestAssets._dress); false when it has no
## surface. EVERY uniform the bake shader declares is copied from the species' material by name (crown centre and
## radius, spherify, the normal map, the AO and foliage flags), so each term is computed from exactly the inputs the
## mesh tree is lit with, and a uniform added to both cannot be forgotten here.
func begin(dressed: ArrayMesh) -> bool:
	if dressed == null or dressed.get_surface_count() == 0:
		return false
	var shader: Shader = load(BAKE_SHADER)
	var names: Array = shader.get_shader_uniform_list().map(func(u): return String(u.name))
	var ab: AABB = dressed.get_aabb()
	for ch in CHANNELS:
		var sub := _subjects[ch]
		for si in sub.get_surface_override_material_count():
			sub.set_surface_override_material(si, null)
		sub.mesh = dressed
		for si in dressed.get_surface_count():
			var sm := dressed.surface_get_material(si) as ShaderMaterial
			if sm == null:
				continue
			var bm := ShaderMaterial.new()
			bm.shader = shader
			for n in names:
				var v: Variant = sm.get_shader_parameter(n)
				if v != null:
					bm.set_shader_parameter(n, v)
			var cut: Variant = sm.get_shader_parameter("alpha_cut")
			bm.set_shader_parameter("alpha_cut", 0.5 if cut == null else float(cut))
			bm.set_shader_parameter("channel", ch)
			sub.set_surface_override_material(si, bm)
		# Y only: the MESH ORIGIN is what the MultiMesh places and the card pivots on, so it stays at the tile's
		# horizontal centre; recentring on the AABB would slide a leaning tree sideways in the atlas, beside its trunk.
		sub.position = Vector3(0, -ab.position.y, 0)
	_atlas = Image.create(GRID * TILE, GRID * TILE, false, Image.FORMAT_RGBA8)
	_atlas.fill(Color(0, 0, 0, 0))
	_atlas_n = Image.create(GRID * TILE, GRID * TILE, false, Image.FORMAT_RGBA8)
	_atlas_n.fill(Color(0, 0, 0, 0))
	# The horizontal reach FROM THE ORIGIN, and one square framing for every view (a per-view frame makes the tree
	# breathe as the camera orbits). `span` is the contract with the runtime card: the tile covers a span-by-span world
	# square centred at half height, and the card is sized from THIS number.
	var half := maxf(maxf(absf(ab.position.x), absf(ab.end.x)), maxf(absf(ab.position.z), absf(ab.end.z)))
	var span := maxf(ab.size.y, half * 2.0) * 1.02
	_meta = {"h": ab.size.y, "w": half * 2.0, "span": span}
	_round = 0
	_unready = 0
	_reaim = true
	_aim_round()
	_wait = settle_first
	_busy = true
	return true


## Once after each drawn frame: true when every view of the species is read (or nothing is baking).
func step() -> bool:
	if not _busy:
		return true
	if _reaim:
		# Cameras made in the frame the bake begins missed their first aim (measured: the first tree baked in a process
		# lost its whole first round, however long it waited); aimed again once a frame has been drawn, they hold it.
		_reaim = false
		_aim_round()
	_wait -= 1
	if _wait > 0:
		return false
	var imgs: Array[Image] = []
	for vp in _vps:
		imgs.append(vp.get_texture().get_image())
	# A view that came back EMPTY is aimed and read again a few frames on, up to UNREADY_FRAMES: the safety net for a
	# camera that missed its aim (see _reaim) or a renderer still compiling the bake shader.
	for c in GRID:
		if (imgs[c] == null or not imgs[c].get_used_rect().has_area()) and _unready < UNREADY_FRAMES:
			_unready += settle
			_aim_round()
			_wait = settle
			return false
	_unready = 0
	for c in GRID:
		_blit(_round * GRID + c, imgs[c], _atlas)
		_blit(_round * GRID + c, imgs[c + GRID], _atlas_n)
	_round += 1
	if _round >= GRID:
		_busy = false
		return true
	_aim_round()
	_wait = settle
	return false


## Whether a species is baking.
func busy() -> bool:
	return _busy


## The species' bake: the full-size atlases, the framing, and how many sampled texels are opaque (0: it rendered
## nothing: a card from it would be invisible, which is what this bake exists not to ship).
func result() -> Dictionary:
	var op := 0
	if _atlas != null:
		for y in range(0, _atlas.get_height(), 8):
			for x in range(0, _atlas.get_width(), 8):
				if _atlas.get_pixel(x, y).a > 0.4:
					op += 1
	return {"albedo": _atlas, "normal": _atlas_n, "h": float(_meta.get("h", 0.0)), "w": float(_meta.get("w", 0.0)),
		"span": float(_meta.get("span", 0.0)), "opaque": op}


## Stop the species baking now.
func abort() -> void:
	_busy = false


## Free the viewports.
func free_nodes() -> void:
	for vp in _vps:
		if is_instance_valid(vp):
			vp.queue_free()
	_vps.clear()
	_cams.clear()
	_subjects.clear()


## The direction view (u, v) of the grid looks FROM: [0,1]² → the upper hemisphere, the exact inverse of the runtime's
## encode (wf_common `wf_hemi_oct_uv`), or every impostor shows a neighbouring view. Corners: the horizontal cardinals.
static func hemi_oct_dir(u: float, v: float) -> Vector3:
	var px := u - v
	var pz := -1.0 + u + v
	var py := 1.0 - absf(px) - absf(pz)
	return Vector3(px, py, pz).normalized()


func _aim_round() -> void:
	var h: float = float(_meta["h"])
	var span: float = float(_meta["span"])
	var n1 := float(GRID - 1)
	for i in CHANNELS * GRID:
		var c := i % GRID
		var view := _round * GRID + c
		var cam := _cams[i]
		cam.size = span
		var dir := hemi_oct_dir(float(view % GRID) / n1, float(view / GRID) / n1)
		var centre := Vector3(0, h * 0.5, 0)
		var d := span * 2.0
		cam.position = centre + dir * d
		# look_at needs an UP not parallel to the view, and straight down is a view this atlas exists to have.
		cam.look_at(centre, Vector3(0, 0, -1) if absf(dir.y) > 0.99 else Vector3.UP)
		cam.near = 0.05
		cam.far = d * 3.0


func _blit(view: int, img: Image, dst: Image) -> void:
	if img == null:
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	dst.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i((view % GRID) * TILE, int(view / GRID) * TILE))


## One G-buffer sheet, from the full-size render to what the card samples: image work only, so a worker may run it.
## PREMULTIPLIED, AND IT STAYS SO: every texel of the render is opaque or clear, so premultiplying is exact; each halving
## is a 2x2 box of premultiplied texels and so is each mip, so coverage weights every average and no transparent-black
## texel drags a visible one toward black (un-premultiplied mips put a dark fringe on distant cards); the card divides
## by alpha after filtering. BC7, the mip chain kept: stored as an Image, loaded as is, no import step. Null when the
## compression fails.
static func store_image(src: Image) -> Image:
	var img := src.duplicate() as Image
	img.premultiply_alpha()
	var w := img.get_width()
	var h := img.get_height()
	while w > GRID * OUT_TILE:
		w /= 2
		h /= 2
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
	img.generate_mipmaps()
	if img.compress(Image.COMPRESS_BPTC, Image.COMPRESS_SOURCE_GENERIC) != OK:
		return null
	return img
