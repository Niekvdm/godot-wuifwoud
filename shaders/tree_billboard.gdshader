// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
shader_type spatial;
// SKIP_VERTEX_TRANSFORM: vertex() writes VERTEX and NORMAL in VIEW space itself. Writing
// only POSITION is not enough: in Godot's forward shader POSITION moves the RASTER and
// nothing else, while lighting, every shadow lookup, VIEW and fog still run on
// `modelview * VERTEX`, the untouched QuadMesh. That quad is centred on the trunk BASE (the
// lift lives in `card_pivot_h`), so each card would be lit on a square half underground and
// turned by the instance basis, its lower half sampling the terrain's shadow from below
// ground out to the sun's full shadow distance ("billboard shading looks off in direct sun").
render_mode cull_disabled, specular_disabled, skip_vertex_transform;
// Distant-tree impostor: a camera-facing card, one quad per far tree,
// MultiMesh-instanced, crossfaded in from the 3D mesh at its visibility edge.
// The canopy sways with the shared wind uniforms.
//
// A BAKED VIEW RING. On a 50 km2 island most of the trees a player ever sees are
// impostors, so a procedural SILHOUETTE (a blob, a cone or a frond burst picked by
// species family) would be most of the forest: no branch structure, no gaps, no sky
// through the crown, and one outline shared by every species in a family. The pack
// build renders each species from many directions into a per-species sheet, and this
// shader picks the tiles by the camera's bearing on the instance. Same cost per
// instance (one quad, a few texture fetches) carrying the actual tree. The procedural
// path is kept as the fallback for a species with no bake, so an unbuilt pack still
// gets a plausible tree rather than a white card.
//
// A CROSSFADED HAND-OVER. Inside the mesh band the card is collapsed in the VERTEX
// stage and costs nothing (rasterised at full size, a card 40 m away is half the
// screen). Across [near_cut, near_cut + near_fade] it dithers in on the pattern the last
// mesh level dithers out on (wf_common `wf_dither`, complementary), so the tree never
// pops; past that it is the tree. The far edge dissolves the same way into nothing.

// The wind clock, gust envelope, per-tree phase, main-camera distance and crossfade
// dither: shared with tree_wind.gdshader, which draws the same trees inside the
// hand-over.
#include "res://addons/wuifwoud/shaders/wf_common.gdshaderinc"

group_uniforms surface;
// The species' baked view ring: `impostor_cols` x `impostor_rows` tiles, tile k at
// the direction hemi_oct_dir(i/(g-1), j/(g-1)) looks from. `impostor_grid`
// of 0 means no bake resolved: take the procedural path below.
uniform sampler2D impostor_tex : source_color, filter_linear_mipmap, repeat_disable;
// Hemi-octahedral atlas: `impostor_grid` x `impostor_grid` frames, frame (i, j) baked
// looking from `hemi_oct_dir(i/(g-1), j/(g-1))`. 0 = no bake resolved, take the
// procedural silhouette below. `impostor_cols`/`_rows` are kept for the manifest but
// equal the grid.
uniform int impostor_grid = 0;
uniform int impostor_cols = 3;
uniform int impostor_rows = 3;
// MIPMAPS ARE LEFT ON, and the tile grid is the reason that is safe here. At a few
// pixels on screen the sampler reaches a mip coarse enough to bleed across tile
// borders, but every tile in this atlas is THE SAME TREE from another angle, so the
// bleed blends views of one species rather than mixing two. A shared atlas could not
// do this. What bleed does cost is a slightly softened outline, which reads as
// antialiasing at that size.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
// THE G-BUFFER BAKE (the pack build's, ForestImpostorBaker), used when set: two
// sheets on the same grid, both PREMULTIPLIED by coverage so filtering and mips never
// average a visible texel against transparent black (a dark fringe otherwise).
//   impostor_albedo  tex * albedo * the mesh's crown occlusion, at the leaf's TRUE depth
//                    in the crown: sRGB bytes, read RAW (the premultiply happened in
//                    byte space), divided by alpha and decoded here.
//   impostor_normal  the normal the mesh is lit with, in each FRAME's view space (x, y;
//                    z rebuilt), and its transmission weight: raw data.
// The sphere dome below is then not used: it is a guess at what these two carry.
uniform bool impostor_gbuffer = false;
uniform sampler2D impostor_albedo : filter_linear_mipmap, repeat_disable;
uniform sampler2D impostor_normal : filter_linear_mipmap, repeat_disable;
// COVERAGE KEPT THROUGH THE MIPS. A mip averages alpha, so a crown of thin needles
// (a fir's sheet is a third covered) loses ever more texels to the cut as the card
// shrinks: distant forest thins out and reads sparser than the trees it stands for.
// Scaling alpha up with the mip level that is sampled holds the covered share roughly
// constant (B. Golus, "Anti-aliased Alpha Test", 2017). 0 = plain mips.
uniform float alpha_mip_scale : hint_range(0.0, 1.0) = 0.25;
uniform vec4 crown_uv = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec3 foliage : source_color = vec3(0.24, 0.29, 0.10);
uniform vec3 trunk : source_color = vec3(0.36, 0.23, 0.12);
uniform int profile : hint_range(0, 2) = 0;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.35;
// Height of the card's centre above the instance origin, in MESH units. Not in
// QuadMesh.center_offset, which bakes into the vertex positions: fine for a card whose
// own up is world up, wrong for one that tips to face the camera, where the offset would
// swing with the card and the tree would slide off its trunk when seen from above. The
// lift belongs on the TREE's axis, the quad's span on the card's, so they are applied
// separately in vertex().
uniform float card_pivot_h = 0.0;

