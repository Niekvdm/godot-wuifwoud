// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
shader_type spatial;
// The far forest: the canopy shell past the impostor cards. Its mesh (built by the native core) carries
// the canopy's height and relief, the skirt and the rules by place; this draws the cover (each crown kept by its own
// draw under the far summary's cover; the shared dither far away), the crowns' colours (the type's palette for the band,
// from the cards' own bakes), a dome per crown, and the handover under the last cards.
//
// MATCHING THE CARDS (prompts/222: "matches with the forest instead of an ugly shell"). The cards read as single trees:
// a ragged treetop skyline, crowns lit on the sun side and dark between, colour by tree. The shell read as a matte
// blanket: its crowns collapsed to one mean colour once under two pixels, its skyline was the mesh's, its elevation
// bands switched on a line. So:
//   - CLUMPS: a second crown lattice at CLUMP_K x the spacing carries a crown's colour pick and dome where single crowns
//     are too small to see; their own shading falls back to the type's mean, darkened by the gaps, only past that.
//   - THE SKYLINE: where the shell is seen edge-on (the view grazes it), the gaps between crowns (or clumps) are cut
//     away, so a ridge against the sky or a slope behind shows treetops, not the mesh's line.
//   - THE BANDS: a crown's band is picked at its own height plus a per-clump offset over band_blend_m: no ring.
//   - THE WALLS: an edge's wall darkens toward the ground and its top is ragged by crown, not a hedge.
//
// ALPHA IS NEVER WRITTEN (the cards' rule): the cut is `discard`, so the shell stays on the opaque pipeline.
// THE HANDOVER is the incoming half of wf_common's complementary dither pair, on the cards' own distance (3D, from the
// main camera), so a plane high above sees no hole between the last cards and the shell.
// cull_disabled: from inside a flat forest the far canopy is seen from below.
render_mode cull_disabled, specular_disabled;

#include "res://addons/wuifwoud/shaders/wf_common.gdshaderinc"

uniform sampler2D summary : filter_linear_mipmap, repeat_disable;   // R type, G cover, B age: this cell's
uniform sampler2D palette : filter_nearest, repeat_disable;         // forest_far_palette.gd texture_image()
uniform vec2 cell_origin = vec2(0.0);
uniform float cell_size = 4096.0;
uniform int cell_texels = 512;
uniform float far_cut = 2600.0;     // where the cards end (billboard_far_m)
uniform float fade_m = 600.0;       // the handover under them
uniform float coast_m = 150.0;
uniform float mid_m = 450.0;
uniform vec3 backlight_col : source_color = vec3(0.10, 0.14, 0.05);
// The match to the cards (defaults measured against them, docs in the header).
uniform float clump_k = 3.0;            // a clump's spacing in tree spacings
uniform float crown_shade = 0.45;       // a crown's rim darkened to this share of its colour (the gap between crowns)
uniform float dome = 1.2;               // the crown's dome in the normal
uniform float clump_dome = 0.8;         // a clump's, where crowns are too small
uniform float far_shade = 0.78;         // the mean's share past the clumps (the gaps' shadow, averaged)
uniform float band_blend_m = 70.0;      // the elevation bands blended over this
uniform float skyline_cut = 0.55;       // edge-on, the rim past which a crown's edge is cut (1: none)
uniform float graze_lo = 0.80;          // where cutting starts: 1 - |n.v| (the view's grazing)
uniform float graze_hi = 0.97;
uniform float wall_floor = 0.35;        // a wall's foot, as a share of its colour
uniform float wall_rag = 0.45;          // a wall's top: this share of its height ragged by crown
// THE CROWN LAYER (where a crown spans a few pixels): each pixel's view ray is traced into a layer of crowns hanging
// from the shell (the shell is the tallest tips' plane): jittered crowns, cones to domes (crown_point), heights varied;
// a ray that meets one is shaded by that crown (its slope, its colour, darker lower down), one that reaches the layer's
// floor between them sees the understorey (or the ground, where the cover is open), one that skims the top meets
// nothing and is cut: a treetop skyline on every ridge.
uniform float crown_depth_k = 2.2;      // the layer's depth in tree spacings (the crowns' visible height)
uniform float crown_r = 0.62;           // a crown's radius in tree spacings
uniform float crown_point = 0.55;       // 0 a dome (broadleaf) .. 1 a cone (conifer)
uniform float crown_slope = 0.45;       // the crown's flank in the normal
uniform float crown_ao = 0.65;          // a crown's lowest visible part, as a share of its colour (with understorey:
uniform float understorey = 0.32;       // the shell's mean kept at the palette's, the floor between crowns's share)
uniform float pom_gain = 1.05;          // the layer's shading (its slopes, its floor) keeps the palette's mean: measured
                                        // 3-5% under the flat shell's without it, against the cards' look the owner set
