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
// WF_A2C: the alpha-to-coverage variant (tree_wind.gdshader says how it is made and why), swapped in while the viewport
// runs MSAA: the card's cut becomes per-sample coverage, in the alpha pass (WF_A2C_DEPTH: depth written per covered
// sample as well).
#if defined(WF_A2C) && defined(WF_A2C_DEPTH)
render_mode cull_disabled, specular_disabled, skip_vertex_transform, depth_draw_always, alpha_to_coverage_and_one;
#elif defined(WF_A2C)
render_mode cull_disabled, specular_disabled, skip_vertex_transform, alpha_to_coverage_and_one;
#else
render_mode cull_disabled, specular_disabled, skip_vertex_transform;
#endif
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
// THE TRIMMED CARD (ForestImpostorBaker.trim_of). A view's silhouette fills a fraction
// of the bake's square, and every texel outside it was rasterised, shaded up to the
// first cut below and discarded. With a trim vertex() pulls the quad's corners in to the
// box the three blended frames reach (trim_sil): the conservative union, so no texel the
// cut keeps is ever outside it. `impostor_trim` is RGBA8, a row a view and a mip set,
// column 0 the view's vertical reach and column 1 + k band k's horizontal one (the box
// takes their union), in `sil` units; the set is picked by the card's size on screen
// (`trim_tile` texels a tile). `card_span` is the card's square in mesh units, the quad's
// own size. 0 bands: no trim.
// `alpha_cut` and `alpha_mip_scale` above are what the trim was measured against
// (ForestImpostorBaker TRIM_CUT, half the cut for the WF_A2C variant's, and
// TRIM_MIP_SCALE): lowering either draws texels it trimmed away.
uniform sampler2D impostor_trim : filter_nearest, repeat_disable;
// THE DEPTH SHEET (ForestImpostorBaker channel 2): per texel, how far the surface stands
// in front of the frame's centre plane, in span units, premultiplied as (depth/range +
// 0.5) x coverage in R and coverage in G. `depth_range` is DEPTH_RANGE; 0: no sheet,
// and the frames are reprojected on their planes alone (see frame_setup).
uniform sampler2D impostor_depth : filter_linear_mipmap, repeat_disable;
uniform float depth_range = 0.0;
// THE CARD'S DETAIL BY ITS SIZE ON SCREEN (the bake's tile, in pixels). Below `depth_min_px`
// the depth step is skipped (three reads a pixel; at that size its shift is a pixel or
// less), and below `blend_min_px` the card samples its nearest frame alone instead of
// blending three (two thirds of its reads; 0 keeps the blend at every size).
uniform float depth_min_px = 48.0;
uniform float blend_min_px = 0.0;
// THE DEPTH IS READ BLURRED, this many mip levels coarser than the albedo (and never
// finer than the level after it). One parallax step reads the depth where the ray meets
// the frame's plane, and beside a thin branch that is background: depth 0, the step
// misses the branch, and three frames missing it three ways leave it in dots under the
// cut (measured on the starter pack's dead tree). The sheet is premultiplied, so a
// coarse texel's depth / coverage is the mean depth of the surface around it: the hole
// beside a branch reads the branch's depth, and the whole branch steps together.
uniform float depth_blur_lod : hint_range(0.0, 5.0) = 2.0;
uniform int trim_bands = 0;
uniform int trim_sets = 0;
uniform float trim_tile = 128.0;
uniform float card_span = 0.0;
// WHETHER THE CARD IS TRIMMED (trim_sil): off. Measured on a field of 120k cards (210 m-2 km,
// 1600x900, three runs a variant): trimmed 0.59-0.63 ms of GPU, untrimmed 0.56-0.59. At the
// sizes cards are drawn the vertex stage's lookups cost more than the pixels they save. The
// trim sheet stays bound either way: it holds each view's depth reach (frame_uv's clamp).
uniform bool trim_card = false;

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

