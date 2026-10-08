// Copyright (c) 2026 Digitzone
// SPDX-License-Identifier: MIT
#include "arena/wf_arena.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>

using namespace godot;
using wf::BLOCK_SPLIT;
using wf::CLUSTER_FLOATS;

void wf::walk_clusters(const float *p_buf, int64_t p_n, int64_t p_stride, double p_reach, std::vector<float> &r_out) {
	r_out.clear();
	for (int64_t c = 0; c < p_n; c += BLOCK_SPLIT) {
		const int64_t cn = std::min<int64_t>(BLOCK_SPLIT, p_n - c);
		// GDScript's Vector3(1e18, ...) and minf / maxf: `a < b ? a : b`, `a > b ? a : b`, in that operand order (it
		// decides which zero a -0.0 / 0.0 tie keeps, and so the bytes).
		float lo[3] = { 1e18f, 1e18f, 1e18f };
		float hi[3] = { -1e18f, -1e18f, -1e18f };
		for (int64_t j = 0; j < cn; j++) {
			const float *q = p_buf + (c + j) * p_stride;
			for (int k = 0; k < 3; k++) {
				const float v = q[3 + 4 * k];
				lo[k] = lo[k] < v ? lo[k] : v;
				hi[k] = hi[k] > v ? hi[k] : v;
			}
		}
		if (lo[0] > hi[0]) {
			lo[0] = lo[1] = lo[2] = 0.0f;
			hi[0] = hi[1] = hi[2] = 0.0f;
		}
		const float dx = hi[0] - lo[0];
		const float dy = hi[1] - lo[1];
		const float dz = hi[2] - lo[2];
		// Vector3::length(): x² + y² + z² summed left to right in float, sqrtf.
		const float len = std::sqrt(dx * dx + dy * dy + dz * dz);
		r_out.push_back((lo[0] + hi[0]) * 0.5f);
		r_out.push_back((lo[1] + hi[1]) * 0.5f);
		r_out.push_back((lo[2] + hi[2]) * 0.5f);
		r_out.push_back((float)((double)len * 0.5 + p_reach));
		r_out.push_back((float)c);
		r_out.push_back((float)cn);
	}
}

void WfArena::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add", "buf", "n", "clusters", "reach"), &WfArena::add);
	ClassDB::bind_method(D_METHOD("release", "off", "n"), &WfArena::release);
	ClassDB::bind_method(D_METHOD("write_at", "off", "n", "rows", "centre", "radius"), &WfArena::write_at);
	ClassDB::bind_method(D_METHOD("take_uploads", "max_ranges"), &WfArena::take_uploads);
	ClassDB::bind_method(D_METHOD("reserve", "n"), &WfArena::reserve);
	ClassDB::bind_method(D_METHOD("stats"), &WfArena::stats);
	ClassDB::bind_method(D_METHOD("read", "off", "n"), &WfArena::read);
}

bool WfArena::setup(int64_t p_stride, int64_t p_fixed_cap) {
	if (p_stride < 12 || p_stride > 64 || p_fixed_cap < 0 || p_fixed_cap > MAX_INSTANCES) {
		return false;
	}
	stride_ = p_stride;
	fixed_ = p_fixed_cap > 0;
	cap_ = fixed_ ? p_fixed_cap : 0;
	n_ = cap_;
	buf_.assign((size_t)(cap_ * stride_), 0.0f);
	realloc_ = true;
	return true;
}

PackedByteArray WfArena::bytes_of(const float *p_src, int64_t p_floats) {
	PackedByteArray out;
	if (p_floats <= 0) {
		return out;
	}
	out.resize(p_floats * (int64_t)sizeof(float));
	std::memcpy(out.ptrw(), p_src, (size_t)p_floats * sizeof(float));
	return out;
}

