// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#ifndef WF_ARENA_H
#define WF_ARENA_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <deque>
#include <unordered_map>
#include <utility>
#include <vector>

namespace wf {

// A committed block is split into clusters of at most this many instances (the GPU path's level-1 cull; ForestIndirect's
// BLOCK_SPLIT).
constexpr int64_t BLOCK_SPLIT = 256;
// Floats a cluster: [cx, cy, cz, radius, rel, n], rel the cluster's first instance relative to its block.
constexpr int64_t CLUSTER_FLOATS = 6;

// The clusters of a packed buffer: every BLOCK_SPLIT instances, the bounding sphere of their
// origins (floats 3, 7 and 11 of an instance) grown by `reach`. The GDScript walk's arithmetic exactly (ForestIndirect's
// _plan_walk: float32 bounds and centre, the half diagonal in float32, `+ reach` in double, stored as float32), so a
// block installed from these clusters writes the same block-table bytes as one _plan_walk planned. `p_n` instances
// must lie in `p_buf`.
void walk_clusters(const float *p_buf, int64_t p_n, int64_t p_stride, double p_reach, std::vector<float> &r_out);

} // namespace wf

namespace godot {

// ONE SPECIES' (AND TIER'S) INSTANCE ARENA, CPU SIDE: the instance buffer with its logical count, GPU capacity and
// growth, the first-fit free list, the level-1 block table and the ranges awaiting upload, so an install is one memcpy,
// a free one strided memset, and a frame's uploads leave as bytes. Made by WfCore.make_arena; MAIN THREAD ONLY
// (ForestIndirect owns it; workers never see one). test_wf_arena pins the uploads it sends, byte for byte, by their
// hashes.
class WfArena : public RefCounted {
	GDCLASS(WfArena, RefCounted)

public:
	static constexpr int64_t MIN_CAP = 2048; // the arena's floor: most species' first or second step
	static constexpr int64_t GROW_LINEAR_AT = 32768; // past this the capacity grows by a quarter, not double
	static constexpr int64_t MIN_BLOCKS = 256; // block-table rows to begin with; doubles from there
	static constexpr int64_t BLOCK_FLOATS = 8; // a row: [cx, cy, cz, radius, off, n, 0, 0] (wf_cull.glsl's Block)
	// The block table carries offsets and counts as float32: past 2^24 they are no longer exact, so no arena grows there.
	static constexpr int64_t MAX_INSTANCES = int64_t(1) << 24;

private:
	struct Range {
		int64_t off = 0;
		int64_t n = 0;
		bool payload = false; // write_at's rows on a fixed arena: uploaded as they came, never copied in
		PackedByteArray bytes;
	};

	int64_t stride_ = 16;
	bool fixed_ = false;
	int64_t n_ = 0; // logical instances (a fixed arena: its capacity)
	int64_t cap_ = 0; // the GPU buffer's instances
	bool realloc_ = true; // the GPU buffers must be made again (and everything uploaded)
	std::vector<float> buf_; // n_ * stride_ floats (a fixed arena: cap_ * stride_); its capacity follows cap_, so an append
	// within the GPU capacity never moves (copies) the whole buffer
	std::vector<std::pair<int64_t, int64_t>> free_; // first fit, in release order: [offset, count]
	std::unordered_map<int64_t, int64_t> live_; // offset -> count of every block handed out and not yet freed
	int64_t live_n_ = 0; // instances in those blocks (the high-water n_ less the released holes)
	std::vector<float> btab_; // bcap_ * BLOCK_FLOATS
	int64_t bcap_ = 0;
	int64_t bhigh_ = 0; // rows in use, freed ones (count 0) included
	std::unordered_map<int64_t, int64_t> bidx_; // block key (its arena offset) -> row
	std::vector<int64_t> bfree_; // rows a free released, reused last-in first-out
	std::vector<uint8_t> bdirty_; // per row: awaiting upload
	int64_t bdirty_n_ = 0;
	std::deque<Range> dirty_;

	void block_set(int64_t p_key, float p_cx, float p_cy, float p_cz, float p_r, int64_t p_off, int64_t p_n);
	bool block_clear(int64_t p_key);
	void mark_dirty(int64_t p_off, int64_t p_n);
	void mark_payload(int64_t p_off, int64_t p_n, const PackedByteArray &p_bytes);
	static PackedByteArray bytes_of(const float *p_src, int64_t p_floats);

protected:
	static void _bind_methods();

public:
	// A growing arena (p_fixed_cap 0) or a fixed one of p_fixed_cap instances (a caller that places rows itself, through
	// write_at: a grass field's slot pool). False for a stride under 12 or over 64 floats, or a capacity out of range.
	bool setup(int64_t p_stride, int64_t p_fixed_cap);

	// `n` instances (n * stride floats of `buf`) installed: first fit over the free list, else appended (growing); one
	// copy. The block rows from `clusters` ([cx, cy, cz, radius, rel, n] each, radius WITHOUT `reach`: the place kernel's)
	// when they are the BLOCK_SPLIT walk's shape, else the arena's own walk; every radius grows by `reach`. {"off", "n"},
	// or {} (refused, nothing changed) for n <= 0, a buffer shorter than n * stride, a fixed arena, or past the limit.
	Dictionary add(const PackedFloat32Array &p_buf, int64_t p_n, const PackedFloat32Array &p_clusters, double p_reach);
	// A block released: its liveness column (floats 0, 4 and 8 of each instance) zeroed, its rows cleared, its range
	// back on the free list. False (nothing changed) when (off, n) is not a block this arena handed out and holds.
	// Not `free`: Object.free() is every object's, and a method of that name would shadow it.
	bool release(int64_t p_off, int64_t p_n);
	// Rows at a known offset (a fixed arena: uploaded as they came; a growing one: copied in) registered as ONE block with
	// the caller's bounds; n <= 0 clears the block at `off`. True when anything changed.
	bool write_at(int64_t p_off, int64_t p_n, const PackedFloat32Array &p_rows, const Vector3 &p_centre, double p_radius);
	// What the GPU needs this frame, as ForestIndirect.update sends it: {"ranges": [[byte offset, PackedByteArray], …] (at
	// most `max_ranges` dirty ranges; the rest stay queued), "rows": [[byte offset, PackedByteArray], …] (the block rows
	// that changed, adjacent rows merged; the whole table on a realloc), "realloc", "n", "cap", "nblocks", "bcap", "more"
	// (ranges left for a later frame)}.
	Dictionary take_uploads(int64_t p_max_ranges);
	// Capacity for at least `n` instances, rounded up to 4096, and block-table rows in proportion to the rows `n_`
	// instances hold now: a card arena is pre-sized when a fill ends, so the ring a drive brings in never forces a regrow,
	// and a regrow of either rebuilds the species' GPU side in one frame. The realloc it raises sends the whole arena on
	// the next take_uploads. False (nothing changed) for a fixed arena, `n` past MAX_INSTANCES, or both capacities already
	// there.
	bool reserve(int64_t p_n);
	// {"floats", "reserved" (the CPU buffer's capacity, floats), "n", "cap", "bcap", "nblocks", "free_rows", "free_ranges",
	// "live", "live_n" (instances in live blocks), "dirty", "fixed", "stride", "realloc" (the next take_uploads rebuilds
	// the GPU side)}.
	Dictionary stats() const;
	// Tests: the instance buffer's floats of instances [off, off + n), clamped to the buffer.
	PackedFloat32Array read(int64_t p_off, int64_t p_n) const;
};

} // namespace godot

#endif // WF_ARENA_H
