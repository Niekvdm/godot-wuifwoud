#[compute]
#version 450
// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT

// One level of a hierarchical-Z pyramid: reduce the source by 2x and keep the FARTHEST
// depth in each footprint. The forest's cull samples this to reject instances that are
// entirely behind what was already drawn.
//
// GODOT USES REVERSE-Z (measured, not recalled): a point 1 m in front of the camera
// projects to z = 0.049988 and one at 1000 m to z = 0.000037, so NEAR IS LARGER. The
// farthest fragment is therefore the MINIMUM value, and this reduces with min(). Getting
// that backwards does not look like a bug, it looks like the forest disappearing.
//
// 3x3, NOT 2x2, and always clamped. A plain 2x2 halving drops a row and a column whenever
// the source dimension is odd, and the dropped texel might be the far one: losing it
// raises the stored depth and lets something visible be culled. Folding in the extra ring
// can only lower the stored value, which can only make culling LESS likely. Every rounding
// choice in an occlusion pyramid has to fall that way: a false cull is a hole in the world,
// a missed cull is a tree drawn for nothing.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// SAMPLED, NOT AN IMAGE, and the difference is not stylistic. With MSAA ON the resolved
// depth comes back as an R32_SFLOAT with STORAGE usage and either binding works; with MSAA
// OFF there is nothing to resolve, so `access_resolved_depth` hands over the actual
// depth-stencil attachment: a depth format with SAMPLING but no STORAGE. Binding that as
// an image is rejected ("needs the TEXTURE_USAGE_STORAGE_BIT"), once per species per frame,
// and the error spam alone takes a 14 ms frame to 256. texelFetch works on both.
layout(set = 0, binding = 0) uniform sampler2D src;
layout(r32f, set = 0, binding = 1) uniform writeonly image2D dst;

layout(push_constant) uniform Params {
	ivec4 sizes;   // xy = dst size, zw = src size
} p;

void main() {
	ivec2 t = ivec2(gl_GlobalInvocationID.xy);
	ivec2 ds = p.sizes.xy;
	ivec2 ss = p.sizes.zw;
	if (t.x >= ds.x || t.y >= ds.y) {
		return;
	}
	ivec2 s = t * 2;
	float d = texelFetch(src, clamp(s, ivec2(0), ss - 1), 0).r;
	for (int y = 0; y < 3; ++y) {
		for (int x = 0; x < 3; ++x) {
			d = min(d, texelFetch(src, clamp(s + ivec2(x, y), ivec2(0), ss - 1), 0).r);
		}
	}
	imageStore(dst, t, vec4(d, 0.0, 0.0, 0.0));
}