// VARYINGS ARE PACKED, four floats a location. Each varying is a location of its own
// whatever its size, Godot's own spatial varyings take most of the 32 a GPU may offer,
// and this shader's ran out (33 used, the depth sheet's frames added). vertex() and
// fragment() work on locals under the names below and pack / unpack them at their ends.
//   sil        silhouette UV: x across (0..1), y base→top (0..1)
//   tile_a..c  atlas offsets of the three blended frames; tile_w their barycentric weights
//   has_ring   1 when a baked view grid resolved
//   vdist      instance distance to the MAIN camera, for the crossfades
//   near_band  this tree's own hand-over sub-band, from wf_tree_band; far_band its far dissolve
//   px_gone    0 = full size on screen .. 1 = at the screen-size floor
varying vec4 v_sil_fc;       // sil, fuv_c
varying float vdist;
varying flat vec4 v_tiles_ab; // tile_a, tile_b
varying flat vec4 v_tc_near;  // tile_c, near_band
varying flat vec4 v_far_kc;   // far_band, fk_c
varying flat vec4 v_w_ring;   // tile_w, has_ring
varying flat vec4 v_zr_gone;  // fzr, px_gone
// The card's basis in VIEW space, for the crown dome in fragment(). VIEW space because
// that is the space `NORMAL` is in when written from fragment(), and it has to be
// written there, not in vertex(), because the whole point is a normal that VARIES
// across the quad.
varying flat vec3 vx_right;
varying flat vec3 vx_up;
varying flat vec3 vx_face;
// EACH FRAME SAMPLED WHERE IT SEES THIS PIXEL (frame_setup). Per frame: where the pixel's
// view ray meets that frame's centre plane, in its own tile (sil units), and how far one
// span of baked depth moves the hit across its tile; then the depth reach the shift is
// clamped to (the trim's bound, so a trimmed card still holds everything it draws).
// Packed two frames a varying: frames a and b in xy and zw (c rides with sil and far_band
// above; fzr with px_gone).
varying vec4 fuv_ab;
varying flat vec4 fk_ab;
// THE TREE'S OWN BASIS (x and up, unit; z is their cross), for fragment(). MODEL_MATRIX there is the MultiMesh
// NODE's transform: the per-instance transform is applied in the vertex stage only, so a normal turned to world by
// it never takes the tree's own yaw, and a card turned 180 deg was lit from the far side.
varying flat vec3 v_inst_x;
varying flat vec3 v_inst_y;

// The union of column `c`'s reach (lo, hi) over the blended frames `views` of trim row
// block `r0`, skipping a frame of zero weight (it draws nothing). Empty: lo > hi, and
// the trim sheet's empty (1, 0) never widens a union.
vec2 trim_reach(int c, int r0, ivec3 views, vec3 w) {
	vec2 u = vec2(1.0, 0.0);
	if (w.x > 0.0) {
		vec2 e = texelFetch(impostor_trim, ivec2(c, r0 + views.x), 0).rg;
		u = vec2(min(u.x, e.x), max(u.y, e.y));
	}
	if (w.y > 0.0) {
		vec2 e = texelFetch(impostor_trim, ivec2(c, r0 + views.y), 0).rg;
		u = vec2(min(u.x, e.x), max(u.y, e.y));
	}
	if (w.z > 0.0) {
		vec2 e = texelFetch(impostor_trim, ivec2(c, r0 + views.z), 0).rg;
		u = vec2(min(u.x, e.x), max(u.y, e.y));
	}
	return u;
}

