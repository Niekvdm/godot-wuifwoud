#[compute]
#version 450
// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT

// GPU VEGETATION CULL: one species' island-wide instance arena, compacted into
// per-distance-band MultiMeshes and drawn INDIRECTLY.
//
// One MultiMeshInstance3D per (64 m chunk x species) is 3 699 drawables for 29 511
// trees, about eight instances each: Godot then pays a per-drawable cull, a
// per-drawable LOD pick and a per-drawable submit for groups of eight, and creating
// them costs ~8 ms of `add_child` apiece while streaming. Here one arena per species
// holds every instance in the ring, and this shader sorts them by distance into a
// handful of output buffers each frame, so the draw count is species x bands (about
// 150), not species x chunks, and the LOD level is chosen PER TREE instead of per
// chunk.
//
// WHY THE BANDS ARE THE LOD LEVELS. A draw carries one mesh, so a band is exactly as
// fine-grained as a mesh LOD can be. The bands come from the pack's authored
// `_LOD0..3` switch distances (ForestAssets.LOD_SWITCH_M), split once more at the
// shadow ring so the near bands can cast and the far ones cannot: the
// per-chunk shadow ring, for free and at instance precision.
//
// ONE WORKGROUP PER SPECIES, ON PURPOSE. The compaction counter has to be readable by
// whoever writes `instance_count` into the indirect command buffer, and cross-
// workgroup visibility would need either a second dispatch or a global counter buffer
// plus a barrier. Inside a single workgroup a `shared` counter and one `barrier()` do
// it: the grid-stride loop covers an arena of any size, and the same 256 threads then
// write the command buffers. A species is a few thousand instances, so the loop is
// ~10 iterations deep and the poor occupancy of one workgroup costs nothing: there
// are ~25 species dispatched together.
//
// 1024 THREADS CHANGES NOTHING. With the impostor tier in the arena a species can
// hold 50 000 cards, ~200 grid-stride iterations at 256 threads, so one workgroup
// keeping the GPU busy is the obvious suspicion. Measured at a driver-eye station:
// 14.98 ms against 14.83, inside the noise. The arena scan is not what the impostor
// tier costs.

#define MAX_BINS 6
// Blocks tested per batch: one per thread, so it matches the workgroup.
#define MAX_BLOCKS 256

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// The species arena: Godot's MultiMesh TRANSFORM_3D + custom-data layout, four vec4
// per instance: the basis TRANSPOSED with the origin in the .w column, then the
// custom data (the per-tree tint). Identical to what pack_instance() writes, because
// it IS what pack_instance writes: the arena is uploaded verbatim.
layout(set = 0, binding = 0, std430) restrict readonly buffer Src { vec4 d[]; } src;

// One compacted output per band: the RD buffer behind each band's MultiMesh.
layout(set = 0, binding = 1, std430) restrict writeonly buffer Dst0 { vec4 d[]; } dst0;
layout(set = 0, binding = 2, std430) restrict writeonly buffer Dst1 { vec4 d[]; } dst1;
layout(set = 0, binding = 3, std430) restrict writeonly buffer Dst2 { vec4 d[]; } dst2;
layout(set = 0, binding = 4, std430) restrict writeonly buffer Dst3 { vec4 d[]; } dst3;
layout(set = 0, binding = 5, std430) restrict writeonly buffer Dst4 { vec4 d[]; } dst4;
layout(set = 0, binding = 6, std430) restrict writeonly buffer Dst5 { vec4 d[]; } dst5;

// Each band's indirect command buffer: five uint per SURFACE, laid out
// [index_count, instance_count, first_index, base_vertex, first_instance]. Godot fills
// index_count when the mesh is set and leaves the rest zero (measured on 4.7, two
// surfaces: `[3 0 0 0 0  6 0 0 0 0]`), so the only field this shader owns is
// instance_count at +1. Writing it is what makes the draw exist.
layout(set = 0, binding = 7,  std430) restrict buffer Cmd0 { uint c[]; } cmd0;
layout(set = 0, binding = 8,  std430) restrict buffer Cmd1 { uint c[]; } cmd1;
layout(set = 0, binding = 9,  std430) restrict buffer Cmd2 { uint c[]; } cmd2;
layout(set = 0, binding = 10, std430) restrict buffer Cmd3 { uint c[]; } cmd3;
layout(set = 0, binding = 11, std430) restrict buffer Cmd4 { uint c[]; } cmd4;
layout(set = 0, binding = 12, std430) restrict buffer Cmd5 { uint c[]; } cmd5;

