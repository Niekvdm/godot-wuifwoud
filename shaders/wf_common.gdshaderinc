// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
// Shared by tree_wind.gdshader (mesh trees) and tree_billboard.gdshader (impostor
// cards). THE TWO SHADERS DRAW THE SAME TREES either side of a crossfade, so
// everything they have to agree on lives here and nowhere else: the wind clock, the
// gust envelope, the per-tree sway phase, which camera a distance is measured from,
// and the dither pattern that splits a pixel between the outgoing and the incoming
// draw. A copy in each shader is how the far forest ends up swaying to a different
// rhythm than the near one.

// ── WIND CLOCK ──────────────────────────────────────────────────────────────────
// INTEGRATED ON THE CPU (ForestSpawner._advance_wind, one global set per
// frame), NEVER REBUILT FROM TIME. A phase built from an absolute clock (`TIME *
// wind_speed`, `TIME * gust_speed`, with the rates re-pushed from the gusted wind)
// jumps whenever its rate changes: at TIME = 600 s a 1 % change of `wind_speed` moves
// the sway phase by 6 radians, so every gust change would snap the whole forest to a
// new pose, and it reads as the forest "catching up" with the weather.
//
// A phase is STATE. It advances by rate*dt each frame and wraps at a period where
// every harmonic below completes a whole number of cycles, so no frame ever sees a
// discontinuity. The wrap periods are pinned here next to the harmonics they serve:
//   wuifwoud_wind_phase  wraps at 200*PI: sway harmonics are 0.75, 1.37, 1.9, 2.3, 4.6
//                                      (x100 all integers, so all whole at 200*PI)
//   wuifwoud_gust_phase  wraps at VEG_GUST_WRAP_M: the gust octaves are 1.00 and 0.37
//                                      cycles per gust length (x100 integers)
// ForestSpawner mirrors both constants; change them together.
global uniform float wuifwoud_wind_phase;     // sway clock, radians; wraps at 200*PI
global uniform float wuifwoud_gust_phase;     // gust-front travel, METRES downwind
global uniform vec2 wuifwoud_wind_dir;        // unit XZ, rotated smoothly on the CPU
global uniform float wuifwoud_wind_strength;  // metres of canopy-tip travel at full throw
global uniform float wuifwoud_gust_depth;     // how far a lull drops below a gust, 0..1

// Gust geometry. CONSTANTS, not uniforms: the wrap period of wuifwoud_gust_phase is
// 100 gust lengths, and a per-material uniform that drifted from it would put a
// visible jump into the far field once an hour. Sized after a tree pack's own wind
// script (a 600 m gust field, 175 m trunk flex): 40-120 m reads as chatter at driving
// speed, a literal 600 m sine is DC across one view.
const float VEG_GUST_LEN = 260.0;        // metres between crests
const float VEG_GUST_WIDTH = 170.0;      // lateral cell: a straight front pulses like a metronome
const float VEG_GUST_WRAP_M = 26000.0;   // 100 * VEG_GUST_LEN

// Unit wind direction, safe against the all-zero project default.
vec2 wf_wind_unit() {
	return normalize(wuifwoud_wind_dir + vec2(1e-4, 0.0));
}

// One sway phase per TREE, from its world origin, so a stand does not breathe in
// unison. Metres-scale coefficients: ~107 m between neighbouring trees being in
// antiphase, so adjacent trunks lean TOGETHER and the offset only stops the forest
// being a metronome.
float wf_tree_phase(vec2 p) {
	return dot(p, vec2(0.046, 0.036));
}