group_uniforms shading;
// THE CARD IS SHADED AS A CROWN, NOT AS A PLATE, and this block is the whole of it.
// A procedural card or a plain albedo sheet carries no lighting of its own, so every
// term the mesh tree gets from its geometry has to be synthesised here or the card
// simply does not have it: a card with raw albedo, one flat camera-facing normal, no
// occlusion and no transmission reads pale and papery next to the same trees in mesh
// range.
//
// The three terms below are the three the mesh shader applies, under the same names
// and at the same defaults, so a change on one side has an obvious counterpart on the
// other:
//   crown_ao      tree_wind `crown_ao`      : geometric crown occlusion on ALBEDO
//   ao_strength   tree_wind `ao_strength`   : occlusion of AMBIENT (AO_LIGHT_AFFECT
//                                             stays 0, so direct sun is untouched)
//   backlight_col tree_wind `backlight_col` : thin outer leaves transmit
uniform float crown_normal : hint_range(0.0, 1.0) = 0.75;
uniform float crown_ao : hint_range(0.0, 1.0) = 0.45;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform vec3 backlight_col : source_color = vec3(0.10, 0.14, 0.05);
// WHERE THE CROWN SITS ON THE CARD, and how much of the card it fills.
//
// The bake frames a `span`-by-`span` world square from the mesh ORIGIN, and span is
// `max(h, w) * 1.02`, so a tree fills the card VERTICALLY (h/span ~ 0.98) but only
// `w/span` of it horizontally, which on a tall fir is 0.47. Building the crown dome
// over the card's own 0..1 UV would therefore stretch it to twice the tree's width and
// the sun side would barely tilt. `crown_extent` = (span/w, span/h) rescales the dome
// onto the tree; ForestAssets pushes it from the same manifest entry the card's
// size comes from, so the two cannot drift. (1, 1) is the procedural fallback, whose
// quad is sized to the tree by construction.
uniform vec2 crown_extent = vec2(1.0, 1.0);
// The dome's equator in card V. A crown's centre of mass sits above the tree's
// geometric middle, and this is the one number here with no counterpart in the mesh
// shader (which measures a real `crown_centre` off the geometry). At impostor range a
// tree is ~25 px, so an approximate equator is not resolvable; if it ever reads
// wrong, the honest fix is to push the mesh's measured crown centre through the
// manifest rather than to tune this.
uniform float crown_centre_v : hint_range(0.0, 1.0) = 0.56;

// Wind: the globals and functions in wf_common, the SAME travelling gust front as
// tree_wind.gdshader, and it has to be, or the effect dies at the LOD ring, which
// is the worst possible place for it: a gust wave crossing a far hillside is where
// the whole thing reads. One include, so it cannot drift.