// Camera state, shared by every species and rewritten once a frame. Not a push
// constant: six frustum planes plus a camera is 112 bytes and the per-species push
// already carries the band table, which would put the two over the 128-byte floor
// Vulkan guarantees.
//
// THE PLANE SIGN IS NORMALISED ON THE CPU, not assumed here: whichever way Godot's
// `Camera3D.get_frustum()` points its normals, the spawner flips any plane that puts
// a point known to be inside the frustum on its negative side. So the rule here is
// always "inside when `dot(n, p) + d >= -r`".
layout(set = 0, binding = 13, std430) restrict readonly buffer Globals {
	vec4 cam;         // xyz = MAIN camera position this frame
	// A SECOND, DELIBERATELY STALE CAMERA, used only for distance THINNING. It jumps in
	// discrete steps once the real camera has moved far enough (VegetationIndirect
	// ._globals_bytes). Thinning is a hard per-instance cut with no fade, so against an
	// exact camera EVERY FRAME any wobble in the camera's distance flips the cards
	// sitting on the threshold on and off: "the billboards flicker while climbing",
	// because altitude changes every card's distance at once and they all sit on the
	// threshold together.
	vec4 thin_cam;
	vec4 planes[6];   // xyz = inward normal, w = d
	// LAST FRAME'S view-projection, and it must be last frame's. The cull for frame N
	// runs on the render thread before frame N has drawn anything, so the only depth
	// that exists is the previous frame's; testing against it with the CURRENT matrix
	// would compare a picture taken from one place against geometry projected from
	// another, and cull whatever the camera swept past.
	vec4 prev_vp[4];
	// x,y = pyramid size in texels, z = mip count, w = 0 disables the test entirely.
	vec4 hiz;
} G;

layout(push_constant, std430) uniform Params {
	vec4 e0;       // band boundaries 0..3 (band i spans [edge(i), edge(i+1)))
	vec4 e1;       // band boundaries 4..7
	vec4 f;        // x = species bounding radius, unscaled; y = shadow cull slack, m;
	               // z = distance thinning starts, m; w = share thinned away at the cut
	uvec4 misc;    // x = arena high-water, y = band count, z = per-band capacity,
	               // w = surface count of this species' mesh
	uvec4 misc2;   // x = bitmask of bands that cast shadows, y = block count
	               // (0 = no block table, scan the arena flat),
	               // z = vec4 per instance: 4 for transform+one attribute (the forest),
	               // 5 when a field carries BOTH colour and custom data (the grass)
} p;

// LEVEL 1. Every block in the arena is a spatial cluster (the 1024 m impostor cell or
// the 64 m mesh chunk it was committed from), and this is its bounding sphere plus the
// slice of the arena it occupies. Uploaded when the ring changes, not per frame.
//
// WHY THIS EXISTS. Without it the cull is a FLAT SCAN of the whole species: measured at
// 0.03 ms for the mesh tier's 29 511 instances and 0.37 ms for 512 752 with the
// impostor tier in, which loses the impostor tier the frame it wins on draw calls.
// Godot's own per-cell culling is hierarchical, and a flat scan cannot beat hierarchy
// however few draws it produces, so the answer is to be hierarchical too.
//
// IT IS ON THE GPU AND NOT THE CPU ON PURPOSE. ~500 blocks x 6 plane tests per frame is
// about 0.3 ms of GDScript, which is the whole prize.
// RANGE IS FLOATS, NOT UINTS, and that is a CPU decision showing through. A mixed
// vec4+uvec4 struct cannot be built on the CPU side without interleaving two typed
// arrays byte by byte (32 byte-assignments per block, every block, every frame the
// ring moves: 5-15 ms at 100 m/s). All-float lets the table be one PackedFloat32Array
// written in place and uploaded in slices.
// Offsets stay exact: float32 represents every integer below 2^24, and the arena is
// hundreds of thousands of instances, not millions.
struct Block {
	vec4 sphere;   // xyz = centre, w = radius
	vec4 range;    // x = first instance in the arena, y = count
};
layout(set = 0, binding = 14, std430) restrict readonly buffer Blocks { Block d[]; } blk;

