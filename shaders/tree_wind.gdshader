// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled, depth_prepass_alpha;
// Foliage wind for MultiMesh-instanced trees/bushes.
//
// Height-weighted canopy sway (trunk stays planted), per-instance phase from the
// instance world position so a forest ripples out of phase, plus tip flutter.
// Per-instance tint comes from INSTANCE_CUSTOM.
//
// TEXTURED. A shader with one flat `albedo` colour per surface and no texture draws a
// crown as a green SOLID: no leaf silhouette, no light through the canopy, at any
// distance; a forest-floor camera then sits at 66.7 % of pixels below 32/255 at FULL
// sky ambient, because a closed canopy of opaque quads transmits no light at any
// ambient level or sun elevation.
//
// ALPHA SCISSOR, NOT BLEND. These are dense crowns; alpha blending would cost a
// sort per instance and still order wrongly against itself. `depth_prepass_alpha`
// keeps the scissored crowns writing depth so they shadow and occlude correctly.
// `alpha_cut` is per-material: stylised atlases are clean binary masks (61 % of
// texels at exactly 255, 37 % at exactly 0) and their packs' own materials set 0.5,
// so 0.5 is corroborated rather than guessed.
//
// OPAQUE PIPELINE, ALL THE WAY OUT. A node visibility-range fade (FADE_SELF) moves
// every instance inside the fade band into the TRANSPARENT pass regardless of
// material, and since this shader writes ALPHA, the fade value would be overwritten
// and nothing would even fade. The hand-over to the impostor card is done HERE, per
// tree: past `lod_out1` the instance collapses in the vertex stage and costs nothing,
// and across [lod_out0, lod_out1] a complementary screen dither crossfades it with the
// card (wf_common `wf_dither`), which TAA/FSR2 resolve to a true fade. Mesh LOD inside
// that band is the engine's, per MultiMesh, over render buckets small enough for its
// AABB rule to be about the tree rather than about the chunk.

// The wind clock, gust envelope, per-tree phase, main-camera distance and crossfade
// dither: shared with tree_billboard.gdshader, which draws the same trees past the
// hand-over.
#include "res://addons/wuifwoud/shaders/wf_common.gdshaderinc"
// Rotor downwash as wind: the forest's copy of an outwash field a ground cover may read too.
#include "res://addons/wuifwoud/shaders/forest_wash.gdshaderinc"