group_uniforms lod;
// Shader-side near cutoff: billboards live in COARSE chunks (node-level
// visibility ranges would double-draw over the near 3D trees), so each
// instance admits itself only once its tree has left the mesh band. `near_cut` =
// the mesh shader's `fade_start_m`, `near_fade` = its band width; the spawner
// pushes both from tree_visibility_m.
uniform float near_cut = 810.0;
// FAR-MASS density ramp: billboard-ONLY extras carry a per-instance appear offset in
// COLOR.a (1 = regular impostor, appears at near_cut; toward 0 = appears up to
// density_ramp_m farther out). Without it extra far mass slams in at exactly mesh
// range: a visible density CLIFF at the LOD ring.
uniform float density_ramp_m = 0.0;
uniform float near_fade = 90.0;
// This tree's share of that band: see tree_wind `handover_frac` and wf_common
// `wf_tree_band`. Pushed to the SAME value as the mesh shader's, and applied to the
// SAME [cut, cut + near_fade], so the two sub-bands are identical and the dither stays
// complementary per tree.
uniform float handover_frac : hint_range(0.02, 1.0) = 1.0;
// FAR DISSOLVE. A card cut by the node's visibility range alone ends the impostor field
// on a hard line: a band of trees that "doesn't blend at the edge of the fog". Fog thins
// an object's CONTRAST with distance but never removes it, so wherever the range ends
// there is still a visible silhouette to cut. Dithering out over a band (the near ring's
// mechanism, mirrored) lets the field thin into the haze instead. 0 disables it: a hard
// cut.
uniform float far_cut = 0.0;
uniform float far_fade = 400.0;
// SCREEN-SIZE FLOOR: a card whose TREE stands under `px_min` pixels tall is not drawn,
// and between px_min and 1.5x it dissolves on the shared dither. ForestSpawner
// `card_px_min` explains the number; 0 = off.
uniform float px_min = 0.0;
// THINNING THAT KEEPS THE CANOPY. Past `thin_start_m` the field draws a falling share of
// its cards, down to `1 - thin_max` at `far_cut`: on the GPU path the cull drops each
// card by its own distance (wf_cull.glsl), on the per-chunk path a cell draws a prefix
// of its buffer. Dropping half the cards halves the canopy they cover, so the far forest
// would read sparser than the trees it stands for. With `thin_compensate` every SURVIVOR grows
// by 1/sqrt(keep), which hands it the area of the cards dropped around it: the same
// coverage from fewer cards. `card_keep` is the per-chunk path's exact share for this
// node's cell; -1 (every GPU-path band) means "derive it from this card's distance",
// which is the formula the cull applies.
uniform float thin_start_m = 0.0;
uniform float thin_max = 0.0;
uniform bool thin_compensate = false;
instance uniform float card_keep = -1.0;

varying vec2 sil;            // silhouette UV: x across (0..1), y base→top (0..1)
varying flat vec2 tile_a;    // atlas offsets of the three blended frames
varying flat vec2 tile_b;
varying flat vec2 tile_c;
varying flat vec3 tile_w;    // their barycentric weights
varying flat float has_ring; // 1 when a baked view grid resolved
varying float vdist;         // instance distance to the MAIN camera, for the crossfades
varying flat vec2 near_band; // this tree's own hand-over sub-band, from wf_tree_band
varying flat vec2 far_band;  // and its own far dissolve
varying flat float px_gone;  // 0 = full size on screen .. 1 = at the screen-size floor
// The card's basis in VIEW space, for the crown dome in fragment(). VIEW space because
// that is the space `NORMAL` is in when written from fragment(), and it has to be
// written there, not in vertex(), because the whole point is a normal that VARIES
// across the quad.
varying flat vec3 vx_right;
varying flat vec3 vx_up;
varying flat vec3 vx_face;