// HIERARCHICAL DEPTH from the previous frame: see forest_hiz_pyramid.gd for how it is built and
// what was measured to build it. Reverse-Z, so each texel holds the FARTHEST fragment in
// its footprint and an instance is hidden only when its nearest point is behind that.
// SET 1, NOT SET 0, and that is a lifetime decision. Set 0 is built once per species and
// cached; the pyramid's texture is recreated whenever the viewport resizes, and a cached set
// holding a freed RID is a crash rather than a stale picture. Its own set is rebuilt with the
// pyramid and bound alongside, so the two lifetimes never have to agree.
layout(set = 1, binding = 0) uniform sampler2D hiz;

shared uint g_count[MAX_BINS];
shared uint g_live[MAX_BLOCKS];
shared uint g_nlive;

float edge(uint k) {
	return (k < 4u) ? p.e0[k] : p.e1[k - 4u];
}

// DETERMINISTIC [0, 1) FROM A WORLD POSITION, quantised to 0.25 m: bit-for-bit the
// same mixing as `ForestSpawner._thin_key`, so the impostors that survive
// thinning are the same ones on every peer and every run. A card that changes its mind
// about existing as the count moves is a forest that shimmers.
float thin_key(vec3 pos) {
	uint qx = uint(int(floor(pos.x * 4.0)) + 1048576);
	uint qz = uint(int(floor(pos.z * 4.0)) + 1048576);
	uint h = qx * 374761393u + qz * 668265263u;
	h = (h ^ (h >> 13u)) * 1274126177u;
	h = h ^ (h >> 16u);
	return float(h & 0xFFFFFFu) / 16777216.0;
}

// A block survives if its sphere can reach the species' cut AND touches the frustum.
// The slack is the SPECIES' worst case rather than a band's: a block spans several
// bands, so it has to be kept if any of them casts.
bool block_visible(Block bl, float cut) {
	float r = bl.sphere.w + (p.misc2.x != 0u ? p.f.y : 0.0);
	if (distance(bl.sphere.xyz, G.cam.xyz) - r > cut) {
		return false;
	}
	for (uint k = 0u; k < 6u; ++k) {
		if (dot(G.planes[k].xyz, bl.sphere.xyz) + G.planes[k].w < -r) {
			return false;
		}
	}
	return true;
}

// Copy one instance's whole row, whatever the row is. The stride is a push constant
// because the tiers that share this shader need not agree on it: a tree carries a
// transform plus one four-float attribute (4 vec4), a tier with both colour and custom
// data carries 5. Everything the cull reads (position, scale) sits in the first three
// vec4 either way, so only the copy has to know.
void store(uint bin, uint slot, uint src_base, uint stride) {
	uint o = slot * stride;
	switch (bin) {
		case 0u: for (uint k = 0u; k < stride; ++k) { dst0.d[o + k] = src.d[src_base + k]; } break;
		case 1u: for (uint k = 0u; k < stride; ++k) { dst1.d[o + k] = src.d[src_base + k]; } break;
		case 2u: for (uint k = 0u; k < stride; ++k) { dst2.d[o + k] = src.d[src_base + k]; } break;
		case 3u: for (uint k = 0u; k < stride; ++k) { dst3.d[o + k] = src.d[src_base + k]; } break;
		case 4u: for (uint k = 0u; k < stride; ++k) { dst4.d[o + k] = src.d[src_base + k]; } break;
		case 5u: for (uint k = 0u; k < stride; ++k) { dst5.d[o + k] = src.d[src_base + k]; } break;
	}
}

void write_cmd(uint bin, uint surf, uint count) {
	uint o = surf * 5u + 1u;
	switch (bin) {
		case 0u: cmd0.c[o] = count; break;
		case 1u: cmd1.c[o] = count; break;
		case 2u: cmd2.c[o] = count; break;
		case 3u: cmd3.c[o] = count; break;
		case 4u: cmd4.c[o] = count; break;
		case 5u: cmd5.c[o] = count; break;
	}
}

void cull_instance(uint i, uint bins, uint cap);

