# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## THE IMPOSTOR BAKE: a tree species' hemi-octahedral G-buffer atlases (albedo, normal + transmission, depth) rendered
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
## The G-buffer channels a view renders (impostor_bake.gdshader `channel`): 0 albedo, 1 normal + transmission, 2 depth.
const CHANNELS := 3
## THE DEPTH SHEET's range: a texel's depth is its distance in front of the tile's centre plane (toward the frame's
## camera) in units of the bake's `span`, stored as depth / DEPTH_RANGE + 0.5. A tree's every point lies within
## span × 0.71 of the centre (span covers the larger of its height and width), so 1.5 holds it with room.
const DEPTH_RANGE := 1.5
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

## THE TRIMMED CARD. A view's silhouette fills a fraction of the bake's square (a tall narrow tree a third of it), and
## the card used to rasterise all of it and discard the rest per pixel. The card is a strip of TRIM_BANDS horizontal
## bands instead, each pulled in by the vertex shader to what its views reach (trim_of). Eight: 18 vertices and 16
## triangles against the quad's 4 and 2. Not yet tuned against measured overdraw.
const TRIM_BANDS := 8
## Mip sets measured: set s holds what mips 0 .. s + TRIM_MIP_SPAN - 1 can show, and the card picks a set by its size on
## screen; a card smaller than the last set's draws its plain square. Three: on the starter pack's trees the strip covers
## 28-54 % of the square at set 0, 37-62 % at set 1 and 58-80 % at set 2, and a fourth (to mip 5, whose texel is a
## quarter of the tile) 98-100 %: no saving for eight times the triangles.
const TRIM_SETS := 3
## The mips a set holds above its own: a sampled level and the next (trilinear), and one of slack for the card's
## estimate of the level the hardware picks (see tree_billboard.gdshader `trim_sil`).
const TRIM_MIP_SPAN := 3
## The lowest alpha the card draws and its coverage-keeping mip boost, as tree_billboard.gdshader has them: HALF its
## `alpha_cut` (0.35), because the alpha-to-coverage variant (WF_A2C, under MSAA) keeps a fragment down to half the cut
## and lets the edge decide its samples; and `alpha_mip_scale` (the card sets neither). A texel can be drawn only at
## alpha >= TRIM_CUT / boost; the trim keeps every texel that can, and changes there belong here too.
const TRIM_CUT := 0.175
const TRIM_MIP_SCALE := 0.25
## Headroom under that threshold (BC7's alpha error, a hardware LOD a little past the estimate).
const TRIM_SAFETY := 0.8