// The travelling gust envelope at world XZ `p`: 1.0 in a gust, 1-depth in a lull.
// Evaluated PER TREE from the instance origin so a tree gusts as one object and the
// wave is a property of the stand. The front sweeps DOWNWIND; the lateral sine
// breaks it into cells.
float wf_gust_env(vec2 p) {
	vec2 dir = wf_wind_unit();
	vec2 side = vec2(-dir.y, dir.x);
	float front = (wuifwoud_gust_phase - dot(p, dir)) / VEG_GUST_LEN
	            + sin(dot(p, side) / VEG_GUST_WIDTH) * 0.18;
	// Two octaves: a pure sine gusts like a metronome, real air is patchy. Both are
	// periodic in 100 gust lengths: see VEG_GUST_WRAP_M.
	float env = sin(front * 6.2831853) * 0.62 + sin(front * 6.2831853 * 0.37 + 1.7) * 0.38;
	return mix(1.0 - wuifwoud_gust_depth, 1.0, clamp(env * 0.5 + 0.5, 0.0, 1.0));
}

// ── CAMERA DISTANCE ─────────────────────────────────────────────────────────────
// ALWAYS THE MAIN CAMERA. `CAMERA_POSITION_WORLD` is `INV_VIEW_MATRIX[3]` of the pass
// being rendered: in a sun-shadow pass that is the light's position, kilometres out
// along the sun, so a distance taken from it puts every tree past its hand-over in
// the shadow maps and the forest casts no shadow (it looks like cheap shadows). Every
// per-instance distance decision (LOD band, hand-over, thinning) has to agree between
// the colour pass and the shadow passes, and only the main camera's position does.
vec3 wf_cam_pos(mat4 main_cam_inv_view) {
	return main_cam_inv_view[3].xyz;
}

// ── CROSSFADES ──────────────────────────────────────────────────────────────────
// Every transition in the forest (LOD level to LOD level, last level to impostor
// card, card to nothing at the far edge) is a COMPLEMENTARY SCREEN-SPACE DITHER
// over a distance band: across the band the share of pixels the outgoing draw keeps
// falls as the share the incoming draw keeps rises, on the same pattern, so every
// pixel is covered exactly once and TAA/FSR2 resolve the pattern to a true crossfade.
// Outside the band the instance is collapsed in the vertex stage and costs nothing;
// the double draw is confined to the band.
//
// BOTH SIDES MUST USE THIS FUNCTION PAIR. The outgoing side keeps a fragment when
// `wf_dither(px) >= w`, the incoming side when `wf_dither(px) < w`, with the same
// `w = wf_band(a, b, d)`; a second pattern or a second curve on one side leaves
// pixels drawn twice or not at all. Interleaved gradient noise (Jimenez 2014): no
// visible tiling at 1:1, and it does not crawl with the camera the way an ordered
// Bayer pattern does against TAA jitter.
float wf_dither(vec2 px) {
	return fract(52.9829189 * fract(0.06711056 * px.x + 0.00583715 * px.y));
}

float wf_band(float a, float b, float d) {
	return smoothstep(a, b, d);
}

// ── HEMI-OCTAHEDRAL IMPOSTOR FRAMES ─────────────────────────────────────────────
// The EXACT INVERSE of ForestImpostorBaker's `hemi_oct_dir`. If these two ever
// disagree every impostor shows a neighbouring view, which reads as a forest of
// trees all facing slightly wrong: subtle enough to ship and impossible to place.
//
// A direction on the upper hemisphere -> uv in [0,1]^2. Corners are the four
// horizontal cardinals, the CENTRE is straight up, the border is the horizon ring.
// Straight down at a tree is therefore a real baked frame at full resolution, which
// is the whole reason for this parameterisation (see the baker's header).
vec2 wf_hemi_oct_uv(vec3 v) {
	vec3 o = v / (abs(v.x) + abs(v.y) + abs(v.z));
	return vec2(o.x + o.z, o.z - o.x) * 0.5 + 0.5;
}

// The direction frame `uv` was baked looking FROM: ForestImpostorBaker's
// `hemi_oct_dir`, the exact inverse of wf_hemi_oct_uv above.
vec3 wf_hemi_oct_dir(vec2 uv) {
	float px = uv.x - uv.y;
	float pz = -1.0 + uv.x + uv.y;
	return normalize(vec3(px, 1.0 - abs(px) - abs(pz), pz));
}