void main() {
	uint t = gl_LocalInvocationID.x;
	if (t < MAX_BINS) {
		g_count[t] = 0u;
	}
	memoryBarrierShared();
	barrier();

	uint n = p.misc.x;
	uint bins = min(p.misc.y, uint(MAX_BINS));
	uint cap = p.misc.z;
	uint nblocks = p.misc2.y;
	if (nblocks == 0u) {
		// NO BLOCK TABLE: a flat scan. Kept for the first frames of a species, before
		// its table has been uploaded, and as the answer for anything committed without
		// spatial grouping.
		for (uint i = t; i < n; i += gl_WorkGroupSize.x) {
			cull_instance(i, bins, cap);
		}
	} else {
		// LEVEL 1 THEN LEVEL 2, a batch of blocks at a time so any block count fits in
		// the shared list. One thread tests one block; the survivors are compacted and
		// then walked by the whole workgroup.
		for (uint base = 0u; base < nblocks; base += uint(MAX_BLOCKS)) {
			if (t == 0u) {
				g_nlive = 0u;
			}
			memoryBarrierShared();
			barrier();
			uint b = base + t;
			if (b < nblocks) {
				Block bl = blk.d[b];
				if (bl.range.y > 0.0 && block_visible(bl, edge(bins))) {
					g_live[atomicAdd(g_nlive, 1u)] = b;
				}
			}
			memoryBarrierShared();
			barrier();
			uint nl = g_nlive;
			for (uint k = 0u; k < nl; ++k) {
				vec2 rg = blk.d[g_live[k]].range.xy;
				uint rstart = uint(rg.x);
				uint rcount = uint(rg.y);
				for (uint i = t; i < rcount; i += gl_WorkGroupSize.x) {
					cull_instance(rstart + i, bins, cap);
				}
			}
			memoryBarrierShared();
			barrier();
		}
	}

	memoryBarrierShared();
	barrier();

	// One thread per (band, surface) writes that draw's instance count. Clamped to the
	// capacity because the counter kept climbing past it above; the extra instances
	// were never stored, so drawing them would read stale slots.
	uint surfaces = max(p.misc.w, 1u);
	if (t < bins * surfaces) {
		uint bin = t / surfaces;
		uint surf = t - bin * surfaces;
		write_cmd(bin, surf, min(g_count[bin], cap));
	}
}


// OCCLUSION. Is this instance's bounding sphere entirely behind what was already drawn?
//
// EVERY UNCERTAIN CASE RETURNS FALSE, i.e. "draw it". A false cull is a hole in the world
// that appears when the camera turns; a missed cull is one tree drawn for nothing. With a
// pyramid that is a frame stale, the two are not close to equally bad.
//
// The sphere is projected as its eight AABB corners rather than analytically: the screen
// bound is then conservative by construction, and the same loop yields the nearest depth.
bool occluded(vec3 centre, float radius) {
	if (G.hiz.w < 0.5) {
		return false;
	}
	mat4 vp = mat4(G.prev_vp[0], G.prev_vp[1], G.prev_vp[2], G.prev_vp[3]);
	vec3 lo = centre - radius;
	vec3 hi = centre + radius;
	vec2 mn = vec2(1e30);
	vec2 mx = vec2(-1e30);
	float nearest = 0.0;      // reverse-Z: 0 is the far plane, so this only grows
	for (int i = 0; i < 8; ++i) {
		vec3 c = vec3((i & 1) != 0 ? hi.x : lo.x,
					  (i & 2) != 0 ? hi.y : lo.y,
					  (i & 4) != 0 ? hi.z : lo.z);
		vec4 clip = vp * vec4(c, 1.0);
		// Straddling the camera plane makes the perspective divide meaningless. Anything
		// that close is in your face; never cull it.
		if (clip.w <= 1e-4) {
			return false;
		}
		vec3 ndc = clip.xyz / clip.w;
		mn = min(mn, ndc.xy);
		mx = max(mx, ndc.xy);
		nearest = max(nearest, ndc.z);
	}
	vec2 uv0 = mn * 0.5 + 0.5;
	vec2 uv1 = mx * 0.5 + 0.5;
	if (uv1.x <= 0.0 || uv1.y <= 0.0 || uv0.x >= 1.0 || uv0.y >= 1.0) {
		return false;   // off screen; the frustum test owns that case, not this one
	}
	uv0 = clamp(uv0, vec2(0.0), vec2(1.0));
	uv1 = clamp(uv1, vec2(0.0), vec2(1.0));

	// Pick the level whose texel covers the whole screen rect, so four taps bound it
	// whatever its size. +1 because a rect of N texels can straddle N+1 of them.
	vec2 px = (uv1 - uv0) * G.hiz.xy;
	float lod = clamp(ceil(log2(max(max(px.x, px.y), 1.0))), 0.0, G.hiz.z - 1.0);
	float d = textureLod(hiz, uv0, lod).r;
	d = min(d, textureLod(hiz, vec2(uv1.x, uv0.y), lod).r);
	d = min(d, textureLod(hiz, vec2(uv0.x, uv1.y), lod).r);
	d = min(d, textureLod(hiz, uv1, lod).r);

	// Behind the farthest thing in that footprint, with a margin. The margin is
	// relative because reverse-Z depth is hyperbolic: a fixed epsilon is enormous near
	// the camera and nothing at all far away.
	return nearest < d * 0.999;
}