group_uniforms surface;
// REPEAT ENABLED, and it has to be for any pack whose bark TILES. Measured UV
// ranges: a detailed fir pack's bark runs u 0..2 and v -5..2, its leaves 0..1, and
// every stylised surface sits inside a 0..1 atlas region (u 0.04..0.11 on a pine
// trunk). With `repeat_disable` everything outside 0..1 clamps to the edge texel,
// which smears tiled trunks into horizontal bands.
//
// Safe for the atlas packs precisely BECAUSE their UVs never leave 0..1 (the two
// modes only differ outside that range), and the atlas regions are interior, so no
// bilinear tap at a region edge can wrap to the far side of the sheet.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
// Multiplies the texture. Left at white by the spawner; a species that wants a
// seasonal or per-band shift can tint here without a second atlas.
uniform vec3 albedo : source_color = vec3(1.0, 1.0, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;
// Backlight: a real canopy glows where the sun is behind it. Cheap constant term
// rather than transmission, but it is the difference between a leaf and a chip of
// painted card.
uniform vec3 backlight_col : source_color = vec3(0.10, 0.14, 0.05);

// PBR SET, OPTIONAL, WITH EXPLICIT `has_` FLAGS, and the flags are not optional.
//
// An unbound sampler2D reads as opaque WHITE in Godot. A white normal map unpacks
// to (1,1,1)*2-1 = (1,1,1), which is not a unit normal and lights every tree
// wrongly; a white MT_AO_G reads as metallic 1, AO 1, smoothness 1, i.e. a mirror.
// So "is it bound" cannot be inferred from the sample: it has to be told.
//
// Atlas packs bind only `albedo_tex` and both flags stay false; detailed packs bind
// all three. One shader, both.
group_uniforms pbr;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform float normal_depth : hint_range(0.0, 4.0) = 1.0;
// R metallic, G ambient occlusion, A smoothness: the packing such packs' own
// materials name (`_MetalicRAOGSmothnessA`). Godot wants ROUGHNESS, so the
// smoothness is inverted on read rather than the texture being repacked: a repack
// is a second copy that can silently disagree with the pack after an update.
uniform sampler2D mtao_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_mtao = false;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;

group_uniforms crown;
// CROWN SHAPE, measured per species by the spawner rather than authored here.
//
// SPHERIFY blends the vertex normal toward the direction out of the crown centre,
// which is the standard foliage trick: a cluster of leaf cards then shades like one
// soft volume instead of a stack of flat planes. It is applied SELECTIVELY because
// packs are not consistent; measured mean(N.radial) on the foliage surface:
//
//   stylised oak +0.94   birch +0.91   bush +0.94   <- already spherified
//   stylised pine +0.01  palm  +0.04   tree +0.25   <- flat card normals
//
// So the broadleaves need none of it and the conifers need all of it, and a fixed
// amount would either do nothing or wreck the trees that were authored correctly.
// The spawner sets this to (1 - measured), so each species gets exactly the deficit.
uniform vec3 crown_centre = vec3(0.0, 1.0, 0.0);
uniform float crown_radius = 1.0;
uniform float spherify : hint_range(0.0, 1.0) = 0.0;
// Inner canopy sits behind the leaves outside it. Without this a crown is one flat
// block of albedo at every depth, which is most of what reads as "bland" next to a
// terrain carrying strata, contact fringe and per-texel AO.
uniform float crown_ao : hint_range(0.0, 1.0) = 0.45;
// Value break-up across the crown in WORLD space, so neighbouring leaves differ and
// a whole tree is not one colour. Analytic rather than a texture: this runs on every
// foliage fragment of ~150 000 instances and a sampler fetch is not worth it here.
uniform float crown_variation : hint_range(0.0, 1.0) = 0.22;

group_uniforms wind;
// Direction, strength, clock and gust envelope are the GLOBALS in wf_common: one
// wind for every species and for the impostor field behind them. What stays per
// material is the tree's own mechanics below.
// Below this local height nothing sways (trunk); full sway is reached
// `sway_span` metres above it.
uniform float sway_base = 1.4;
uniform float sway_span = 6.0;
uniform float flutter_amp = 0.12;
// How the bend grows with distance from the pivot: 1 linear, >1 saturates toward
// the tips, <1 concentrates it there. Detailed fir packs author 1.0, which is the
// default here too.
uniform float stiffness : hint_range(0.05, 4.0) = 1.0;
// 0 = leaves tremble along their own normal, 1 = along the wind. NM authors 0.5.
uniform float shiver_directionality : hint_range(0.0, 1.0) = 0.5;
// 1 on a canopy surface, 0 on bark. Bark bends with the tree; it does not flutter.
uniform float foliage_mask = 1.0;

// GUST WAVES. Wind does not arrive everywhere at once: it comes in fronts that
// travel downwind, and a forest shows you that better than anything else in a
// landscape: the ripple crossing a hillside is the most legible wind cue a game
// has. Without this every tree oscillates on a fixed phase from its own position,
// so the canopy shimmers uniformly and reads as noise rather than weather. The
// envelope (`wf_gust_env`), its geometry and its clock live in wf_common, because
// the impostor field behind the mesh band must carry the SAME front.

// VEHICLES PUSH VEGETATION ASIDE. Four world-space points, xy = world XZ, z =
// radius in metres, w = strength; radius 0 is an inactive slot. Fed from the
// nearest vehicles by ForestSpawner.
//
// Applied PER INSTANCE, like the gust, so a plant leans as one object rather than
// deforming around the bumper: this is a lean, not a collision response.
//
// SCALED DOWN BY PLANT SIZE, because a car does not bend a 20 m fir. The size comes
// from `crown_radius`, which the spawner already measures off the mesh: a 1 m bush
// scores ~1.0 and a mature conifer ~0.15, so the effect lands on the undergrowth a
// car actually drives through and leaves the canopy alone.
uniform vec4 wind_push[4];
uniform float push_size_ref : hint_range(0.1, 20.0) = 1.5;

// ROTOR WASH (forest_wash.gdshaderinc): a gale out from under the disc. A LEAN like
// the push (metres of tip travel, the same rotation) but pumped by a per-plant
// THRASH and whipped sideways by the buffeting, with the leaves shivering fast on
// top. And NOT confined to the undergrowth the way the car push is: a hovering
// helicopter moves a 20 m fir's crown, so big plants keep a floor of the lean.
const float WASH_TREE_TRAVEL = 2.2;   // m of tip travel at full wash (the game's rotor wash strength)
const float WASH_BIG_TREE = 0.3;      // size-scale floor: a mature crown still takes 30 %
const float WASH_THRASH_W = 11.0;     // rad/s, ~1.75 Hz: the whole plant pumping in the gusts
const float WASH_SHIVER_W = 56.0;     // rad/s, ~9 Hz: leaves buffeting
const float WASH_SHIVER_M = 0.07;     // m of leaf travel at full wash
const float WASH_BRANCH_W = 19.0;     // rad/s, ~3 Hz: limbs whipping across the flow

// THREE MOTIONS AT THREE SCALES.
//
// One lateral offset with `sin(t * 5.0 + inst.x + VERTEX.y)` in the phase is not
// enough: driving phase from RAW VERTEX.y at 5 Hz puts two vertices a centimetre apart
// near-opposite in phase, so the canopy shimmers per-vertex instead of moving as a
// thing, which reads as HEAT HAZE, not wind; and a pure XZ shear slides the whole tree
// sideways in proportion to height, with no pivot, so it never looks hinged at the
// ground.
//
// A tree moves at three scales and they are not the same signal:
//   BEND    the whole stem leaning on the gust, slow, one phase per TREE
//   BRANCH  limbs answering the bend a beat later, phase varying over METRES
//   FLUTTER leaf cards trembling, fast and small, still spatially smooth
//
// Every spatial phase term is a low-frequency function of WORLD XZ (metres), so
// neighbouring vertices stay in step and the variation happens across a canopy rather
// than across a triangle.
//
// BEND ALSO DROPS THE TIP. A stem that leans keeps its length, so the top descends
// by roughly d^2/2L for lateral travel d about a pivot L below. Without it the crown
// stretches upward as it leans and the tree reads as rubber.

// PER-INSTANCE TINT RIDES INSTANCE_CUSTOM, NOT COLOR, and that is what keeps the
// mesh LOD chain alive. COLOR carries the MultiMesh instance tint AND the mesh's own
// vertex-colour array multiplied together, and some packs ship arrays that are
// not colours (rgb ~0). Reading COLOR therefore forces a choice
// between a black forest and stripping the array, and stripping means rebuilding
// the surface, which drops the importer's auto-LOD chain AND its shadow mesh. Moving
// the tint to a channel the mesh cannot pollute means the mesh is never rebuilt:
// every species keeps 2-4 authored LODs, its generated LODs and its shadow mesh.
// Alpha is a validity flag so a non-MultiMesh use does not tint to black.
group_uniforms lod;
// DISTANCE CULLING OF THE CROWN'S CARDS, IN THE VERTEX STAGE. What a forest costs
// the GPU is the RASTERISED AREA of its overlapping leaf cards, not their shading:
// a dither discard at the very top of fragment() saved 3 %, while fewer cards (the
// LOD chain) saved 64 %. So a card that is not wanted must never reach the
// rasteriser. Each card carries a per-card random in COLOR.r, stamped at load
// (ForestAssets.stamp_card_ids: one value per connected component, shared by
// all its vertices, so a whole card collapses together and no triangle is torn).
// Past `thin_start_m` the share of cards kept falls to `1 - thin_max` at
// `thin_end_m` (the impostor hand-over). Inside thin_start_m nothing changes. Bark
// is never culled, and an unstamped surface (`cards_stamped` false) is never
// culled either: its COLOR reads (1,1,1,1) and would lose every card.
uniform float thin_start_m = 80.0;
uniform float thin_end_m = 350.0;
uniform float thin_max : hint_range(0.0, 1.0) = 0.0;
uniform bool cards_stamped = false;
// THE HAND-OVER BAND, in metres from the main camera: the mesh dithers out over
// [lod_out0, lod_out1] and is gone past it, while the impostor card dithers in on the
// complement of the same pattern (its `near_cut`/`near_fade` are pushed to the SAME
// two numbers). Past the band the instance is collapsed in the vertex stage and costs
// no fragments. A species with no card (bushes) fades into nothing over a short band
// of its own. Pushed by ForestSpawner.push_lod_params from
// ForestAssets.handover_band.
uniform float lod_out0 = 260.0;
uniform float lod_out1 = 350.0;
// HOW MUCH OF THAT BAND ONE TREE USES. The band above belongs to the STAND; each tree
// crossfades over `handover_frac` of it at a per-tree random offset inside it
// (wf_common `wf_tree_band`), so only that share of the trees is dithering at any
// one moment instead of every trunk in 90 m at once. The card is pushed the same
// number and derives the same sub-band from the same instance origin, which is what
// keeps the two complementary. 1.0 restores one shared band for every tree, which is
// what a BUSH is pushed, because a bush has no card to hand over to and converting it
// in one step is a pop rather than a dissolve.
uniform float handover_frac : hint_range(0.02, 1.0) = 1.0;

varying vec4 inst_tint;
varying flat vec2 band_out;  // this tree's own [out0, out1], from wf_tree_band
varying float crown_depth;   // 0 at the crown centre, 1 at its outer surface
varying vec3 shade_pos;      // world XZ/Y for the value break-up
varying float inst_d;        // instance distance to the MAIN camera, for the crossfades

void vertex() {
	inst_tint = INSTANCE_CUSTOM;
	vec3 inst = MODEL_MATRIX[3].xyz;                 // per-instance world origin
	// The MAIN camera, in every pass: see wf_common `wf_cam_pos`.
	float cam_d = distance(inst, wf_cam_pos(MAIN_CAM_INV_VIEW_MATRIX));
	inst_d = cam_d;
	// THIS TREE'S sub-band, keyed on its own origin. The card computes the identical
	// pair from the identical origin, so the pattern below is still the exact
	// complement of the card's, per tree rather than per hillside.
	band_out = wf_tree_band(lod_out0, lod_out1, inst.xz, handover_frac);
	// BAND FIRST, and everything below sits behind it: a tree the card has taken over
	// does no wind math at all. The branch is on a per-instance value, so every vertex
	// of one tree takes the same side and the GPU does not diverge.
	bool culled = cam_d >= band_out.y;
	// Per INSTANCE, not per vertex: one tree's kept share is one number, so every
	// vertex of a card sees the same threshold and the card collapses whole.
	float thin_keep = 1.0 - thin_max * smoothstep(thin_start_m, thin_end_m, cam_d);
	culled = culled || (cards_stamped && foliage_mask > 0.5 && COLOR.r > thin_keep);
	if (culled) {
		// Every vertex on the instance origin: no area, nothing rasterised.
		VERTEX = vec3(0.0);
	} else {
	// BEFORE the wind displaces anything: crown depth is a property of the tree's
	// shape, and measuring it after the sway would make the shading breathe.
	vec3 from_c = VERTEX - crown_centre;
	float crown_r = length(from_c);
	crown_depth = clamp(crown_r / max(crown_radius, 0.001), 0.0, 1.0);
	if (foliage_mask > 0.5 && spherify > 0.001 && crown_r > 0.001) {
		NORMAL = normalize(mix(NORMAL, from_c / crown_r, spherify));
	}
	// ONE world-space transform of the vertex, used for the shading break-up AND
	// the spatial wind phases (it was computed twice).
	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	shade_pos = wpos;

	float h = max(VERTEX.y - sway_base, 0.0);
	float w = clamp(h / sway_span, 0.0, 1.0);
	w *= w;                                           // tips move most

	vec2 dir = wf_wind_unit();
	vec2 side = vec2(-dir.y, dir.x);
	// THE CLOCK IS A STATE, NOT `TIME * rate`: see wf_common.gdshaderinc.
	float t = wuifwoud_wind_phase;
	float tree = wf_tree_phase(inst.xz);
	float env = wf_gust_env(inst.xz);

	// Spatial phases in WORLD XZ at ~1 cycle per few metres. This is the line that
	// stops the shimmer: across one leaf card the phase barely moves.
	// Branch ~19 m, leaf ~11 m. The leaf figure is NM's authored ShiverNoiseWorldSize
	// (10 m) almost exactly; the branch scale sits between it and the tree field.
	float sp_branch = dot(wpos.xz, vec2(0.26, 0.20));
	float sp_leaf = dot(wpos.xz, vec2(0.50, 0.40));

	// BEND: the stem leaning on the gust. Two octaves so gusts arrive unevenly.
	float bend = sin(t * 0.75 + tree) * 0.68 + sin(t * 1.37 + tree * 1.7) * 0.32;

	// BRANCH: limbs answering a beat behind, along and across the wind.
	float br_a = sin(t * 1.9 + sp_branch + tree);
	float br_b = sin(t * 2.3 + sp_branch * 1.3 + tree * 0.7);

	// FLUTTER: leaf cards only, small and fast but spatially smooth.
	//
	// SCALED BY WIND STRENGTH. The gust envelope deliberately does NOT gate it (a canopy
	// keeps trembling through a lull, which is the note below), but it must not be
	// independent of the wind SPEED as well: a dead calm would tremble as hard as a gale,
	// and `wind_strength = 0` would leave every leaf moving on TIME, which also makes a
	// shot rig useless as an instrument (two runs of identical code differing by up to
	// 48 % of pixels, scaling with how much foliage is in frame).
	float calm = clamp(wuifwoud_wind_strength / 0.15, 0.0, 1.0);
	float flut = sin(t * 4.6 + sp_leaf + tree * 2.1) * foliage_mask * calm;

	// The envelope scales the BEND and BRANCH terms; flutter is leaf-scale and
	// keeps going through a lull, which is what a canopy actually does.
	float amp = wuifwoud_wind_strength * w * env;

	// VEHICLE PUSH, per instance and away from each point.
	vec2 push = vec2(0.0);
	float push_scale = clamp(push_size_ref / max(crown_radius, 0.1), 0.0, 1.0);
	for (int i = 0; i < 4; i++) {
		if (wind_push[i].z <= 0.0) {
			continue;
		}
		vec2 delta = inst.xz - wind_push[i].xy;
		float pd = length(delta);
		if (pd > wind_push[i].z || pd < 1e-4) {
			continue;
		}
		// Smooth falloff to the rim so a plant does not snap upright as the car
		// leaves the radius.
		float k = 1.0 - pd / wind_push[i].z;
		push += (delta / pd) * (k * k * wind_push[i].w * push_scale);
	}

	// ROTOR WASH, per instance: pressed out under the disc, the jet and its
	// outward crests beyond, pumped by this plant's thrash, whipped by the buffet.
	vec2 w_press;
	vec2 w_jet;
	vec2 w_across;
	float w_flutter;
	float tree_seed = fract(tree * 0.15915494);
	rotor_wash_at(inst.xz, tree_seed, w_press, w_jet, w_across, w_flutter);
	vec2 wash_push = w_press * 0.6 + w_jet;
	float wash_mag = length(wash_push);
	float wash_scale = clamp(push_size_ref / max(crown_radius, 0.1), WASH_BIG_TREE, 1.0);
	float thrash = sin(TIME * (WASH_THRASH_W + tree_seed * 3.0) + tree * 2.3);
	wash_push = (wash_push * (1.0 + 0.35 * thrash) + w_across * (0.3 * w_flutter))
			* (WASH_TREE_TRAVEL * wash_scale);

	// BEND IS A ROTATION ABOUT THE ROOT, not a lateral slide with a correction.
	//
	// Offsetting VERTEX.xz and then subtracting d^2/2L to stop the crown stretching
	// upward only approximates the arc a rotation traces exactly. Rotating preserves the
	// stem's length by construction, with no correction term and no hand-picked pivot
	// distance, and a bush at the edge of a gust does not sink into the ground when
	// `sway_span` happens to be small.
	//
	// The angle grows with distance from the pivot, which is how a cantilever bends
	// (and how foliage shaders of tree packs do it).
	// `stiffness` shapes that growth: 1 is linear in distance, >1 saturates toward
	// the tips (a stiff trunk), <1 concentrates the bend at the top (a whippy one).
	vec3 pivot = vec3(0.0, sway_base, 0.0);
	vec3 rel = VERTEX - pivot;
	float rlen = length(rel);
	// SHAPE IS BOUNDED 0..1. A raw `pow(r/s, 1/s)` at stiffness 1 is just the distance
	// from the pivot and grows without limit: twenty metres up a fir that is a factor of
	// 20, on top of an `amp` that ALREADY carries the height weight, so height would be
	// counted twice and a mild push would rotate the crown through ~70 degrees with the
	// bark stretched along it (hidden at shipping strength on everything but the tallest
	// trees, which is worse).
	float shape = pow(clamp(rlen / max(sway_span, 1.0), 0.0, 1.0),
		1.0 / max(stiffness, 0.05));
	// ONE rotation for wind AND push. They are both a lean; giving the push its own
	// axis would let a plant bend two ways at once and stretch.
	vec2 lean = dir * (bend * amp + br_a * amp * 0.20) + push + wash_push;
	// The angle that moves a point at `rlen` by `lean` metres is lean/rlen, so the
	// uniform keeps meaning METRES OF TIP TRAVEL and `shape` decides how much of it
	// this vertex gets. Displacement is bounded by `lean` however tall the tree is.
	float lean_len = length(lean);
	float ang = lean_len / max(rlen, 0.15) * shape;
	vec3 wdir3 = vec3(dir.x, 0.0, dir.y);
	vec3 lean3 = vec3(lean.x, 0.0, lean.y);
	vec3 axis = cross(vec3(0.0, 1.0, 0.0), lean3);
	if (length(axis) > 1e-4 && ang != 0.0 && shape > 0.0) {
		axis = normalize(axis);
		float ca = cos(ang);
		float sa = sin(ang);
		// Rodrigues.
		vec3 rot = rel * ca + cross(axis, rel) * sa + axis * dot(axis, rel) * (1.0 - ca);
		VERTEX = pivot + rot;
	}
	// Cross-wind branch swing stays a small lateral offset: it is a limb moving, not
	// the stem leaning, and giving it its own rotation axis buys nothing visible.
	VERTEX.xz += side * (br_b * amp * 0.12);

	// FLUTTER ALONG THE LEAF NORMAL, blended toward the wind, not straight up.
	// A leaf card trembles about its own plane; displacing every card on world +Y
	// makes a canopy pulse vertically like a jellyfish. `shiver_directionality`
	// mixes toward the wind so a gale still combs the needles downwind.
	// SHIVER MASK COMES FROM THE MESH: COLOR.a is the vertex alpha the packs author
	// for exactly this (detailed fir packs ramp 0..1 over the needles and sit at 0 on the
	// bark). A mesh with no colour array reads 1 and flutters whole.
	vec3 shiver_dir = normalize(mix(NORMAL, normalize(wdir3 + vec3(0.0, 0.35, 0.0)),
		shiver_directionality));
	VERTEX += shiver_dir * (flut * flutter_amp * w * COLOR.a);
	// The wash's buffeting: leaves shivering fast and hard, combed away from the
	// rotor, and limbs whipping across the flow.
	if (wash_mag > 0.001) {
		vec2 wd = wash_push / max(length(wash_push), 1e-4);
		vec3 wash_dir3 = normalize(vec3(wd.x, 0.25, wd.y));
		float shiver = sin(TIME * WASH_SHIVER_W + sp_leaf * 3.0 + tree * 1.3);
		VERTEX += wash_dir3 * (shiver * wash_mag * WASH_SHIVER_M * w * COLOR.a * foliage_mask);
		VERTEX.xz += w_across * (sin(TIME * WASH_BRANCH_W + sp_branch * 2.0 + tree) * 0.25 * w);
	}
	}   // !culled
}

void fragment() {
	// CROSSFADE EDGE. Inside the hand-over band, keep or drop this pixel by the shared
	// dither against the band curve; the card keeps exactly the complement. Tested
	// BEFORE the texture fetch (a dropped pixel costs nothing further) and before
	// the alpha scissor, which applies to what survives.
	if (inst_d > band_out.x
			&& wf_dither(FRAGCOORD.xy) < wf_band(band_out.x, band_out.y, inst_d)) {
		discard;
	}
	vec4 tex = texture(albedo_tex, UV);
	// Per-instance tint (brightness/hue jitter set on the MultiMesh) breaks the
	// clone-army look. a < 0.5 means nobody wrote custom data: draw untinted
	// rather than black.
	vec3 tint = inst_tint.a < 0.5 ? vec3(1.0) : inst_tint.rgb;

	// Depth into the crown drives BOTH the occlusion and the break-up, so they
	// cannot drift apart: dark and busy inside, bright and clean at the tips.
	// The geometric crown term BACKS OFF where a real AO map exists. They answer
	// different questions (a needle behind its neighbour vs a branch inside the
	// canopy) but they overlap, and at full strength together the crowns go black.
	float crown_k = has_mtao ? crown_ao * 0.35 : crown_ao;
	float ao = mix(1.0 - crown_k, 1.0, crown_depth);
	// Three octaves of smooth analytic noise. Metre-scale, so it varies across a
	// canopy rather than across a leaf card: the same rule the wind phases follow,
	// and for the same reason: per-vertex-scale variation reads as noise, not shape.
	float nz = sin(shade_pos.x * 0.61 + shade_pos.z * 0.43) * 0.50
	         + sin(shade_pos.y * 0.97 - shade_pos.x * 0.29) * 0.32
	         + sin((shade_pos.x + shade_pos.z) * 1.73 + shade_pos.y * 0.7) * 0.18;
	float breakup = 1.0 + nz * crown_variation;
	// Bark takes neither: a trunk is not a canopy and has its own texture already.
	float shade = mix(1.0, ao * breakup, foliage_mask);

	ALBEDO = tex.rgb * albedo * tint * shade;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	ROUGHNESS = roughness;
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = normal_depth;
	}
	// A BACK FACE KEEPS THE AUTHORED NORMAL. `cull_disabled` defines DO_SIDE_CHECK, so
	// Godot has ALREADY negated NORMAL for a back face before this code runs, and negating
	// it again restores the vertex normal as authored (spherified, above). That is the
	// right normal here, for every species this shader draws: a foliage normal is either
	// an authored smooth field (radial on stylised broadleaves, up-biased on detailed
	// firs) or a radial one spherify has built, a property of the CROWN, not of which side
	// of a card the camera is on. Godot's flip would point it into the crown on every card
	// seen from behind, half of them. impostor_bake.gdshader repeats this so the
	// impostor bakes the normal the mesh is lit with.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
		if (has_normal) {
			NORMAL_MAP_DEPTH = -normal_depth;
		}
	}
	if (has_mtao) {
		vec4 mt = texture(mtao_tex, UV);
		METALLIC = mt.r;
		// PER-TEXEL AO ON TOP OF the geometric crown term, not instead of it. They
		// answer different questions: the texture knows a needle sits behind its
		// neighbour, the crown term knows this whole branch sits inside the canopy.
		AO = mix(1.0, mt.g, ao_strength);
		// AO_LIGHT_AFFECT LEFT AT ITS DEFAULT (0): occlusion darkens AMBIENT only.
		// Setting it to 1 also darkens direct sunlight, which stacked with the
		// geometric crown term and renders sunlit crowns almost black. Tree packs' own
		// materials apply occlusion to indirect light, so 1 would not match the pack; it
		// would double-count.
		ROUGHNESS = 1.0 - mt.a;
	}
	// Thin outer leaves transmit; the packed interior does not.
	BACKLIGHT = backlight_col * mix(0.35, 1.35, crown_depth) * foliage_mask;
}