uniform int pom_steps = 18;
uniform float pom_reach = 9.0;          // the furthest a ray is followed, in tree spacings
// Diagnostics (tools; 0 in play), flat emitted colours no natural pixel has: 1 the canopy magenta and the walls red, cut
// as drawn; 2 the same with no cut at all (the whole mesh: where the shell stands, whatever its cover and the handover).
uniform int debug_mode = 0;
// THE COST SWITCHES (ForestSpawner far_near_collapse / far_layer_prune), each the same picture for less work.
// NEAR COLLAPSE: every pixel nearer than the handover's start is dropped (the first test in fragment()), yet a cell is
// 4 km across, so the shell around the camera was rasterised (the canopy over a forest road fills half the screen) only
// to be dropped pixel by pixel, in the depth prepass too. A vertex all of whose triangles lie nearer than that start is
// put on the camera instead: a triangle through the eye projects to a line and draws nothing. "All of its triangles" is
// bounded, not known: a triangle reaches at most `tri_reach_m` across the ground from any of its vertices, and between
// `y_span` (the cell's mesh, walls included) in height.
uniform bool near_collapse = true;
uniform vec2 y_span = vec2(-1.0e6, 1.0e6);
uniform float tri_reach_m = 64.0;
// LAYER PRUNE: the crown layer's search (far_layer) tests only the neighbour cells whose crowns can reach the point.
uniform bool layer_prune = true;
// STILL MODE (ForestSpawner, while no temporal filter runs). Three of the shell's choices are made per pixel on a
// dither so that a temporal filter averages them into a blend; with none, each is a still pattern, and at a ridge
// (the skyline) it reads as sky dotted through the canopy. In still mode they are coherent instead:
//   the hand-over under the last cards goes crown cell by crown cell, each at its own distance in the band (as the
//   trees switch per tree), not a screen door 600 m deep;
//   the crown layer's march takes the same step offset at every pixel (the middle of each step), so a ray skimming
//   the treetops hits or misses with its neighbours, not on a pattern;
//   the layer gives way to the clumps at a size (pom_w one half), not pixel by pixel across a band.
// The cover past the crowns (sub-pixel) keeps its dither: a choice anchored in the world there would crawl in motion.
uniform bool still_mode = false;

varying vec3 wpos;
varying float vdist;
varying vec3 vcam;          // the main camera (MAIN_CAM_INV_VIEW_MATRIX is the vertex stage's)
varying vec3 cust;          // x the rules by place, y skirt (0 canopy, 1 skirt), z the ground's height
varying flat float vtype;   // the type of the densest covered quad at the vertex

float far_h12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 far_h22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

// The nearest crown on a jittered lattice in `gp` (lattice units): its cell (xy) and the vector to it (zw).
vec4 far_crown(vec2 gp) {
	vec2 ip = floor(gp);
	vec2 fp = fract(gp);
	float best = 8.0;
	vec4 r = vec4(ip, 0.0, 0.0);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 o = vec2(float(i), float(j));
			vec2 rv = o + far_h22(ip + o) * 0.8 + 0.1 - fp;
			float d2 = dot(rv, rv);
			if (d2 < best) {
				best = d2;
				r = vec4(ip + o, rv);
			}
		}
	}
	return r;
}

// A colour from the band's palette row for the pick 0..1 (the cumulative weights in A); the mean when none.
vec3 far_pick(int row, float pick, vec3 mean_c) {
	for (int k = 0; k < 8; k++) {
		vec4 e = texelFetch(palette, ivec2(k, row), 0);
		if (e.a <= 0.0) {
			break;
		}
		if (pick <= e.a) {
			return e.rgb;
		}
	}
	return mean_c;
}