// ONE INSTANCE: band, frustum, thinning, store. Factored out because it is driven from
// two places: the flat scan and the per-block walk.
void cull_instance(uint i, uint bins, uint cap) {
	{
		uint stride = max(p.misc2.z, 4u);
		uint b0 = i * stride;
		vec4 a = src.d[b0];
		vec4 b = src.d[b0 + 1u];
		vec4 c = src.d[b0 + 2u];
		// A FREED SLOT IS A ZERO BASIS. Blocks are released by zeroing them in place:
		// the arena is a bump allocator with a free list, not a compacted array, so a
		// hole has to be recognisable from the data alone. No live instance has a zero
		// scale (the scatter's range is 0.8..1.5), so the first basis column's length
		// is an exact liveness test and costs three multiplies.
		vec3 col0 = vec3(a.x, b.x, c.x);
		float scl2 = dot(col0, col0);
		if (scl2 <= 0.0) {
			return;
		}
		vec3 pos = vec3(a.w, b.w, c.w);
		float d = distance(pos, G.cam.xyz);
		uint bin = uint(MAX_BINS);
		for (uint k = 0u; k < bins; ++k) {
			if (d >= edge(k) && d < edge(k + 1u)) {
				bin = k;
				break;
			}
		}
		if (bin >= bins) {
			return;   // past the species' cut, or behind the near edge of band 0
		}
		// FRUSTUM CULL: THE HALF THAT MAKES THIS PAY. Without it the per-chunk path
		// wins on geometry even while losing on draw count: Godot frustum-culls 3 699
		// chunk-sized drawables hard, and a 70-degree view keeps maybe a quarter of
		// them, whereas one band covers a ring around the camera and passes whatever
		// it is tested against (without it: draws 2 353 -> 840 at a driver-eye station
		// and the frame 12.2 -> 15.1 ms).
		//
		// SHADOW CASTERS GET SLACK INSTEAD OF AN EXEMPTION. One command buffer serves
		// the colour pass AND every shadow cascade, so a count culled to the main
		// frustum culls the tree out of its own shadow. Bands that cast are tested
		// against the same planes pushed out by `f.y` (the shadow ring), which keeps
		// a halo of off-screen casters; bands that do not cast are tested exactly.
		float r = p.f.x * sqrt(scl2)
			+ (((p.misc2.x >> bin) & 1u) != 0u ? p.f.y : 0.0);
		bool inside = true;
		for (uint k = 0u; k < 6u; ++k) {
			if (dot(G.planes[k].xyz, pos) + G.planes[k].w < -r) {
				inside = false;
				break;
			}
		}
		if (!inside) {
			return;
		}
		// AFTER the frustum, BEFORE thinning: the frustum test is six dot products and
		// rejects most of the arena, so the texture taps here are only paid by instances
		// that survived it. Shadow-casting bands are exempt: the same command buffer
		// feeds every cascade, and something the camera cannot see can still throw a
		// shadow that it can.
		if (((p.misc2.x >> bin) & 1u) == 0u && occluded(pos, p.f.x * sqrt(scl2))) {
			return;
		}
		// DISTANCE THINNING, PER INSTANCE. The keep fraction is evaluated at the card's
		// own distance, so the field thins smoothly across a cell instead of stepping at
		// its boundary (as a cell's `visible_instance_count` would), and nothing
		// downstream depends on buffer order.
		if (p.f.w > 0.0) {
			float td = distance(pos, G.thin_cam.xyz);
			float t = clamp((td - p.f.z) / max(edge(bins) - p.f.z, 1.0), 0.0, 1.0);
			if (thin_key(pos) >= 1.0 - p.f.w * t) {
				return;
			}
		}
		uint slot = atomicAdd(g_count[bin], 1u);
		if (slot >= cap) {
			return;   // band full: drop, never wrap; a wrap would corrupt live slots
		}
		store(bin, slot, b0, stride);
	}
}
