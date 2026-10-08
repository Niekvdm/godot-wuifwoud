// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
shader_type spatial;
// The far forest: the canopy shell past the impostor cards. Its mesh (built by the native core) carries
// the canopy's height and relief, the skirt and the rules by place; this draws the cover (each crown kept by its own
// draw under the far summary's cover; the shared dither far away), the crowns' colours (the type's palette for the band,
// from the cards' own bakes), a dome per crown, and the handover under the last cards.
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
// Diagnostics (tools; 0 in play), flat emitted colours no natural pixel has: 1 the canopy magenta and the walls red, cut
// as drawn; 2 the same with no cut at all (the whole mesh: where the shell stands, whatever its cover and the handover).
uniform int debug_mode = 0;

varying vec3 wpos;
varying float vdist;
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

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vdist = distance(wpos, wf_cam_pos(MAIN_CAM_INV_VIEW_MATRIX));
	cust = CUSTOM0.xyz;
	vtype = CUSTOM0.w;
}

void fragment() {
	bool wall = cust.y > 0.001;
	if (debug_mode == 2) {
		ALBEDO = vec3(0.0);
		EMISSION = wall ? vec3(1.0, 0.0, 0.0) : vec3(1.0, 0.0, 1.0);
		ROUGHNESS = 1.0;
	} else {
		if (wf_dither(FRAGCOORD.xy) >= wf_band(far_cut - fade_m, far_cut, vdist)) {
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
		int band = cust.z < coast_m ? 0 : (cust.z < mid_m ? 1 : 2);
		int row = ty * 3 + band;
		vec4 meanp = texelFetch(palette, ivec2(8, row), 0);
		vec2 gp = wpos.xz / max(meanp.a, 1.0);
		vec2 ip = floor(gp);
		vec2 fp = fract(gp);
		float best = 8.0;
		vec2 bcell = ip;
		vec2 bvec = vec2(0.0);
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				vec2 o = vec2(float(i), float(j));
				vec2 rv = o + far_h22(ip + o) * 0.8 + 0.1 - fp;
				float d2 = dot(rv, rv);
				if (d2 < best) {
					best = d2;
					bcell = ip + o;
					bvec = rv;
				}
			}
		}
		float rim = clamp(sqrt(best) / 0.7, 0.0, 1.0);
		float far_w = smoothstep(0.25, 0.5, length(fwidth(gp)));   // 1 where a crown spans under about 2 pixels
		float own = mix(far_h12(bcell), wf_dither(FRAGCOORD.xy + vec2(17.0, 31.0)), far_w);
		if (own >= cover) {
			discard;
		}
		float pick = far_h12(bcell + 19.7);
		vec3 col = meanp.rgb;
		for (int k = 0; k < 8; k++) {
			vec4 e = texelFetch(palette, ivec2(k, row), 0);
			if (e.a <= 0.0) {
				break;
			}
			if (pick <= e.a) {
				col = e.rgb;
				break;
			}
		}
		vec3 albedo = mix(col * mix(1.0, 0.55, rim * rim), meanp.rgb * 0.85, far_w);
		vec3 geo = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 nw = geo;
		if (wall) {
			albedo = meanp.rgb * 0.7;
		} else {
			nw = normalize(geo + vec3(-bvec.x, 0.0, -bvec.y) * 1.2 * (1.0 - far_w));
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