// That frame's CAMERA basis, columns (right, up, back), as the bake built it with
// `look_at(centre, up)`: Godot's Basis.looking_at puts +Z at `dir` (toward the camera),
// X = up x Z, Y = Z x X, with up = -Z for the straight-down frame where world +Y is the
// view axis. A view-space normal baked in that frame goes to the TREE's space through it.
mat3 wf_frame_basis(vec3 dir) {
	vec3 up = abs(dir.y) > 0.99 ? vec3(0.0, 0.0, -1.0) : vec3(0.0, 1.0, 0.0);
	vec3 x = normalize(cross(up, dir));
	return mat3(x, cross(dir, x), dir);
}

// sRGB byte value -> linear, the piecewise curve (the G-buffer albedo is sampled RAW
// because it is premultiplied in byte space, and decoded here after the divide).
vec3 wf_srgb_to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThanEqual(c, vec3(0.04045)));
}

// Barycentric weights over the three frames of the grid cell `f` falls in, plus which
// diagonal half of the cell we are in (w). Three taps, not one: a nearest-frame pick
// pops visibly as the camera turns, and this is the standard octahedral-impostor
// blend. Weights sum to 1 by construction.
vec4 wf_frame_weights(vec2 f) {
	vec4 w;
	w.x = min(1.0 - f.x, 1.0 - f.y);
	w.y = abs(f.x - f.y);
	w.z = min(f.x, f.y);
	w.w = ceil(f.x - f.y);          // 0 = lower triangle, 1 = upper
	float sum = w.x + w.y + w.z;
	w.xyz /= max(sum, 1e-5);
	return w;
}

// ── PER-TREE HAND-OVER ──────────────────────────────────────────────────────────
// A SHARED BAND MAKES THE DITHER THE SUBJECT. With one [a, b] for every tree, every
// trunk in the band is stippled at the same ratio at once, so what the player sees is
// not a forest changing LOD but a screen-door drawn over a hillside, and it sits
// there for the whole band (90 m is 3.6 s at 25 m/s). Worse, `_card_near_cut` clamps
// the hand-over to the streamed mesh frontier, so it can fire far nearer than
// `tree_visibility_m`, where a tree is big enough for the pattern to be unmistakable.
//
// Each tree gets its OWN narrow sub-band at a random offset inside the wide one
// instead. Only `frac` of the trees in the band are dithering at any moment, each for
// `frac` of the distance; the stand still converts gradually, because the offsets are
// spread across the full band. The pattern stops being a property of the view.
//
// BOTH SIDES MUST PASS THE SAME `p` AND `frac`. The mesh instance and the card
// instance for one tree are placed from a single scatter point
// (ForestSpawner._resolve_point returns the same `Vector3(p.x, h, p.y)` to the
// mesh tier and the card tier), so their XZ already agrees bit for bit. A hash is
// chaotic, though: any future epsilon between the two would drop the tree into two
// different sub-bands and it would draw twice, or not at all, for several metres. The
// 25 cm quantisation makes that agreement robust rather than incidental; two trees
// close enough to collide in it simply hand over together, which is invisible.
float wf_tree_hash(vec2 p) {
	vec2 q = floor(p * 4.0);
	return fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453);
}

// This tree's own sub-band inside [a, b]. `frac` = 1 restores one shared band for
// every tree, which is what a BUSH wants: a bush has no card to hand over to, it
// dissolves into nothing, and converting it in one step is a pop rather than a fade.
vec2 wf_tree_band(float a, float b, vec2 p, float frac) {
	float w = (b - a) * clamp(frac, 0.02, 1.0);
	return vec2(a, a + w) + (b - a - w) * wf_tree_hash(p);
}