// The crown layer over world xz: the tallest kept crown's top there (metres above the layer's floor), its cell, and the
// position in it (the vector from its centre over its radius). A crown is kept by its own draw under `cover`.
float far_layer(vec2 p, float spacing, float depth, float cover, out vec2 cid, out vec2 rel) {
	vec2 ip = floor(p / spacing);
	float best = 0.0;
	cid = ip;
	rel = vec2(1.0);
	// WHICH NEIGHBOURS CAN REACH p (layer_prune). A crown's centre lies in [0.1, 0.9] of its cell and its radius is at
	// most crown_r * 1.2 cells, so the cell to the left reaches into this one only below that radius minus 0.1, the cell
	// to the right only above 1.1 minus it; a neighbour that cannot reach p would be skipped by the radius test below
	// anyway, so leaving it out is the same answer, in the same order. The same bound rejects a crown before its radius
	// is drawn.
	ivec2 lo = ivec2(-1);
	ivec2 hi = ivec2(1);
	float rr = crown_r * 1.2 + 1.0e-3;
	float rr_m2 = 1.0e30;
	if (layer_prune) {
		vec2 fp = p / spacing - ip;
		lo = ivec2(fp.x < rr - 0.1 ? -1 : 0, fp.y < rr - 0.1 ? -1 : 0);
		hi = ivec2(fp.x > 1.1 - rr ? 1 : 0, fp.y > 1.1 - rr ? 1 : 0);
		rr_m2 = rr * rr * spacing * spacing;
	}
	for (int j = lo.y; j <= hi.y; j++) {
		for (int i = lo.x; i <= hi.x; i++) {
			vec2 c = ip + vec2(float(i), float(j));
			if (far_h12(c) >= cover) {
				continue;
			}
			vec2 r = p - (c + far_h22(c) * 0.8 + 0.1) * spacing;
			if (dot(r, r) >= rr_m2) {
				continue;
			}
			float rad = spacing * crown_r * (0.8 + 0.4 * far_h12(c + 9.7));
			float x = length(r) / rad;
			if (x >= 1.0) {
				continue;
			}
			float h = depth * (0.72 + 0.28 * far_h12(c + 5.1)) * mix(sqrt(1.0 - x * x), 1.0 - x, crown_point);
			if (h > best) {
				best = h;
				cid = c;
				rel = r / rad;
			}
		}
	}
	return best;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vcam = wf_cam_pos(MAIN_CAM_INV_VIEW_MATRIX);
	vdist = distance(wpos, vcam);
	cust = CUSTOM0.xyz;
	vtype = CUSTOM0.w;
	// NEAR COLLAPSE (the uniform's note): every point of every triangle on this vertex lies within the ground reach and
	// the height span, so its distance is under sqrt(h^2 + dy^2); under the handover's start all of it is dropped.
	float near_lo = far_cut - fade_m;
	if (near_collapse && debug_mode != 2 && near_lo > 0.0) {
		float h = length(wpos.xz - vcam.xz) + tri_reach_m;
		float dy = max(abs(y_span.y - vcam.y), abs(vcam.y - y_span.x));
		if (h * h + dy * dy < near_lo * near_lo) {
			// onto THIS pass's eye (the one it projects through), in the mesh's own space
			VERTEX = (inverse(MODEL_MATRIX) * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;
			vdist = 0.0;
		}
	}
}

void fragment() {
	bool wall = cust.y > 0.001;
	if (debug_mode == 2) {
		ALBEDO = vec3(0.0);
		EMISSION = wall ? vec3(1.0, 0.0, 0.0) : vec3(1.0, 0.0, 1.0);
		ROUGHNESS = 1.0;
	} else {
		float hand_w = wf_band(far_cut - fade_m, far_cut, vdist);
		if (wf_dither(FRAGCOORD.xy) >= hand_w && !(still_mode && hand_w > 0.0)) {
			discard;
		}
		vec2 uv = (wpos.xz - cell_origin) / cell_size;
		ivec2 tc = clamp(ivec2(floor(uv * float(cell_texels))), ivec2(0), ivec2(cell_texels - 1));
		int ty = int(round(texelFetch(summary, tc, 0).r * 255.0));
		if (wall || ty == 0) {
			ty = int(round(vtype));
		}
		if (ty <= 0) {
			discard;
		}
		float cover = (wall ? 1.0 : texture(summary, uv).g) * clamp(cust.x, 0.0, 1.0);
		// the spacing is the band's; read at the middle band first, then the crown's own band below
		float spacing = max(texelFetch(palette, ivec2(8, ty * 3 + 1), 0).a, 1.0);
		vec2 gp = wpos.xz / spacing;
		// the crown cell's own place in the band (still_mode; the shared dither above otherwise)
		if (still_mode && far_h12(floor(gp) + 71.3) >= hand_w) {
			discard;
		}
		vec2 cp = gp / clump_k;
		vec4 clump = far_crown(cp);
		float far_w = smoothstep(0.25, 0.5, length(fwidth(gp)));   // 1 where a crown spans under about 2 pixels
		float clump_w = smoothstep(0.25, 0.5, length(fwidth(cp)));  // and a clump
		float crim = clamp(length(clump.zw) / 0.7, 0.0, 1.0);
		// the band by the crown's (or clump's) own jittered height: blended, not a ring
		float hj = cust.z + (far_h12(clump.xy + 7.3) - 0.5) * 2.0 * band_blend_m;
		int band = hj < coast_m ? 0 : (hj < mid_m ? 1 : 2);
		int row = ty * 3 + band;
		vec4 meanp = texelFetch(palette, ivec2(8, row), 0);
		vec3 vw = normalize(vcam - wpos);
		vec3 geo = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 albedo;
		vec3 nw = geo;
		float down = dot(-vw, -geo);   // how fast the view ray sinks into the layer, per metre
		// the crown layer where a crown spans more than about a pixel ACROSS the screen (dithered into the clumps past
		// that): the smaller derivative, as a grazing view foreshortens the other and the layer is what draws it right
		float pom_w = 1.0 - smoothstep(0.6, 1.1, min(length(dFdx(gp)), length(dFdy(gp))));
		bool pom = !wall && geo.y > 0.25 && down > 0.0
			&& (still_mode ? pom_w >= 0.5 : wf_dither(FRAGCOORD.xy + vec2(41.0, 7.0)) < pom_w);
		if (pom) {
			float dep_m = crown_depth_k * spacing;
			float reach = min(dep_m / max(down, 1e-4), pom_reach * spacing);
			float jit = still_mode ? 0.5 : wf_dither(FRAGCOORD.xy + vec2(5.0, 11.0));
			vec3 rd = -vw;
			bool hit = false;
			vec2 cid = vec2(0.0);
			vec2 rel = vec2(1.0);
			float hh = 0.0;
			float t = 0.0;
			for (int i = 0; i < pom_steps; i++) {
				t = reach * (float(i) + jit) / float(pom_steps);
				vec3 q = wpos + rd * t;
				hh = far_layer(q.xz, spacing, dep_m, cover, cid, rel);
				if (t * down >= dep_m - hh) {
					hit = true;
					break;
				}
			}
			if (!hit) {
				// skimmed over the tips (the skyline, a ridge's crest): nothing here; else the floor between crowns
				if (reach * down < dep_m * 0.98 || cover < 0.5) {
					discard;
				}
				albedo = meanp.rgb * understorey * pom_gain;
			} else {
				vec3 col = far_pick(row, far_h12(cid + 19.7), meanp.rgb);
				albedo = col * mix(crown_ao, 1.0, clamp(hh / dep_m, 0.0, 1.0)) * pom_gain;
				float x = length(rel);
				vec2 dir = rel / max(x, 1e-3);
				float g = mix(x / sqrt(max(1.0 - x * x, 0.05)), 1.0, crown_point) * crown_slope;
				nw = normalize(geo + vec3(dir.x, 0.0, dir.y) * g);
			}
		} else {
			// past the crown layer: the clumps (L1), edge-on the gaps between them cut away. The nearest single crown is
			// only wanted here (the layer has its own), so only looked for here.
			vec4 crown = far_crown(gp);
			float rim = clamp(length(crown.zw) / 0.7, 0.0, 1.0);
			float graze = smoothstep(graze_lo, graze_hi, 1.0 - abs(dot(geo, vw)));
			float edge_rim = mix(rim, crim, far_w);
			float own = mix(far_h12(crown.xy), wf_dither(FRAGCOORD.xy + vec2(17.0, 31.0)), far_w);
			if (!wall) {
				if (own >= cover) {
					discard;
				}
				if (graze > 0.0 && edge_rim > mix(1.01, skyline_cut, graze)) {
					discard;
				}
			}
			// colour: the crown's pick near, the clump's where crowns are too small, the gaps' mean past the clumps
			vec3 near_c = far_pick(row, far_h12(crown.xy + 19.7), meanp.rgb) * mix(1.0, crown_shade, rim * rim);
			vec3 clump_c = far_pick(row, far_h12(clump.xy + 19.7), meanp.rgb) * mix(1.0, mix(crown_shade, 1.0, 0.35), crim * crim);
			albedo = mix(near_c, clump_c, far_w);
			albedo = mix(albedo, meanp.rgb * far_shade, clump_w * far_w);
			if (wall) {
				// darker toward the ground; the top ragged by crown (the wall's height in the ground's terms)
				float up = clamp((wpos.y - cust.z) / max(spacing * 2.5, 6.0), 0.0, 1.0);
				if (up > 1.0 - wall_rag * (0.4 + 0.6 * far_h12(floor(wpos.xz / spacing) + 3.1))) {
					discard;
				}
				albedo = meanp.rgb * mix(wall_floor, 0.75, up);
			} else {
				vec2 d = mix(crown.zw * dome, clump.zw * clump_dome, far_w) * (1.0 - clump_w * far_w);
				nw = normalize(geo + vec3(-d.x, 0.0, -d.y));
			}
		}
		NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
		ALBEDO = debug_mode == 1 ? vec3(0.0) : albedo;
		if (debug_mode == 1) {
			EMISSION = wall ? vec3(1.0, 0.0, 0.0) : vec3(1.0, 0.0, 1.0);
		}
		ROUGHNESS = 0.95;
		BACKLIGHT = backlight_col * 0.9;
	}
}