var _world: World3D = null
var _vps: Array[SubViewport] = []
var _cams: Array[Camera3D] = []
var _subjects: Array[MeshInstance3D] = []   # a channel's subject: on render layer 1 << channel
var _atlas: Image = null
var _atlas_n: Image = null
var _atlas_d: Image = null
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
		"projection": "hemi_oct", "gbuffer": true, "trim_bands": TRIM_BANDS, "trim_sets": TRIM_SETS,
		"depth_range": DEPTH_RANGE}


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
	_atlas_d = Image.create(GRID * TILE, GRID * TILE, false, Image.FORMAT_RGBA8)
	_atlas_d.fill(Color(0, 0, 0, 0))
	# The horizontal reach FROM THE ORIGIN, and one square framing for every view (a per-view frame makes the tree
	# breathe as the camera orbits). `span` is the contract with the runtime card: the tile covers a span-by-span world
	# square centred at half height, and the card is sized from THIS number.
	var half := maxf(maxf(absf(ab.position.x), absf(ab.end.x)), maxf(absf(ab.position.z), absf(ab.end.z)))
	var span := maxf(ab.size.y, half * 2.0) * 1.02
	_meta = {"h": ab.size.y, "w": half * 2.0, "span": span}
	# The depth channel measures from the tile's centre (where every camera aims) in span units: the runtime card's
	# own centre and size, so a baked depth is a shift the card can apply as it is.
	for ch in CHANNELS:
		var sub := _subjects[ch]
		for si in sub.get_surface_override_material_count():
			var bm := sub.get_surface_override_material(si) as ShaderMaterial
			if bm != null:
				bm.set_shader_parameter("depth_centre", Vector3(0, ab.size.y * 0.5, 0))
				bm.set_shader_parameter("depth_scale", 1.0 / (span * DEPTH_RANGE))
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
		_blit(_round * GRID + c, imgs[c + 2 * GRID], _atlas_d)
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
	return {"albedo": _atlas, "normal": _atlas_n, "depth": _atlas_d, "h": float(_meta.get("h", 0.0)), "w": float(_meta.get("w", 0.0)),
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


## The grid position (u, v in [0, 1]) of the view looking FROM direction `dir` (a direction under the horizon taken at
## the horizon): the inverse of hemi_oct_dir.
static func hemi_oct_uv(dir: Vector3) -> Vector2:
	var d := Vector3(dir.x, maxf(dir.y, 0.0), dir.z)
	var s := absf(d.x) + absf(d.y) + absf(d.z)
	if s < 1e-9:
		return Vector2(0.5, 0.5)
	var px := d.x / s
	var pz := d.z / s
	return Vector2((px + pz + 1.0) * 0.5, (pz + 1.0 - px) * 0.5)


## The view (column, row) of the GRID × GRID sheet nearest direction `dir`.
static func view_cell(dir: Vector3) -> Vector2i:
	var uv := hemi_oct_uv(dir)
	var n1 := float(GRID - 1)
	return Vector2i(clampi(roundi(uv.x * n1), 0, GRID - 1), clampi(roundi(uv.y * n1), 0, GRID - 1))


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
##
## `rg`: THE DEPTH SHEET, two channels: the render writes (depth, 1), so premultiplied it is (depth × coverage, coverage)
## and the card divides the one by the other, as it divides the other sheets by their alpha. BC5 (RGTC_RG): two
## independent 8-bit-interpolated channels, the same byte a texel as BC7.
static func store_image(src: Image, rg := false) -> Image:
	var img := src.duplicate() as Image
	img.premultiply_alpha()
	var w := img.get_width()
	var h := img.get_height()
	while w > GRID * OUT_TILE:
		w /= 2
		h /= 2
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
	if rg:
		img.convert(Image.FORMAT_RG8)
	img.generate_mipmaps()
	# Two channels go to BC5 through the S3TC family; the NORMAL source pins them as RG (a generic one may read two
	# equal channels as one and pick BC4).
	if rg:
		if img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_NORMAL) != OK or img.get_format() != Image.FORMAT_RGTC_RG:
			return null
	elif img.compress(Image.COMPRESS_BPTC, Image.COMPRESS_SOURCE_GENERIC) != OK:
		return null
	return img


## The lowest alpha a texel of mip `m` can hold and still be drawn: the card boosts the sampled alpha by
## 1 + lod * TRIM_MIP_SCALE before its cut, and mip m is sampled up to lod m + 1 (trilinear).
static func trim_threshold(m: int) -> float:
	return TRIM_CUT / (1.0 + float(m + 1) * TRIM_MIP_SCALE) * TRIM_SAFETY