// THE FRAMES' OWN GEOMETRY. Each frame was baked by an orthographic camera looking
// along its direction, so a point X of the tree lands in its tile at
// 0.5 + ((X - C).Xf, (X - C).Yf) / span and sits (X - C).Zf / span in front of its centre
// plane (C the tile's centre, Xf/Yf/Zf the frame camera's basis: wf_frame_basis). Sampling
// every frame at the CARD's own coordinate, as this card used to, is right only for the
// frame that looks exactly along the view: the others are a few degrees off, their
// texels sit elsewhere, and a blend of three of them is a double image ("ghosting"), and
// a frame's in-plane roll (the overhead frames', a banking camera's) turned the image
// with the camera.
//
// Here the card point P = C + span (R (s.x - 0.5) + U (s.y - 0.5)) is seen along -F (F the
// direction to the camera, R/U the card's axes). Its ray meets frame f's centre plane at
// uv0 = 0.5 + A (s - 0.5), A = B - k n^T, with B the card axes in the frame's (R.Xf ...),
// n = (R.Zf, U.Zf) and k = (F.Xf, F.Yf) / F.Zf; and a surface z spans in front of that
// plane is hit at uv0 + z k. Affine in s, so the vertex stage computes uv0 and the
// rasteriser interpolates it exactly; the fragment reads z at uv0 and steps once.
void frame_setup(vec2 tile, mat3 tb, vec3 r, vec3 u, vec3 f, out mat2 a, out vec2 k) {
	mat3 fm = tb * wf_frame_basis(wf_hemi_oct_dir(tile / float(max(impostor_grid - 1, 1))));
	mat2 b = mat2(vec2(dot(r, fm[0]), dot(r, fm[1])), vec2(dot(u, fm[0]), dot(u, fm[1])));
	vec2 n = vec2(dot(r, fm[2]), dot(u, fm[2]));
	k = vec2(dot(f, fm[0]), dot(f, fm[1])) / max(dot(f, fm[2]), 0.2);
	a = b - outerProduct(k, n);
}

// How far, in card units along x and y, frame f's texels can land from where its own
// tile has them: s = 0.5 + A^-1 (u - 0.5 - z k), so |s - u| <= |(A^-1 - I)(u - 0.5)|
// + |A^-1 k| |z|, with |u - 0.5| <= 0.5 a component and |z| <= `zr`. The trim widens
// by it. A frame seen nearly edge-on (a small determinant) has no useful bound.
vec2 frame_margin(mat2 a, vec2 k, float zr) {
	if (abs(determinant(a)) < 0.3) {
		return vec2(1.0);
	}
	mat2 ai = inverse(a);
	mat2 d = ai - mat2(1.0);
	vec2 sk = abs(ai * k) * zr;
	return vec2((abs(d[0].x) + abs(d[1].x)) * 0.5 + sk.x, (abs(d[0].y) + abs(d[1].y)) * 0.5 + sk.y);
}

// Where this corner of the card sits, in `sil` units: side 0 left / 1 right, top 0 foot /
// 1 crown, pulled in to the box the blended frames `views` (weights `w`) reach: their
// vertical reach (the sheet's column 0) and the union of every band's horizontal reach,
// each widened by the frames' margin `m` (frame_margin: their texels can land that far
// from where their tiles hold them). `tile_px` is the bake's tile on screen in pixels.
//
// A QUAD, NOT A STRIP. The card was an eight-band strip, each row pulled to its own
// bands' reach: on the starter's trees it covered 28-54 % of the square. It was measured
// against the quad on a field of 30k cards (210 m-2 km, 1600x900): 0.45 ms of GPU for the
// strip, 0.21 for the quad, and 0.44 with the strip folded flat (no lookups), so the cost
// was the strip's 18 vertices running this vertex stage, at sizes where few pixels were
// saved. The box keeps the quad's 4 vertices and still drops a narrow tree's empty sides.
//
// WHICH MIP SET. The hardware samples level log2(trim_tile / tile_px) (the card faces
// the camera, so the footprint is isotropic) and its trilinear neighbour; set s holds
// mips 0 .. s + 2, so taking s half a level BELOW the estimate leaves the hardware half a
// level of headroom above it, and every finer level (a negative mip bias under TAA or
// FSR) is in the set already. A card too small for the last set, or whose frames could
// shift their texels past TRIM_MARGIN (a frame a cell away with deep parallax, the rolled
// overhead frames), draws its whole square.
const float TRIM_MARGIN = 0.125;
vec2 trim_sil(float side, float top, float tile_px, ivec3 views, vec3 w, vec2 m) {
	float lod = log2(max(trim_tile / max(tile_px, 1e-3), 1.0));
	int tset = int(floor(max(lod - 0.5, 0.0)));
	if (tset >= trim_sets || max(m.x, m.y) > TRIM_MARGIN) {
		return vec2(side, top);
	}
	int r0 = tset * impostor_grid * impostor_grid;
	vec2 yr = trim_reach(0, r0, views, w);
	// Nothing there: the card on one point.
	if (yr.x > yr.y) {
		return vec2(0.5);
	}
	vec2 xr = vec2(1.0, 0.0);
	for (int j = 1; j <= trim_bands; j++) {
		vec2 e = trim_reach(j, r0, views, w);
		xr = vec2(min(xr.x, e.x), max(xr.y, e.y));
	}
	yr = vec2(max(yr.x - m.y, 0.0), min(yr.y + m.y, 1.0));
	xr = xr.x > xr.y ? vec2(0.5) : vec2(max(xr.x - m.x, 0.0), min(xr.y + m.x, 1.0));
	return vec2(side < 0.5 ? xr.x : xr.y, top < 0.5 ? yr.x : yr.y);
}

