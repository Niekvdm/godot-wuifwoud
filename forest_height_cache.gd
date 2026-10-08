# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestHeightCache
extends RefCounted

## Flat copies of Terrain3D region heightmaps, sampled without touching the terrain.
##
## ── When this is NOT worth it ──
## The region copy is expensive: get_data().to_float32_array() on a 1024x1024 RF
## heightmap is two 4 MB copies, measured at ~7 ms. It only pays for itself when
## amortised over TENS OF THOUSANDS of samples, which is why a streaming consumer keeps one
## cache alive across its whole ring rather than per cell.
##
## A per-batch copy does not work. Measured with a terrain sampler bench: 0.01x at 64
## points, still 0.09x at 1024; break-even needs ~7000 points in a single batch. For
## one-off or small-batch sampling, call Terrain3DData.get_height directly.
##
## ── Why this exists ──
## Terrain3DData.get_height() is not one lookup. It resolves the region, checks the
## control map for a hole, then bilinearly interpolates four vertices, each of
## which resolves its own region and does its own Image::get_pixelv. That is ~5
## region resolutions and 5 image fetches per call, through a Variant call from
## GDScript; a consumer calling it once per plant pays ~1300 image fetches to place one
## 8 m cell.
##
## Here a region's heightmap is copied ONCE into a PackedFloat32Array, after which
## a sample is four array indexes and a lerp. The ring only ever spans a handful of
## regions, so the copy is amortised over tens of thousands of plants.
##
## ── Why a copy and not a reference ──
## The copy is what makes off-thread placement legal. Terrain3D streams regions in
## and out on the main thread; a worker holding a live Image or region pointer can
## have it evicted mid-sample. Owning the floats outright means placement never
## touches terrain state at all, so there is nothing to race with.

## Vertices a region side (0 until configure).
var region_size: int = 0
## Metres between vertices.
var vertex_spacing: float = 1.0
var _maps := {}          # Vector2i region_loc -> PackedFloat32Array

## ── One-entry region memo ────────────────────────────────────────────────────
## An 8 m cell and a 1024 m region: a cell's ~1300 height samples all land in the
## SAME region except at a border. A dictionary lookup to resolve it would be paid
## ~1300 times per cell to answer the same question, with a Vector2i key built and
## hashed each time (measured at 1.07M _vertex calls and 0.82 s per 30 s of driving).
##
## Held in VERTEX coordinates so the hit test is four integer compares: no
## Vector2i, no floor-division, no hashing.
##
## Mutable state on a shared object is only safe because of how this class is used:
## the main thread owns the streaming cache, and every worker gets its OWN view from
## snapshot_around(). Nothing here is read from two threads. If that ever changes,
## this memo is the first thing that breaks.
var _memo_ok := false
var _memo_x0: int = 0    # region origin, vertex coords
var _memo_z0: int = 0
var _memo_arr := PackedFloat32Array()
var _order: Array[Vector2i] = []   # insertion order, for eviction
## The streaming ring spans at most a few regions; the cap only exists so a long
## drive cannot accumulate the whole island at ~4 MB per region.
var max_regions: int = 9


## The region size and vertex spacing every copy is read at; drops nothing.
func configure(p_region_size: int, p_vertex_spacing: float) -> void:
	region_size = maxi(1, p_region_size)
	vertex_spacing = maxf(0.0001, p_vertex_spacing)


## World XZ -> region grid coordinate, matching Terrain3DData::get_region_location.
func region_location(x: float, z: float) -> Vector2i:
	var span := float(region_size) * vertex_spacing
	return Vector2i(int(floor(x / span)), int(floor(z / span)))


## True when no region has been copied: the caller must fall back to the terrain
## rather than silently placing nothing.
func is_empty() -> bool:
	return _maps.is_empty()


## Whether the region at `loc` is copied.
func has_region(loc: Vector2i) -> bool:
	return _maps.has(loc)