void WfArena::block_set(int64_t p_key, float p_cx, float p_cy, float p_cz, float p_r, int64_t p_off, int64_t p_n) {
	int64_t row = -1;
	auto it = bidx_.find(p_key);
	if (it != bidx_.end()) {
		row = it->second;
	} else {
		if (!bfree_.empty()) {
			row = bfree_.back();
			bfree_.pop_back();
		} else {
			row = bhigh_++;
		}
		bidx_[p_key] = row;
	}
	if (bhigh_ > bcap_) {
		int64_t cap = std::max(MIN_BLOCKS, bcap_);
		while (cap < bhigh_) {
			cap *= 2;
		}
		btab_.resize((size_t)(cap * BLOCK_FLOATS), 0.0f);
		bdirty_.resize((size_t)cap, 0);
		bcap_ = cap;
		// The block buffer changes size: its uniform set is stale and the whole table goes up again.
		realloc_ = true;
	}
	float *b = btab_.data() + row * BLOCK_FLOATS;
	b[0] = p_cx;
	b[1] = p_cy;
	b[2] = p_cz;
	b[3] = p_r;
	b[4] = (float)p_off;
	b[5] = (float)p_n;
	if (!bdirty_[(size_t)row]) {
		bdirty_[(size_t)row] = 1;
		bdirty_n_++;
	}
}

bool WfArena::block_clear(int64_t p_key) {
	auto it = bidx_.find(p_key);
	if (it == bidx_.end()) {
		return false;
	}
	const int64_t row = it->second;
	bidx_.erase(it);
	bfree_.push_back(row);
	btab_[(size_t)(row * BLOCK_FLOATS + 5)] = 0.0f; // count 0: the shader skips the row
	if (!bdirty_[(size_t)row]) {
		bdirty_[(size_t)row] = 1;
		bdirty_n_++;
	}
	return true;
}

// Consecutive plain ranges merge (the forest appends blocks back to back); a payload range never merges, and nothing
// merges into one, so the upload order within a frame is the list order.
void WfArena::mark_dirty(int64_t p_off, int64_t p_n) {
	if (!dirty_.empty()) {
		Range &last = dirty_.back();
		if (!last.payload && last.off + last.n == p_off) {
			last.n += p_n;
			return;
		}
	}
	Range r;
	r.off = p_off;
	r.n = p_n;
	dirty_.push_back(r);
}

void WfArena::mark_payload(int64_t p_off, int64_t p_n, const PackedByteArray &p_bytes) {
	Range r;
	r.off = p_off;
	r.n = p_n;
	r.payload = true;
	r.bytes = p_bytes;
	dirty_.push_back(r);
}

Dictionary WfArena::add(const PackedFloat32Array &p_buf, int64_t p_n, const PackedFloat32Array &p_clusters,
		double p_reach) {
	Dictionary h;
	if (p_n <= 0 || fixed_ || p_buf.size() < p_n * stride_) {
		return h;
	}
	int64_t off = -1;
	for (size_t i = 0; i < free_.size(); i++) {
		if (free_[i].second >= p_n) {
			off = free_[i].first;
			if (free_[i].second > p_n) {
				free_[i] = { free_[i].first + p_n, free_[i].second - p_n };
			} else {
				free_.erase(free_.begin() + (int64_t)i);
			}
			break;
		}
	}
	if (off < 0) {
		const int64_t need = n_ + p_n;
		if (need > MAX_INSTANCES) {
			return h;
		}
		off = n_;
		if (need > cap_) {
			int64_t cap = std::max(MIN_CAP, cap_);
			while (cap < need) {
				// DOUBLING ONLY WHILE SMALL: past GROW_LINEAR_AT a quarter, rounded up to 4096 instances.
				cap = cap < GROW_LINEAR_AT ? cap * 2 : (int64_t)std::ceil((double)need * 1.25 / 4096.0) * 4096;
			}
			cap_ = cap;
			realloc_ = true;
			buf_.reserve((size_t)(cap_ * stride_));
		}
		n_ = need;
		buf_.resize((size_t)(n_ * stride_), 0.0f);
	}
	const float *src = p_buf.ptr();
	std::memcpy(buf_.data() + off * stride_, src, (size_t)(p_n * stride_) * sizeof(float));
	// The kernel's clusters when they are the walk's own shape (one per BLOCK_SPLIT instances, in order), else the walk.
	const int64_t want = (p_n + BLOCK_SPLIT - 1) / BLOCK_SPLIT;
	bool use = p_clusters.size() == want * CLUSTER_FLOATS;
	const float *pc = p_clusters.ptr();
	for (int64_t k = 0; use && k < want; k++) {
		const int64_t rel = k * BLOCK_SPLIT;
		const int64_t cn = std::min<int64_t>(BLOCK_SPLIT, p_n - rel);
		use = pc[k * CLUSTER_FLOATS + 4] == (float)rel && pc[k * CLUSTER_FLOATS + 5] == (float)cn;
	}
	std::vector<float> walked;
	if (use) {
		for (int64_t k = 0; k < want; k++) {
			const float *c = pc + k * CLUSTER_FLOATS;
			const int64_t rel = k * BLOCK_SPLIT;
			block_set(off + rel, c[0], c[1], c[2], (float)((double)c[3] + p_reach), off + rel, (int64_t)c[5]);
		}
	} else {
		wf::walk_clusters(src, p_n, stride_, p_reach, walked);
		for (size_t k = 0; k < walked.size(); k += CLUSTER_FLOATS) {
			const int64_t rel = (int64_t)walked[k + 4];
			block_set(off + rel, walked[k], walked[k + 1], walked[k + 2], walked[k + 3], off + rel,
					(int64_t)walked[k + 5]);
		}
	}
	mark_dirty(off, p_n);
	live_[off] = p_n;
	live_n_ += p_n;
	h["off"] = off;
	h["n"] = p_n;
	return h;
}