void vertex() {
	// The packed varyings' locals (see the varyings), packed at the end.
	vec2 sil;
	vec2 tile_a;
	vec2 tile_b;
	vec2 tile_c;
	vec3 tile_w;
	float has_ring;
	vec2 near_band;
	vec2 far_band;
	float px_gone;
	vec2 fuv_c;
	vec2 fk_c;
	vec3 fzr;
	vec3 inst = MODEL_MATRIX[3].xyz;
	v_inst_x = normalize(MODEL_MATRIX[0].xyz);
	v_inst_y = normalize(MODEL_MATRIX[1].xyz);
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	vec3 cam = INV_VIEW_MATRIX[3].xyz;              // the card FACES the pass's camera
	// ...but its DISTANCE is to the main camera, like the mesh shader's, so one tree
	// sees one distance on both sides of the hand-over (wf_common `wf_cam_pos`).
	vdist = distance(inst, wf_cam_pos(MAIN_CAM_INV_VIEW_MATRIX));
	// An ORTHOGRAPHIC pass (a directional light's shadow cascade) has parallel rays: every card faces along the
	// camera's back axis. Its `INV_VIEW_MATRIX[3]` is only a point far back along the light, and facing that point
	// turned each card off the light's rays by its offset from the cascade centre.
	bool ortho = PROJECTION_MATRIX[3][3] > 0.5;
	vec3 to_cam = ortho ? normalize(INV_VIEW_MATRIX[2].xyz) : normalize(cam - inst);
	// THE CARD IS SPHERICAL, NOT CYLINDRICAL. A world-up lock suits an atlas of azimuths
	// only (a card that tips shows a view it does not have); the hemi-octahedral atlas
	// HAS every elevation, so the card can face the camera squarely, which is what makes
	// it hold up from a plane: a world-up-locked quad has zero projected area looking
	// straight down.
	//
	// THE CARD IS ORIENTED AS ITS FRAME WAS BAKED: right = tree_up x to_cam, up = to_cam x right, the
	// basis the bake's `look_at(centre, up)` gave each frame (wf_common `wf_frame_basis`). It used to take the
	// CAMERA's right for every card, which matches the bake only for a card at screen centre under a level
	// camera: anywhere else the baked image was drawn rolled by the difference. Off-centre cards leaned
	// (the trunks on a slope seen from above all tilted one way), and a rolling camera (a car leaning, a
	// banked road, head tracking) rolled every card with the screen while the mesh trees stayed upright.
	// Near overhead tree_up x to_cam collapses and spins with the azimuth (a radial splay out of screen
	// centre), so within 10-20 deg of the pole it hands over to the camera's right, which has no such
	// degeneracy. ForestAssets.card_basis is this in GDScript (its test pins the properties): keep them equal.
	vec3 cam_right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 tree_up = normalize(MODEL_MATRIX[1].xyz);
	vec3 tr = cross(tree_up, to_cam);
	float tl = length(tr);
	vec3 right = tl > 1e-5 ? tr / tl : cam_right;
	right = normalize(mix(cam_right, right, smoothstep(0.17, 0.34, tl)));
	right = normalize(right - to_cam * dot(right, to_cam));
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
	mat2 fa_m = mat2(1.0);
	mat2 fb_m = mat2(1.0);
	mat2 fc_m = mat2(1.0);
	vec2 fk_a = vec2(0.0);
	vec2 fk_b = vec2(0.0);
	fk_c = vec2(0.0);
	fzr = vec3(0.0);
	ivec3 views = ivec3(0);
	vec2 trim_m = vec2(0.0);
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
		int gi = impostor_grid;
		// The bake's tile on screen (pixels): the card's square without a trim's own size
		// (the tree's height, the square's near enough), on this pass's projection.
		float tile_dv = PROJECTION_MATRIX[3][3] > 0.5 ? 1.0 : max(-(VIEW_MATRIX * vec4(inst, 1.0)).z, 0.1);
		float tile_px_r = (card_span > 0.0 ? card_span : card_pivot_h * 2.0) * sy
			* abs(PROJECTION_MATRIX[1][1]) * 0.5 * VIEWPORT_SIZE.y / tile_dv;
		if (tile_px_r < blend_min_px) {
			// One frame, the heaviest: the others get no weight and fragment() skips them.
			vec2 best = tile_w.x >= tile_w.y && tile_w.x >= tile_w.z ? tile_a : (tile_w.y >= tile_w.z ? tile_b : tile_c);
			tile_a = best;
			tile_w = vec3(1.0, 0.0, 0.0);
		}
		views = ivec3(int(tile_a.y) * gi + int(tile_a.x), int(tile_b.y) * gi + int(tile_b.x),
			int(tile_c.y) * gi + int(tile_c.x));
		mat3 tb = mat3(lx, ly, lz);
		frame_setup(tile_a, tb, right, up, to_cam, fa_m, fk_a);
		frame_setup(tile_b, tb, right, up, to_cam, fb_m, fk_b);
		frame_setup(tile_c, tb, right, up, to_cam, fc_m, fk_c);
		// Each frame's depth reach: the trim's measure of it (column 0's B, in units of
		// half the range) when there is one, else the whole range. No depth sheet: no shift.
		if (depth_range > 0.0) {
			fzr = vec3(depth_range * 0.5);
			if (trim_bands > 0) {
				fzr *= vec3(texelFetch(impostor_trim, ivec2(0, views.x), 0).b,
					texelFetch(impostor_trim, ivec2(0, views.y), 0).b,
					texelFetch(impostor_trim, ivec2(0, views.z), 0).b);
			}
			if (tile_px_r < depth_min_px) {
				fzr = vec3(0.0);     // too small for the step to show: frame_uv skips it
			}
		}
		// The frames' margin, for the trim alone.
		if (trim_card) {
			if (tile_w.x > 0.0) {
				trim_m = max(trim_m, frame_margin(fa_m, fk_a, fzr.x));
			}
			if (tile_w.y > 0.0) {
				trim_m = max(trim_m, frame_margin(fb_m, fk_b, fzr.y));
			}
			if (tile_w.z > 0.0) {
				trim_m = max(trim_m, frame_margin(fc_m, fk_c, fzr.z));
			}
		}
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
		// THE CARD'S OWN SHAPE: the quad's corners, pulled in to this view's box when the
		// bake measured one (trim_sil), with `sil` following them so the atlas stays put
		// under the moved vertices.
		vec2 local = VERTEX.xy;
		if (trim_card && trim_bands > 0 && has_ring > 0.5 && card_span > 0.0) {
			// The tile's height on screen; an orthographic pass (the editor's) has no depth
			// to divide by.
			float depth = PROJECTION_MATRIX[3][3] > 0.5 ? 1.0 : max(-(VIEW_MATRIX * vec4(inst, 1.0)).z, 0.1);
			float tile_px = card_span * sy * abs(PROJECTION_MATRIX[1][1]) * 0.5 * VIEWPORT_SIZE.y / depth;
			sil = trim_sil(UV.x, 1.0 - UV.y, tile_px, views, tile_w, trim_m);
			local = (sil - vec2(0.5)) * card_span;
		}
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
		vec3 world = base + right * (local.x * sx) + up * (local.y * sy) + sway * sy;
		// VIEW SPACE, both of them (skip_vertex_transform): this is the position Godot lights
		// and shadows, so it has to be the one that is drawn.
		VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
		// The facing normal is only the GEOMETRIC normal (shadow normal bias); fragment()
		// overwrites NORMAL with the per-pixel crown dome. It used to be
		// `normalize(to_cam + vec3(0.0, 0.4, 0.0))` for the whole quad, which made the
		// card's brightness track the CAMERA rather than the sun.
		NORMAL = vx_face;
	}
	// Each frame's plane hit for this vertex's place on the card (frame_setup).
	fuv_ab = vec4(vec2(0.5) + fa_m * (sil - vec2(0.5)), vec2(0.5) + fb_m * (sil - vec2(0.5)));
	fuv_c = vec2(0.5) + fc_m * (sil - vec2(0.5));
	fk_ab = vec4(fk_a, fk_b);
	v_sil_fc = vec4(sil, fuv_c);
	v_tiles_ab = vec4(tile_a, tile_b);
	v_tc_near = vec4(tile_c, near_band);
	v_far_kc = vec4(far_band, fk_c);
	v_w_ring = vec4(tile_w, has_ring);
	v_zr_gone = vec4(fzr, px_gone);
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