## Install a region's heights (row-major from its corner), evicting the oldest past max_regions.
func store(loc: Vector2i, heights: PackedFloat32Array) -> void:
	if heights.size() != region_size * region_size:
		return
	# A cap of zero means "no cache", and it has to be honoured HERE. Falling into
	# the eviction loop below with a cap of zero pops the entry out of _order and
	# then declines to erase it (it is the one just inserted), so _maps keeps it and
	# grows without bound while _order sits empty. Benchmarks disable the cache this
	# way, and a silently-still-caching cache measures nothing.
	if max_regions <= 0:
		return
	if not _maps.has(loc):
		_order.append(loc)
	_maps[loc] = heights
	while _order.size() > max_regions:
		var oldest: Vector2i = _order.pop_front()
		if oldest != loc:
			_maps.erase(oldest)
	# Any change to _maps can invalidate the memo: an eviction frees the very array
	# it points at. Dropping it wholesale costs one bool on a rare call.
	_memo_ok = false


## A private view holding just the regions covering the box at (x, z) of edge
## `size`, for handing to a worker thread.
##
## Dictionaries are not safe to read while another thread mutates them, and the
## main thread evicts regions as the ring moves, so a worker must never touch the
## shared cache. This copies only the dictionary ENTRIES; the float arrays
## themselves are shared by reference (PackedFloat32Array is copy-on-write and
## nothing writes to them), so a snapshot costs a handful of pointers rather than
## the megabytes it appears to.
func snapshot_around(x: float, z: float, size: float) -> ForestHeightCache:
	var view := ForestHeightCache.new()
	view.configure(region_size, vertex_spacing)
	for corner in [Vector2(x, z), Vector2(x + size, z), Vector2(x, z + size),
			Vector2(x + size, z + size)]:
		var loc := region_location(corner.x, corner.y)
		if _maps.has(loc) and not view.has_region(loc):
			view.store(loc, _maps[loc])
	return view


## The same private view over EVERY region a rectangle overlaps, for consumers
## whose cells can be larger than a region (a 1 km impostor cell), where the four
## corners of snapshot_around would miss the regions in between.
func snapshot_rect(x0: float, z0: float, x1: float, z1: float) -> ForestHeightCache:
	var view := ForestHeightCache.new()
	view.configure(region_size, vertex_spacing)
	view.max_regions = 64        # a view never evicts; the cap belongs to the owner
	var l0 := region_location(x0, z0)
	var l1 := region_location(x1, z1)
	for lx in range(l0.x, l1.x + 1):
		for lz in range(l0.y, l1.y + 1):
			var loc := Vector2i(lx, lz)
			if _maps.has(loc):
				view.store(loc, _maps[loc])
	return view


## The regions a rectangle overlaps as a native place job takes them: [location, heights, …], the
## arrays shared, not copied (copy on write; nothing writes them); the same regions snapshot_rect would view.
func regions_rect(x0: float, z0: float, x1: float, z1: float) -> Array:
	var out := []
	var l0 := region_location(x0, z0)
	var l1 := region_location(x1, z1)
	for lx in range(l0.x, l1.x + 1):
		for lz in range(l0.y, l1.y + 1):
			var loc := Vector2i(lx, lz)
			if _maps.has(loc):
				out.append(loc)
				out.append(_maps[loc])
	return out


## Forget every copy.
func drop_all() -> void:
	_maps.clear()
	_order.clear()
	_memo_ok = false
	_memo_arr = PackedFloat32Array()


## Point the memo at the region containing this vertex. False when there is none.
func _memo_at(vx: int, vz: int) -> bool:
	var span := region_size
	if span <= 0:
		return false
	# Integer floor-division: Godot's / truncates toward zero, which folds -1 and 0
	# into the same region and mirrors the map across the origin.
	var lx := (vx - (span - 1)) / span if vx < 0 else vx / span
	var lz := (vz - (span - 1)) / span if vz < 0 else vz / span
	var arr = _maps.get(Vector2i(lx, lz))
	if arr == null:
		return false
	var a: PackedFloat32Array = arr
	if a.is_empty():
		return false
	_memo_arr = a
	_memo_x0 = lx * span
	_memo_z0 = lz * span
	_memo_ok = true
	return true