void vertex() {
	vec3 inst = MODEL_MATRIX[3].xyz;
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	vec3 cam = INV_VIEW_MATRIX[3].xyz;              // the card FACES the pass's camera
	// ...but its DISTANCE is to the main camera, like the mesh shader's, so one tree
	// sees one distance on both sides of the hand-over (wf_common `wf_cam_pos`).
	vdist = distance(inst, wf_cam_pos(MAIN_CAM_INV_VIEW_MATRIX));
	vec3 to_cam = normalize(cam - inst);
	// THE CARD IS SPHERICAL, NOT CYLINDRICAL. A world-up lock suits an atlas of azimuths
	// only (a card that tips shows a view it does not have); the hemi-octahedral atlas
	// HAS every elevation, so the card can face the camera squarely, which is what makes
	// it hold up from a plane: a world-up-locked quad has zero projected area looking
	// straight down.
	//
	// A basis of `cross(world_up, to_cam)` COLLAPSES when the camera is overhead, and a
	// fallback for it hands every card the same `right`: a radial splay out of screen
	// centre. Building the basis from the camera's own right vector has no such
	// degeneracy.
	vec3 right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 up = normalize(cross(to_cam, right));
	sil = vec2(UV.x, 1.0 - UV.y);            // QuadMesh v runs top→bottom
	// The card basis, carried into VIEW space for the crown dome in fragment(). Set
	// before the cull branch so the varyings are never left undefined.
	vx_right = normalize((VIEW_MATRIX * vec4(right, 0.0)).xyz);
	vx_up = normalize((VIEW_MATRIX * vec4(up, 0.0)).xyz);
	vx_face = normalize((VIEW_MATRIX * vec4(to_cam, 0.0)).xyz);

	// WHICH FRAMES. The direction is taken in the INSTANCE's frame: every tree
	// carries its own random yaw, and reading the bearing in world space would lock a
	// whole stand to one view so the forest rotates as one object when the player
	// turns. Encode to the hemi-octahedral square, then blend the THREE frames of the
	// grid cell it lands in (wf_common); a nearest-frame pick pops as the camera
	// moves, and three taps is the standard blend for this parameterisation.
	has_ring = 0.0;
	tile_a = vec2(0.0);
	tile_b = vec2(0.0);
	tile_c = vec2(0.0);
	tile_w = vec3(1.0, 0.0, 0.0);
	if (impostor_grid > 0) {
		vec3 lx = normalize(MODEL_MATRIX[0].xyz);
		vec3 ly = normalize(MODEL_MATRIX[1].xyz);
		vec3 lz = normalize(MODEL_MATRIX[2].xyz);
		// Into the instance's own basis, and clamp to the upper hemisphere: the atlas
		// has no frames below the horizon, and a camera slightly under a hillside tree
		// would otherwise encode off the square.
		vec3 lv = vec3(dot(to_cam, lx), max(dot(to_cam, ly), 0.0), dot(to_cam, lz));
		vec2 g = wf_hemi_oct_uv(normalize(lv)) * float(impostor_grid - 1);
		vec2 base = floor(g);
		vec4 w = wf_frame_weights(g - base);
		tile_w = w.xyz;
		tile_a = base;
		tile_b = base + mix(vec2(0.0, 1.0), vec2(1.0, 0.0), w.w);
		tile_c = base + vec2(1.0);
		float lim = float(impostor_grid - 1);
		tile_a = clamp(tile_a, vec2(0.0), vec2(lim));
		tile_b = clamp(tile_b, vec2(0.0), vec2(lim));
		tile_c = clamp(tile_c, vec2(0.0), vec2(lim));
		has_ring = 1.0;
	}

	// BAND, IN THE VERTEX STAGE. Inside the mesh band (before `cut`) or past `far_cut`
	// the card is sent behind the far plane and never rasterised; the crossfade
	// edges are decided per pixel in fragment(). Per-instance appear distance
	// (COLOR.a) ramps any far-mass extras in gradually; a regular impostor carries
	// 1.0 and appears at the hand-over.
	float cut = near_cut + (1.0 - COLOR.a) * density_ramp_m;
	// THIS TREE'S sub-bands. The mesh shader derives the near one from the same
	// [cut, cut + near_fade] and the same instance origin, so the two stay exact
	// complements; see wf_common `wf_tree_band` for why it is per tree at all.
	near_band = wf_tree_band(cut, cut + near_fade, inst.xz, handover_frac);
	far_band = wf_tree_band(far_cut - far_fade, far_cut, inst.xz, handover_frac);
	// The thinning share at this card, and the growth that gives it back its canopy.
	if (thin_compensate && thin_max > 0.0) {
		float keep = card_keep >= 0.0 ? card_keep
			: 1.0 - thin_max * clamp((vdist - thin_start_m)
				/ max(far_cut - thin_start_m, 1.0), 0.0, 1.0);
		float grow = inversesqrt(clamp(keep, 0.1, 1.0));
		sx *= grow;
		sy *= grow;
	}
	// How tall THIS tree stands on screen: its height (`card_pivot_h` is half of it, in
	// mesh units, times the instance scale) through this pass's projection and viewport.
	px_gone = 0.0;
	if (px_min > 0.0) {
		// abs(): Godot's RenderingDevice projection carries the Vulkan Y FLIP
		// (Projection::set_depth_correction puts -1 in [1][1]), so the raw entry is
		// -cot(fov/2): a negative height, every card under the floor, and the whole
		// impostor field dissolved.
		float px = 2.0 * card_pivot_h * sy * abs(PROJECTION_MATRIX[1][1]) * 0.5 * VIEWPORT_SIZE.y
			/ max(vdist, 1.0);
		px_gone = 1.0 - smoothstep(px_min, px_min * 1.5, px);   // edges ascending: GLSL leaves reversed ones undefined
	}
	if (vdist < near_band.x || (far_cut > 0.0 && vdist >= far_band.y) || px_gone >= 1.0) {
		// Every corner on ONE point behind the eye: a zero-area quad the rasteriser drops.
		// (It used to be POSITION = (0, 0, 2, 1); writing POSITION anywhere switches the
		// whole shader to OVERRIDE_POSITION, which is exactly the trap described at the top.)
		VERTEX = vec3(0.0, 0.0, 1.0);
		NORMAL = vec3(0.0, 0.0, 1.0);
	} else {
		float cv = sil.y;
		// THE CLOCK IS A STATE, NOT `TIME * rate`: see wf_common.gdshaderinc.
		float t = wuifwoud_wind_phase;
		float phase = wf_tree_phase(inst.xz);
		float gust = sin(t + phase) * 0.7 + sin(t * 2.3 + phase * 1.7) * 0.3;
		vec2 gdir = wf_wind_unit();
		float env = wf_gust_env(inst.xz);
		vec3 sway = vec3(gdir.x, 0.0, gdir.y) * (gust * wuifwoud_wind_strength * env * cv * cv);
		// Lift along the INSTANCE's up (the trunk), span along the CARD's axes.
		vec3 inst_up = normalize(MODEL_MATRIX[1].xyz);
		vec3 base = inst + inst_up * (card_pivot_h * sy);
		vec3 world = base + right * (VERTEX.x * sx) + up * (VERTEX.y * sy) + sway * sy;
		// VIEW SPACE, both of them (skip_vertex_transform): this is the position Godot lights
		// and shadows, so it has to be the one that is drawn.
		VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
		// The facing normal is only the GEOMETRIC normal (shadow normal bias); fragment()
		// overwrites NORMAL with the per-pixel crown dome. It used to be
		// `normalize(to_cam + vec3(0.0, 0.4, 0.0))` for the whole quad, which made the
		// card's brightness track the CAMERA rather than the sun.
		NORMAL = vx_face;
	}
}