bool WfArena::release(int64_t p_off, int64_t p_n) {
	auto it = live_.find(p_off);
	if (it == live_.end() || it->second != p_n) {
		return false;
	}
	live_.erase(it);
	live_n_ -= p_n;
	const int64_t base = p_off * stride_;
	const int64_t end = std::min<int64_t>(base + p_n * stride_, (int64_t)buf_.size());
	// THE LIVENESS COLUMN ONLY: floats 0, 4 and 8 are the first basis column, the shader's test.
	for (int64_t i = base; i + 8 < end; i += stride_) {
		buf_[(size_t)i] = 0.0f;
		buf_[(size_t)(i + 4)] = 0.0f;
		buf_[(size_t)(i + 8)] = 0.0f;
	}
	// One block covers several clusters: their keys are exactly the strided offsets add wrote.
	for (int64_t c = 0; c < p_n; c += BLOCK_SPLIT) {
		block_clear(p_off + c);
	}
	free_.push_back({ p_off, p_n });
	mark_dirty(p_off, p_n);
	return true;
}

bool WfArena::write_at(int64_t p_off, int64_t p_n, const PackedFloat32Array &p_rows, const Vector3 &p_centre,
		double p_radius) {
	if (p_n <= 0) {
		return block_clear(p_off);
	}
	if (p_off < 0 || p_off + p_n > n_) {
		return false;
	}
	const int64_t lim = std::min<int64_t>(p_rows.size(), p_n * stride_);
	if (fixed_) {
		// The rows upload straight from the caller's array: the payload is their live prefix. No rows at all is a plain
		// range (an empty payload is no payload), which uploads what the buffer holds.
		block_set(p_off, p_centre.x, p_centre.y, p_centre.z, (float)p_radius, p_off, p_n);
		if (lim > 0) {
			mark_payload(p_off, p_n, bytes_of(p_rows.ptr(), lim));
		} else {
			mark_dirty(p_off, p_n);
		}
		return true;
	}
	if (lim > 0) {
		std::memcpy(buf_.data() + p_off * stride_, p_rows.ptr(), (size_t)lim * sizeof(float));
	}
	block_set(p_off, p_centre.x, p_centre.y, p_centre.z, (float)p_radius, p_off, p_n);
	mark_dirty(p_off, p_n);
	return true;
}

