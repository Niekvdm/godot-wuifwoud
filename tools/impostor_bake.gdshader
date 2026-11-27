// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
shader_type spatial;
render_mode unshaded, cull_disabled;
// THE IMPOSTOR G-BUFFER, for ForestImpostorBaker (the pack build). Not used at runtime.
//
// Each view is rendered once per CHANNEL, and each channel is a term the mesh tree's own
// shader (tree_wind.gdshader) computes for that texel, so the card is shaded by what the
// mesh is shaded by, rather than by a sphere guessed at runtime:
//
//   channel 0  ALBEDO: tex.rgb * albedo * the crown term `shade` (occlusion keyed on the
//              leaf's TRUE 3D depth in the crown). The same term taken off the 2D
//              distance from the card's centre would put the crown's sunlit FRONT
//              shell (the centre of the card) at its darkest.
//   channel 1  NORMAL + TRANSMISSION: the normal the mesh is lit with (spherified or
//              authored, back faces handled as the mesh handles them, the normal map
//              applied), in THIS VIEW's space, x/y in R/G; the backlight weight in B.
//   channel 2  DEPTH: how far the texel stands in front of the tile's centre plane (toward
//              this view's camera), in span units, as depth * `depth_scale` + 0.5 in R and
//              1 in G, which the premultiply turns into (depth x coverage, coverage). The
//              card reprojects each blended frame by it (tree_billboard.gdshader).
//
// UNSHADED IS AN IDENTITY ON THE OUTPUT. With the bake's LINEAR tonemapper at exposure 1,
// what lands in the viewport is linear_to_srgb(ALBEDO). Channel 0 is a colour and wants
// exactly that. Channel 1 is DATA, so it writes srgb_to_linear(data) and the encode hands
// back the data byte for byte.
//
// COVERAGE IS BINARY: a texel under the cut is discarded, everything else is opaque, and
// MSAA is off in the bake. The edges are antialiased by SUPERSAMPLING (the bake renders
// 4x the stored tile and box-filters down, premultiplied), never by an MSAA resolve
// against the transparent-black background, which would darken every edge texel, and
// the silhouette is nearly all edge at the size an impostor is seen.

uniform int channel = 0;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 albedo : source_color = vec3(1.0, 1.0, 1.0);
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform float normal_depth : hint_range(0.0, 4.0) = 1.0;
uniform bool has_mtao = false;
uniform vec3 crown_centre = vec3(0.0, 1.0, 0.0);
uniform float crown_radius = 1.0;
uniform float spherify : hint_range(0.0, 1.0) = 0.0;
// tree_wind's crown_floor: a leaf surface's own stem below it is bark. -1e6: no stem.
uniform float crown_floor = -1.0e6;
uniform float crown_ao : hint_range(0.0, 1.0) = 0.45;
uniform float foliage_mask = 1.0;
// The depth channel's origin (the tile's centre, where every bake camera aims, in the
// bake's world) and 1 / (span * DEPTH_RANGE): ForestImpostorBaker sets both per species.
uniform vec3 depth_centre = vec3(0.0);
uniform float depth_scale = 1.0;

varying float crown_depth;
varying float leaf_w;

void vertex() {
	// tree_wind.gdshader's vertex(), minus the wind: crown depth before anything moves,
	// and the spherified normal.
	vec3 from_c = VERTEX - crown_centre;
	float crown_r = length(from_c);
	crown_depth = clamp(crown_r / max(crown_radius, 0.001), 0.0, 1.0);
	leaf_w = smoothstep(crown_floor - 0.5, crown_floor + 0.5, VERTEX.y);
	if (foliage_mask > 0.5 && spherify > 0.001 && crown_r > 0.001) {
		NORMAL = normalize(mix(NORMAL, from_c / crown_r, spherify * leaf_w));
	}
}

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThanEqual(c, vec3(0.04045)));
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	if (tex.a < alpha_cut) {
		discard;
	}
	if (channel == 2) {
		// View space looks down -Z, so +Z is toward this view's camera: a texel nearer the
		// camera than the centre plane has the larger view-space z.
		float zc = (VIEW_MATRIX * vec4(depth_centre, 1.0)).z;
		float e = clamp((VERTEX.z - zc) * depth_scale + 0.5, 0.0, 1.0);
		ALBEDO = srgb_to_linear(vec3(e, 1.0, 0.0));
	} else if (channel == 0) {
		// tree_wind's `shade`, without the world-space break-up noise (a property of where
		// a tree stands, not of the tree: the card gets its per-instance tint instead).
		float crown_k = has_mtao ? crown_ao * 0.35 : crown_ao;
		float ao = mix(1.0 - crown_k, 1.0, crown_depth);
		float shade = mix(1.0, ao, foliage_mask * leaf_w);
		ALBEDO = tex.rgb * albedo * shade;
	} else {
		// The normal tree_wind lights with. A back face keeps the authored normal (Godot
		// has already negated it under DO_SIDE_CHECK; negating again restores it: see the
		// note in tree_wind.gdshader), and the normal map is applied the way the forward
		// shader applies NORMAL_MAP after fragment(), by hand, because an unshaded
		// shader's output cannot read the result.
		vec3 n = NORMAL;
		float depth = normal_depth;
		if (!FRONT_FACING) {
			n = -n;
			depth = -normal_depth;
		}
		if (has_normal) {
			vec3 nm = texture(normal_tex, UV).rgb;
			nm.xy = nm.xy * 2.0 - 1.0;
			nm.z = sqrt(max(0.0, 1.0 - dot(nm.xy, nm.xy)));
			n = normalize(mix(n, TANGENT * nm.x + BINORMAL * nm.y + n * nm.z, depth));
		}
		n = normalize(n);
		// Thin outer leaves transmit, the packed interior does not, bark not at all:
		// tree_wind's BACKLIGHT weight, scaled into 0..1 (the card multiplies by 1.35).
		float trans = foliage_mask * leaf_w * mix(0.35, 1.35, crown_depth) / 1.35;
		// The view axis is +Z toward the bake camera, so a visible texel's normal has
		// z >= 0, but a normal map or an authored field can tip one slightly past the
		// rim, and the 2-channel encoding cannot say so. The runtime rebuilds z as
		// sqrt(1 - x² - y²), i.e. clamps it onto the camera's hemisphere.
		ALBEDO = srgb_to_linear(vec3(n.xy * 0.5 + 0.5, trans));
	}
}