// One G-buffer normal tap into the TREE's space: the bake stored x/y of the normal in
// that frame's view space (premultiplied by coverage, hence the divide), z points at the
// camera so it is rebuilt, and the frame's own camera basis takes it to object space,
// where the three taps can be blended, which three different view spaces could not.
vec3 frame_normal(vec2 tile, vec4 px) {
	vec3 e = px.rgb / max(px.a, 1e-4);
	vec2 xy = e.xy * 2.0 - 1.0;
	vec3 nv = vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy))));
	return wf_frame_basis(wf_hemi_oct_dir(tile / float(max(impostor_grid - 1, 1)))) * nv;
}

void fragment() {
	float v = sil.y;            // 0 base .. 1 top
	vec3 col;
	float a;
	bool gbuf = has_ring > 0.5 && impostor_gbuffer;
	vec3 gb_n = vec3(0.0);
	float gb_trans = 0.0;

	if (gbuf) {
		// THE G-BUFFER BAKE. Same grid, same three taps and weights as the sheet below,
		// on two premultiplied sheets: blend first, divide by the blended coverage after,
		// which is what premultiplied data is for: a frame that is empty at this texel
		// then simply contributes nothing instead of black.
		vec2 grid = vec2(float(impostor_cols), float(impostor_rows));
		vec2 tuv = clamp(vec2(sil.x, 1.0 - sil.y), 0.002, 0.998);
		vec2 ua = (tile_a + tuv) / grid;
		vec2 ub = (tile_b + tuv) / grid;
		vec2 uc = (tile_c + tuv) / grid;
		vec4 pa = texture(impostor_albedo, ua);
		vec4 pb = texture(impostor_albedo, ub);
		vec4 pc = texture(impostor_albedo, uc);
		vec4 pm = pa * tile_w.x + pb * tile_w.y + pc * tile_w.z;
		a = pm.a;
		if (a < 0.004) discard;
		col = wf_srgb_to_linear(clamp(pm.rgb / a, 0.0, 1.0));
		a *= 1.0 + max(textureQueryLod(impostor_albedo, ua).y, 0.0) * alpha_mip_scale;
		vec4 na = texture(impostor_normal, ua);
		vec4 nb = texture(impostor_normal, ub);
		vec4 nc = texture(impostor_normal, uc);
		float wa = tile_w.x * na.a;
		float wb = tile_w.y * nb.a;
		float wc = tile_w.z * nc.a;
		gb_n = frame_normal(tile_a, na) * wa + frame_normal(tile_b, nb) * wb
			+ frame_normal(tile_c, nc) * wc;
		float wsum = max(wa + wb + wc, 1e-4);
		gb_trans = (na.b * tile_w.x + nb.b * tile_w.y + nc.b * tile_w.z) / wsum;
	} else if (has_ring > 0.5) {
		// Baked grid: the card spans exactly the world square the bake framed, so the
		// silhouette UV is the tile UV with no fitting. A half-texel inset keeps
		// bilinear taps off the neighbouring tile at the fine mips.
		//
		// V IS FLIPPED BACK. `sil.y` was built base→top for the procedural path, and
		// an atlas row runs top→bottom like any image; feeding one to the other plants
		// every impostor on its crown, which is the single most likely way to get this
		// wrong and it renders as a forest of upside-down trees.
		//
		// THREE TAPS, WEIGHTED. Blending the frames' COLOUR (rather than picking one)
		// is what removes the pop as the camera moves; the alpha is blended the same
		// way so the silhouette crossfades with it instead of snapping.
		vec2 grid = vec2(float(impostor_cols), float(impostor_rows));
		vec2 tuv = clamp(vec2(sil.x, 1.0 - sil.y), 0.002, 0.998);
		vec4 ta = texture(impostor_tex, (tile_a + tuv) / grid);
		vec4 tb = texture(impostor_tex, (tile_b + tuv) / grid);
		vec4 tc = texture(impostor_tex, (tile_c + tuv) / grid);
		vec4 tx = ta * tile_w.x + tb * tile_w.y + tc * tile_w.z;
		col = tx.rgb;
		a = tx.a;
	} else {
		// FALLBACK: no bake for this species. A procedural silhouette washed with the
		// crown rect.
		float x = sil.x - 0.5;
		a = 0.0;
		float is_trunk = 0.0;
		float trunk_h = profile == 2 ? 0.58 : 0.26;
		if (v < trunk_h && abs(x) < 0.045) {
			a = 1.0;
			is_trunk = 1.0;
		}
		if (profile == 1) {
			float base = trunk_h * 0.5;
			float w = mix(0.42, 0.0, clamp((v - base) / (1.0 - base), 0.0, 1.0));
			if (v >= base && abs(x) < w) a = 1.0;
		} else if (profile == 2) {
			vec2 c = vec2(x * 1.25, v - 0.74);
			if (v > trunk_h && dot(c, c) < 0.30 * 0.30) a = 1.0;
		} else {
			vec2 c = vec2(x / 0.46, (v - 0.60) / 0.44);
			if (dot(c, c) < 1.0) a = 1.0;
		}
		col = mix(foliage, trunk, is_trunk);
		float rw = crown_uv.z - crown_uv.x;
		float rh = crown_uv.w - crown_uv.y;
		if (is_trunk < 0.5 && rw > 0.001 && rh > 0.001) {
			vec2 uv = vec2(crown_uv.x + (sil.x * 0.82 + 0.09) * rw,
			               crown_uv.y + (1.0 - clamp((v - 0.2) / 0.8, 0.0, 1.0)) * rh);
			vec4 tx = texture(albedo_tex, uv);
			if (tx.a > 0.5) col = tx.rgb;
		}
	}

	if (a < alpha_cut) discard;
	// CROSSFADE EDGES, on the shared pattern and on THIS TREE's sub-bands. Near: the
	// card keeps the pixels the last mesh level drops (`dth < w`, the mesh keeps
	// `dth >= w`, same `w`, same band). Far: the field dissolves into the haze rather
	// than ending on a line.
	float dth = wf_dither(FRAGCOORD.xy);
	if (vdist < near_band.y && dth >= wf_band(near_band.x, near_band.y, vdist)) discard;
	if (far_cut > 0.0 && vdist > far_band.x
			&& dth < wf_band(far_band.x, far_band.y, vdist)) discard;
	if (dth < px_gone) discard;

	// ALPHA IS DELIBERATELY NOT WRITTEN, on either path. Assigning it at all puts the
	// material on the transparent pipeline, which would sort every impostor card on the
	// island per frame; the cutout is done with discard precisely to stay opaque.
	ROUGHNESS = 0.95;
	if (gbuf) {
		// The mesh's own terms, per texel: the normal it is lit with (tree space -> this
		// instance's yaw -> view), the crown occlusion already in the albedo, and its
		// transmission weight (the bake scaled tree_wind's mix(0.35, 1.35, depth) by
		// 1/1.35). No ambient AO: the mesh has one only from a pack AO map, and none of
		// the dome's guesses below are needed.
		vec3 n_w = normalize(mat3(MODEL_MATRIX) * gb_n);
		NORMAL = normalize((VIEW_MATRIX * vec4(n_w, 0.0)).xyz);
		ALBEDO = col * COLOR.rgb;
		BACKLIGHT = backlight_col * (1.35 * gb_trans);
	} else {
		// ── THE CROWN DOME (pre-G-buffer bakes and the procedural fallback) ────────
		// The card is a flat quad carrying an unshaded albedo dump, so on its own it has
		// no shape to light. Treat it as the SPHERE the crown approximately is: offset
		// from the dome's equator, rescaled by `crown_extent` so the ball spans the tree
		// rather than the (much wider) card, gives a normal that leans away from centre.
		// `r` doubles as the stand-in for the mesh shader's `crown_depth`, which it is
		// NOT on the visible side: the centre of a card is the crown's FRONT shell, the
		// outermost leaves, so this path darkens exactly the sunlit face. The G-buffer
		// bake above replaces it with the real per-texel depth.
		vec2 d = vec2(sil.x - 0.5, v - crown_centre_v) * 2.0 * crown_extent;
		float r2 = min(1.0, dot(d, d));
		float r = sqrt(r2);
		vec3 dome = normalize(vx_right * d.x + vx_up * d.y + vx_face * sqrt(1.0 - r2));
		NORMAL = normalize(mix(vx_face, dome, crown_normal));
		float shade = mix(1.0 - crown_ao, 1.0, r);
		ALBEDO = col * shade * COLOR.rgb;
		// AMBIENT ONLY: AO_LIGHT_AFFECT stays at its default 0.
		AO = mix(1.0, shade, ao_strength);
		BACKLIGHT = backlight_col * mix(0.35, 1.35, r);
	}
}