Dictionary WfArena::take_uploads(int64_t p_max_ranges) {
	const bool was = realloc_;
	if (realloc_) {
		// A realloc replaces the buffer: the whole arena is new to the GPU. Payload ranges survive it, re-appended after
		// the wholesale range: their rows were never copied in, and uploads apply in list order.
		std::deque<Range> carried;
		for (const Range &r : dirty_) {
			if (r.payload) {
				carried.push_back(r);
			}
		}
		dirty_.clear();
		Range all;
		all.off = 0;
		all.n = n_;
		dirty_.push_back(all);
		for (const Range &r : carried) {
			dirty_.push_back(r);
		}
		realloc_ = false;
	}
	Array rows;
	if (was) {
		std::fill(bdirty_.begin(), bdirty_.end(), 0);
		bdirty_n_ = 0;
		if (!btab_.empty()) {
			Array one;
			one.push_back((int64_t)0);
			one.push_back(bytes_of(btab_.data(), (int64_t)btab_.size()));
			rows.push_back(one);
		}
	} else if (bdirty_n_ > 0) {
		int64_t lo = -1;
		int64_t hi = -1;
		auto flush = [&]() {
			Array one;
			one.push_back(lo * BLOCK_FLOATS * (int64_t)sizeof(float));
			one.push_back(bytes_of(btab_.data() + lo * BLOCK_FLOATS, (hi - lo) * BLOCK_FLOATS));
			rows.push_back(one);
		};
		for (int64_t r = 0; r < bhigh_; r++) {
			if (!bdirty_[(size_t)r]) {
				continue;
			}
			bdirty_[(size_t)r] = 0;
			if (lo >= 0 && r == hi) {
				hi = r + 1;
				continue;
			}
			if (lo >= 0) {
				flush();
			}
			lo = r;
			hi = r + 1;
		}
		if (lo >= 0) {
			flush();
		}
		bdirty_n_ = 0;
	}
	Array ranges;
	const int64_t take = std::min<int64_t>((int64_t)dirty_.size(), std::max<int64_t>(p_max_ranges, 0));
	for (int64_t i = 0; i < take; i++) {
		const Range &r = dirty_.front();
		const int64_t lo = r.off;
		const int64_t hi = std::min<int64_t>(lo + r.n, n_);
		if (hi > lo) {
			Array one;
			one.push_back(lo * stride_ * (int64_t)sizeof(float));
			one.push_back(r.payload ? r.bytes : bytes_of(buf_.data() + lo * stride_, (hi - lo) * stride_));
			ranges.push_back(one);
		}
		dirty_.pop_front();
	}
	Dictionary out;
	out["ranges"] = ranges;
	out["rows"] = rows;
	out["realloc"] = was;
	out["n"] = n_;
	out["cap"] = cap_;
	out["nblocks"] = bhigh_;
	out["bcap"] = bcap_;
	out["more"] = !dirty_.empty();
	return out;
}

bool WfArena::reserve(int64_t p_n) {
	if (fixed_ || p_n <= 0 || p_n > MAX_INSTANCES) {
		return false;
	}
	bool grew = false;
	const int64_t cap = std::min<int64_t>((p_n + 4095) / 4096 * 4096, MAX_INSTANCES);
	if (cap > cap_) {
		cap_ = cap;
		buf_.reserve((size_t)(cap_ * stride_));
		grew = true;
	}
	// The rows the instances would need at today's ratio: the table doubles from MIN_BLOCKS, as block_set grows it.
	const int64_t rows = n_ > 0 ? (bhigh_ * p_n + n_ - 1) / n_ : 0;
	if (rows > bcap_) {
		int64_t bc = std::max(MIN_BLOCKS, bcap_);
		while (bc < rows) {
			bc *= 2;
		}
		btab_.resize((size_t)(bc * BLOCK_FLOATS), 0.0f);
		bdirty_.resize((size_t)bc, 0);
		bcap_ = bc;
		grew = true;
	}
	if (grew) {
		realloc_ = true;
	}
	return grew;
}

Dictionary WfArena::stats() const {
	Dictionary d;
	d["floats"] = (int64_t)buf_.size();
	d["reserved"] = (int64_t)buf_.capacity();
	d["n"] = n_;
	d["cap"] = cap_;
	d["bcap"] = bcap_;
	d["nblocks"] = bhigh_;
	d["free_rows"] = (int64_t)bfree_.size();
	d["free_ranges"] = (int64_t)free_.size();
	d["live"] = (int64_t)live_.size();
	d["live_n"] = live_n_;
	d["dirty"] = (int64_t)dirty_.size();
	d["fixed"] = fixed_;
	d["stride"] = stride_;
	d["realloc"] = realloc_;
	return d;
}

PackedFloat32Array WfArena::read(int64_t p_off, int64_t p_n) const {
	PackedFloat32Array out;
	const int64_t lo = std::max<int64_t>(p_off, 0) * stride_;
	const int64_t hi = std::min<int64_t>((p_off + std::max<int64_t>(p_n, 0)) * stride_, (int64_t)buf_.size());
	if (hi > lo) {
		out.resize(hi - lo);
		std::memcpy(out.ptrw(), buf_.data() + lo, (size_t)(hi - lo) * sizeof(float));
	}
	return out;
}