// Frame `tile`'s atlas UV for this pixel: its plane hit `u0` stepped by the depth it
// baked around there (`k` per span, clamped to the frame's reach `zr`; read
// `depth_blur_lod` levels above `lod`, the albedo's level), and 1 in z when the hit
// lies on the tile (off it the frame has nothing: the tree is inside every tile). The
// depth is read at the plane hit, one step, the usual parallax trade.
vec3 frame_uv(vec2 tile, vec2 u0, vec2 k, float zr, float lod) {
	vec2 grid = vec2(float(impostor_cols), float(impostor_rows));
	vec2 u = u0;
	if (depth_range > 0.0 && zr > 0.0) {
		vec2 d = textureLod(impostor_depth, (tile + clamp(vec2(u0.x, 1.0 - u0.y), 0.002, 0.998)) / grid,
			max(lod, 0.0) + depth_blur_lod).rg;
		float z = d.y > 0.03 ? clamp((d.x / d.y - 0.5) * depth_range, -zr, zr) : 0.0;
		u += z * k;
	}
	float inside = step(0.0, u.x) * step(u.x, 1.0) * step(0.0, u.y) * step(u.y, 1.0);
	return vec3((tile + clamp(vec2(u.x, 1.0 - u.y), 0.002, 0.998)) / grid, inside);
}