## One vertex. Out-of-cache regions return NAN so the caller can fall back to the
## terrain rather than silently placing plants at zero (sea level), which would
## carpet every unstreamed region with floating plants.
func _vertex(vx: int, vz: int) -> float:
	var span := region_size
	# An unconfigured cache has span 0, and the floor-division below is then an
	# integer divide by zero: GDScript reports it and hands back 0, so this
	# would return SEA LEVEL as a valid height instead of NAN, the exact outcome the
	# note above says must never happen, and a caller whose fallback NAN would select
	# would quietly not take it.
	if span <= 0:
		return NAN
	if not (_memo_ok and vx >= _memo_x0 and vx < _memo_x0 + span \
			and vz >= _memo_z0 and vz < _memo_z0 + span):
		if not _memo_at(vx, vz):
			return NAN
	return _memo_arr[(vz - _memo_z0) * span + (vx - _memo_x0)]


## Bilinear height at a world XZ, matching Terrain3DData::get_height's four-tap
## interpolation over vertex_spacing.
##
## Only taps that actually carry weight are required. Sitting exactly on a vertex
## at the edge of the streamed area would otherwise return NAN because a
## zero-weight neighbour in an uncached region could not be read, and get_height
## itself short-circuits to a single pixel in that case, so demanding four would be
## stricter than the function being replaced. Any tap with real weight missing
## still yields NAN: better no plant than a plant at sea level.
func height(x: float, z: float) -> float:
	var px := x / vertex_spacing
	var pz := z / vertex_spacing
	var x0 := int(floor(px))
	var z0 := int(floor(pz))
	var fx := px - float(x0)
	var fz := pz - float(z0)
	# Unrolled, and deliberately so: the obvious `for w in weights` over an array of
	# [x, z, weight] triples allocates the outer array AND one inner array per tap,
	# five heap allocations every time a plant asks where the ground is. Together
	# with the packed-array default in _vertex that was nine allocations per sample
	# in the function that exists to make sampling free.
	var w00 := (1.0 - fx) * (1.0 - fz)
	var w10 := fx * (1.0 - fz)
	var w01 := (1.0 - fx) * fz
	var w11 := fx * fz
	# ── Fast path: all four taps inside one memoised region ──
	# Four _vertex calls, each with its own floor-division and dictionary lookup,
	# collapse to one region resolution and four array indexes. The guards and the
	# accumulation ORDER are copied verbatim from the slow path below and must stay
	# that way: the zero-weight skip is what lets a sample sitting exactly on a
	# vertex survive a NAN in a corner it does not use, and a nested-lerp rewrite (the
	# obvious "tidier" bilinear) is not bit-identical to this sum.
	var span := region_size
	if span > 0:
		var covered := _memo_ok and x0 >= _memo_x0 and z0 >= _memo_z0 \
				and x0 + 1 < _memo_x0 + span and z0 + 1 < _memo_z0 + span
		if not covered:
			# Prime it. A sample straddling a region border leaves this uncovered and
			# falls through to the general path, which is exactly what it is for.
			covered = _memo_at(x0, z0) and x0 + 1 < _memo_x0 + span \
					and z0 + 1 < _memo_z0 + span
		if covered:
			var a := _memo_arr
			var base := (z0 - _memo_z0) * span + (x0 - _memo_x0)
			var facc := 0.0
			if w00 > 0.0:
				var f00 := a[base]
				if is_nan(f00):
					return NAN
				facc += f00 * w00
			if w10 > 0.0:
				var f10 := a[base + 1]
				if is_nan(f10):
					return NAN
				facc += f10 * w10
			if w01 > 0.0:
				var f01 := a[base + span]
				if is_nan(f01):
					return NAN
				facc += f01 * w01
			if w11 > 0.0:
				var f11 := a[base + span + 1]
				if is_nan(f11):
					return NAN
				facc += f11 * w11
			return facc
	var acc := 0.0
	if w00 > 0.0:
		var h := _vertex(x0, z0)
		if is_nan(h):
			return NAN
		acc += h * w00
	if w10 > 0.0:
		var h := _vertex(x0 + 1, z0)
		if is_nan(h):
			return NAN
		acc += h * w10
	if w01 > 0.0:
		var h := _vertex(x0, z0 + 1)
		if is_nan(h):
			return NAN
		acc += h * w01
	if w11 > 0.0:
		var h := _vertex(x0 + 1, z0 + 1)
		if is_nan(h):
			return NAN
		acc += h * w11
	return acc