## The card's trim from a stored albedo sheet (store_image's, compressed or not): an RGBA8 image TRIM_BANDS + 1 wide and
## TRIM_SETS × GRID² tall, row `set × GRID² + view` (view = row × GRID + column, the bake's order). Column 0 is the view's
## vertical reach, column 1 + k band k's horizontal reach; (lo, hi) in R and G, in tile units, x rightward and y UP from
## the tile's foot (the card's `sil`), band k spanning y k/TRIM_BANDS .. (k + 1)/TRIM_BANDS. Empty: (1, 0). Column 0's B
## is the view's DEPTH REACH, the largest |depth| of a covered texel of `depth` (the stored depth sheet), in units of
## DEPTH_RANGE / 2, rounded up: how far the card's depth shift can move that view's texels (0 without a depth sheet).
## Image work only: a worker may run it. Null when a sheet cannot be read.
##
## CONSERVATIVE, AND THAT IS THE WHOLE CONTRACT: a trim that is too tight cuts a straight edge through a crown, which is
## far worse than the overdraw it saves. A texel counts when its alpha reaches trim_threshold of its mip, measured on
## the sheet AS STORED (BC7's error included) and on every mip a set holds; it reaches one texel further every way (a
## bilinear tap reads its neighbours); and the card takes the union over the three frames it blends, whose blend is
## convex (a pixel passes only where some frame can). Reaches are rounded outward to the byte.
static func trim_of(stored: Image, depth: Image = null) -> Image:
	if stored == null:
		return null
	var zreach := depth_reach_of(depth)
	if depth != null and zreach.is_empty():
		return null
	var img := stored.duplicate() as Image
	if img.is_compressed() and img.decompress() != OK:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if not img.has_mipmaps():
		img.generate_mipmaps()
	var w := img.get_width()
	var tile0 := w / GRID
	var views := GRID * GRID
	var cols := TRIM_BANDS + 1
	var mips := mini(TRIM_SETS + TRIM_MIP_SPAN - 1, img.get_mipmap_count() + 1)
	var data := img.get_data()
	# Per mip: views × cols × (lo, hi), empty (1, 0).
	var per_mip: Array[PackedFloat32Array] = []
	for m in mips:
		var reach := PackedFloat32Array()
		reach.resize(views * cols * 2)
		for i in views * cols:
			reach[i * 2] = 1.0
			reach[i * 2 + 1] = 0.0
		var t := tile0 >> m
		if t < 1:
			per_mip.append(reach)
			continue
		var mw := w >> m
		var off := img.get_mipmap_offset(m)
		var thr := maxi(int(floor(trim_threshold(m) * 255.0)), 1)
		var d := 1.0 / float(t)
		for v in views:
			var ox := (v % GRID) * t
			var oy := (v / GRID) * t
			var base := v * cols * 2
			for ty in t:
				var row := off + ((oy + ty) * mw + ox) * 4 + 3
				var xl := -1
				for tx in t:
					if data[row + tx * 4] >= thr:
						xl = tx
						break
				if xl < 0:
					continue
				var xr := xl
				for tx in range(t - 1, xl, -1):
					if data[row + tx * 4] >= thr:
						xr = tx
						break
				# One texel further every way (bilinear); image rows run top→bottom, the reach's y bottom→top.
				var x0 := maxf(float(xl - 1) * d, 0.0)
				var x1 := minf(float(xr + 2) * d, 1.0)
				var y0 := maxf(float(t - ty - 2) * d, 0.0)
				var y1 := minf(float(t - ty + 1) * d, 1.0)
				reach[base] = minf(reach[base], y0)
				reach[base + 1] = maxf(reach[base + 1], y1)
				for k in TRIM_BANDS:
					if y0 < float(k + 1) / TRIM_BANDS and y1 > float(k) / TRIM_BANDS:
						var b := base + (1 + k) * 2
						reach[b] = minf(reach[b], x0)
						reach[b + 1] = maxf(reach[b + 1], x1)
		per_mip.append(reach)
	# Bytes written directly: set_pixel truncates `v * 255`, which would round an upper reach inward.
	var bytes := PackedByteArray()
	bytes.resize(cols * TRIM_SETS * views * 4)
	for s in TRIM_SETS:
		var last := mini(s + TRIM_MIP_SPAN, mips)
		for v in views:
			for c in cols:
				var i := (v * cols + c) * 2
				var lo := 1.0
				var hi := 0.0
				for m in last:
					lo = minf(lo, per_mip[m][i])
					hi = maxf(hi, per_mip[m][i + 1])
				var o := ((s * views + v) * cols + c) * 4
				if lo > hi:
					bytes[o] = 255
					bytes[o + 1] = 0
				else:
					bytes[o] = clampi(int(floorf(lo * 255.0)), 0, 255)
					bytes[o + 1] = clampi(int(ceilf(hi * 255.0)), 0, 255)
				if c == 0 and not zreach.is_empty():
					bytes[o + 2] = clampi(int(ceilf(zreach[v] / (DEPTH_RANGE * 0.5) * 255.0)), 0, 255)
				bytes[o + 3] = 255
	return Image.create_from_data(cols, TRIM_SETS * views, false, Image.FORMAT_RGBA8, bytes)


## Per view, the largest |depth| (span units) of a texel of the stored depth sheet `depth` (store_image's, `rg`) that
## is at least half covered at mip 0. A barely covered texel's depth is its byte divided by a small coverage, mostly
## quantisation noise (one step at 8/255 coverage is an eighth of the range), and counting those put nearly every
## view at the range's end, measured on the starter pack. The card CLAMPS its depth to this reach, so the trim's margin
## holds whatever the sheet says. [] without a sheet, or when it cannot be read.
static func depth_reach_of(depth: Image) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if depth == null:
		return out
	var img := depth.duplicate() as Image
	if img.is_compressed() and img.decompress() != OK:
		return out
	if img.get_format() != Image.FORMAT_RG8:
		img.convert(Image.FORMAT_RG8)
	var t := img.get_width() / GRID
	var w := img.get_width()
	var data := img.get_data()
	out.resize(GRID * GRID)
	for v in GRID * GRID:
		var ox := (v % GRID) * t
		var oy := (v / GRID) * t
		var reach := 0.0
		for ty in t:
			var row := ((oy + ty) * w + ox) * 2
			for tx in t:
				var a := data[row + tx * 2 + 1]
				if a < 128:
					continue
				var z := absf(float(data[row + tx * 2]) / float(a) - 0.5) * DEPTH_RANGE
				reach = maxf(reach, z)
		out[v] = minf(reach, DEPTH_RANGE * 0.5)
	return out