void fragment() {
	// The packed varyings, unpacked (see the varyings).
	vec2 sil = v_sil_fc.xy;
	vec2 fuv_c = v_sil_fc.zw;
	vec2 tile_a = v_tiles_ab.xy;
	vec2 tile_b = v_tiles_ab.zw;
	vec2 tile_c = v_tc_near.xy;
	vec2 near_band = v_tc_near.zw;
	vec2 far_band = v_far_kc.xy;
	vec2 fk_c = v_far_kc.zw;
	vec3 tile_w = v_w_ring.xyz;
	float has_ring = v_w_ring.w;
	vec3 fzr = v_zr_gone.xyz;
	float px_gone = v_zr_gone.w;
	float v = sil.y;            // 0 base .. 1 top
	vec3 col;
	float a;
	bool gbuf = has_ring > 0.5 && impostor_gbuffer;
	vec3 gb_n = vec3(0.0);
	float gb_trans = 0.0;
#ifdef WF_A2C
	float a_raw = 1.0;          // the coverage before the mip scale (the alpha-to-coverage variant's ALPHA)
	vec2 aa_uv = sil;           // and the texel coordinate its edge is measured in
#endif

	if (gbuf) {
		// THE G-BUFFER BAKE. Same grid, same three taps and weights as the sheet below,
		// on two premultiplied sheets: blend first, divide by the blended coverage after,
		// which is what premultiplied data is for: a frame that is empty at this texel
		// then simply contributes nothing instead of black.
		//
		// EACH FRAME AT ITS OWN UV (frame_uv): where it saw this pixel's surface. The
		// gradients are the plane hits', which are smooth: the depth step jumps where the
		// baked depth does, and its own derivatives there would throw the sampler onto a
		// coarse mip in a seam through the crown.
		vec2 grid = vec2(float(impostor_cols), float(impostor_rows));
		vec2 fuv_a = fuv_ab.xy;
		vec2 fuv_b = fuv_ab.zw;
		// The level the albedo is sampled at (the plane hit's footprint, as textureGrad is given
		// below); the depth is read depth_blur_lod above it.
		vec2 tuv0 = clamp(vec2(fuv_a.x, 1.0 - fuv_a.y), 0.002, 0.998);
		float lod0 = textureQueryLod(impostor_albedo, (tile_a + tuv0) / grid).y;
		vec3 ua = frame_uv(tile_a, fuv_a, fk_ab.xy, fzr.x, lod0);
		// A frame of no weight is not read at all (blend_min_px, the grid's exact frames).
		vec3 ub = tile_w.y > 0.0 ? frame_uv(tile_b, fuv_b, fk_ab.zw, fzr.y, lod0) : vec3(0.0);
		vec3 uc = tile_w.z > 0.0 ? frame_uv(tile_c, fuv_c, fk_c, fzr.z, lod0) : vec3(0.0);
		vec2 ga_x = dFdx(vec2(fuv_a.x, -fuv_a.y)) / grid;
		vec2 ga_y = dFdy(vec2(fuv_a.x, -fuv_a.y)) / grid;
		vec2 gb_x = dFdx(vec2(fuv_b.x, -fuv_b.y)) / grid;
		vec2 gb_y = dFdy(vec2(fuv_b.x, -fuv_b.y)) / grid;
		vec2 gc_x = dFdx(vec2(fuv_c.x, -fuv_c.y)) / grid;
		vec2 gc_y = dFdy(vec2(fuv_c.x, -fuv_c.y)) / grid;
		// A frame whose hit is off its tile has nothing there.
		vec3 fw = tile_w * vec3(ua.z, ub.z, uc.z);
		vec4 pa = textureGrad(impostor_albedo, ua.xy, ga_x, ga_y);
		vec4 pb = fw.y > 0.0 ? textureGrad(impostor_albedo, ub.xy, gb_x, gb_y) : vec4(0.0);
		vec4 pc = fw.z > 0.0 ? textureGrad(impostor_albedo, uc.xy, gc_x, gc_y) : vec4(0.0);
		vec4 pm = pa * fw.x + pb * fw.y + pc * fw.z;
		a = pm.a;
		if (a < 0.004) discard;
		col = wf_srgb_to_linear(clamp(pm.rgb / a, 0.0, 1.0));
#ifdef WF_A2C
		a_raw = a;
		aa_uv = ua.xy * vec2(textureSize(impostor_albedo, 0));
#endif
		a *= 1.0 + max(lod0, 0.0) * alpha_mip_scale;
		vec4 na = textureGrad(impostor_normal, ua.xy, ga_x, ga_y);
		vec4 nb = fw.y > 0.0 ? textureGrad(impostor_normal, ub.xy, gb_x, gb_y) : vec4(0.0);
		vec4 nc = fw.z > 0.0 ? textureGrad(impostor_normal, uc.xy, gc_x, gc_y) : vec4(0.0);
		float wa = fw.x * na.a;
		float wb = fw.y * nb.a;
		float wc = fw.z * nc.a;
		gb_n = frame_normal(tile_a, na) * wa + frame_normal(tile_b, nb) * wb
			+ frame_normal(tile_c, nc) * wc;
		float wsum = max(wa + wb + wc, 1e-4);
		gb_trans = (na.b * fw.x + nb.b * fw.y + nc.b * fw.z) / wsum;
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
#ifdef WF_A2C
		a_raw = a;
		aa_uv = (tile_a + tuv) / grid * vec2(textureSize(impostor_tex, 0));
#endif
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
#ifdef WF_A2C
		a_raw = a;
		aa_uv = sil * 64.0;
#endif
		float rw = crown_uv.z - crown_uv.x;
		float rh = crown_uv.w - crown_uv.y;
		if (is_trunk < 0.5 && rw > 0.001 && rh > 0.001) {
			vec2 uv = vec2(crown_uv.x + (sil.x * 0.82 + 0.09) * rw,
			               crown_uv.y + (1.0 - clamp((v - 0.2) / 0.8, 0.0, 1.0)) * rh);
			vec4 tx = texture(albedo_tex, uv);
			if (tx.a > 0.5) col = tx.rgb;
		}
	}

#ifdef WF_A2C
	// The edge decides coverage (the engine applies the same mip scale to `a_raw`); nothing under half of it can
	// reach a sample, so it goes before the lighting, as the cut would.
	if (a < alpha_cut * 0.5) discard;
	ALPHA = a_raw;
	ALPHA_ANTIALIASING_EDGE = alpha_cut;
	ALPHA_TEXTURE_COORDINATE = aa_uv;
#else
	if (a < alpha_cut) discard;
#endif
	// CROSSFADE EDGES, on the shared pattern and on THIS TREE's sub-bands. Near: the
	// card keeps the pixels the last mesh level drops (`dth < w`, the mesh keeps
	// `dth >= w`, same `w`, same band). Far: the field dissolves into the haze rather
	// than ending on a line.
	float dth = wf_dither(FRAGCOORD.xy);
	if (vdist < near_band.y && dth >= wf_band(near_band.x, near_band.y, vdist)) discard;
	if (far_cut > 0.0 && vdist > far_band.x
			&& dth < wf_band(far_band.x, far_band.y, vdist)) discard;
	if (dth < px_gone) discard;

	// ALPHA IS NOT WRITTEN, on either path (but the alpha-to-coverage variant's, above). Assigning it at all puts the
	// material on the transparent pipeline: drawn after the opaque pass, sorted per band instance (one per species,
	// not per card), blended at its edges, with the colour pass testing LESS_OR_EQUAL instead of EQUAL. Without MSAA
	// none of that buys anything, so the cutout is a discard and the card stays opaque.
	ROUGHNESS = 0.95;
	if (gbuf) {
		// The mesh's own terms, per texel: the normal it is lit with (tree space -> this
		// instance's yaw -> view), the crown occlusion already in the albedo, and its
		// transmission weight (the bake scaled tree_wind's mix(0.35, 1.35, depth) by
		// 1/1.35). No ambient AO: the mesh has one only from a pack AO map, and none of
		// the dome's guesses below are needed.
		vec3 n_w = normalize(mat3(v_inst_x, v_inst_y, cross(v_inst_x, v_inst_y)) * gb_n);
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
