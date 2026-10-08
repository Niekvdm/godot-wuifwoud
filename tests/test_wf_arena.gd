# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The native arena: WfArena on its own: first fit and append, growth and the realloc flag,
## a recycled offset gets exactly the bytes, a release zeroes exactly the liveness columns of its range and clears its
## rows, uploads merge adjacent ranges and stop at the limit (the rest queued), payload ranges survive a realloc in order,
## block rows reused after a release, refusals change nothing; and through ForestIndirect: the uploads the GDScript arena
## sent for the same sequence of adds and releases, byte for byte (pinned by their
## hashes), a handle from before a clear_all frees nothing.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const NativeRes := preload("res://addons/wuifwoud/forest_native.gd")
const Ind := preload("res://addons/wuifwoud/forest_indirect.gd")
const STRIDE := 16
## The native arena's uploads for the sequence below (SHA-256 over every frame's bytes): the GDScript arena sent exactly
## these (the two were compared frame by frame).
const UPLOADS_SHA := "800b5ba79a58e8a1e7535a1168ef6871fa324d9bb769edbd0ce7d3db0d0407d5"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## n instances whose floats are their own index pattern (instance i, float f: base + i * 16 + f), origins at floats 3, 7
## and 11 spread over ground, so every byte says where it came from.
static func _buf(n: int, base: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(n * STRIDE)
	for i in n:
		for f in STRIDE:
			b[i * STRIDE + f] = base + float(i * STRIDE + f)
		b[i * STRIDE + 3] = base + float(i % 23) * 3.0
		b[i * STRIDE + 7] = 5.0 + float(i % 5)
		b[i * STRIDE + 11] = -base + float(i / 23) * 3.0
	return b


static func _floats(ups: Array, i: int) -> PackedFloat32Array:
	return ((ups[i] as Array)[1] as PackedByteArray).to_float32_array()


## A ForestIndirect with one planted species "0/T": no RenderingDevice needed, nothing drawn: the CPU side update()
## sends, through the same functions.
static func _planted() -> Node3D:
	var ind: Node3D = Ind.new()
	ind._ok = true
	var sp := {"key": "0/T", "name": "T", "tier": 0, "stride": STRIDE, "radius": 2.0,
		"meshes": [null], "bins": [{}], "surfaces": 1, "cast_mask": 0, "colors": false, "custom": true, "gi": true,
		"material": RID(), "thin_start": 0.0, "thin_max": 0.0}
	sp.merge(ind._arena_state(STRIDE))
	ind._sp["0/T"] = sp
	return ind


## One frame's uploads as bytes, field by field (the dictionaries' key order differs between the two arenas).
static func _frame(ind: Node3D) -> PackedByteArray:
	var a: Dictionary = ind._take(ind._sp["0/T"])
	return var_to_bytes([a["ranges"], a["rows"], a["realloc"], a["n"], a["cap"], a["nblocks"], a["bcap"], a["more"]])


static func run() -> Dictionary:
	var r := {"name": "wf_arena", "passed": 0, "failed": 0, "details": []}
	var core = NativeRes.core()
	_chk(r, "the native core is built (if not: build it, see the addon's README)", core != null)
	if core == null:
		return r
	_chk(r, "make_arena: a growing and a fixed arena; a stride out of range none",
		core.make_arena(16, 0) != null and core.make_arena(20, 4096) != null and core.make_arena(3, 0) == null)

	# ── first fit and append ──
	var a = core.make_arena(STRIDE, 0)
	var h1: Dictionary = a.add(_buf(300, 1000.0), 300, PackedFloat32Array(), 3.0)
	var h2: Dictionary = a.add(_buf(200, 2000.0), 200, PackedFloat32Array(), 3.0)
	var rel1: bool = a.release(0, 300)
	var h3: Dictionary = a.add(_buf(100, 3000.0), 100, PackedFloat32Array(), 3.0)   # first fit: 0, leaves [100, 200]
	var h4: Dictionary = a.add(_buf(250, 4000.0), 250, PackedFloat32Array(), 3.0)   # 200 too small: appended at 500
	var h5: Dictionary = a.add(_buf(200, 5000.0), 200, PackedFloat32Array(), 3.0)   # exact fit at 100
	_chk(r, "first fit over the free list, else appended (%s)" % str([h1, h2, h3, h4, h5]),
		rel1 and int(h1["off"]) == 0 and int(h2["off"]) == 300 and int(h3["off"]) == 0 and int(h4["off"]) == 500
		and int(h5["off"]) == 100 and int(a.stats()["free_ranges"]) == 0 and int(a.stats()["n"]) == 750)
	_chk(r, "a recycled offset gets exactly the bytes (100 at 0, 200 at 100 inside a freed 300)",
		a.read(0, 100) == _buf(100, 3000.0) and a.read(100, 200) == _buf(200, 5000.0) and a.read(300, 200) == _buf(200, 2000.0))

	# ── growth and the realloc flag ──
	var g = core.make_arena(STRIDE, 0)
	var t0: Dictionary = g.take_uploads(96)                          # nothing yet: realloc, nothing to send
	g.add(_buf(10, 1.0), 10, PackedFloat32Array(), 1.0)
	var t1: Dictionary = g.take_uploads(96)
	g.add(_buf(10, 2.0), 10, PackedFloat32Array(), 1.0)
	var t2: Dictionary = g.take_uploads(96)
	g.add(_buf(2100, 3.0), 2100, PackedFloat32Array(), 1.0)          # past 2048: doubles
	var t3: Dictionary = g.take_uploads(96)
	g.add(_buf(40000, 4.0), 40000, PackedFloat32Array(), 1.0)        # past 32768 by doubling: then a quarter, to 4096s
	var cap4 := int(g.stats()["cap"])
	_chk(r, "growth: 2048 at the first block, doubling past it, then a quarter rounded to 4096; each growth a realloc (%d %d %d %d)" % [
		int(t1["cap"]), int(t2["cap"]), int(t3["cap"]), cap4],
		bool(t0["realloc"]) and int(t1["cap"]) == 2048 and bool(t1["realloc"]) and not bool(t2["realloc"])
		and int(t3["cap"]) == 4096 and bool(t3["realloc"]) and cap4 == int(ceil(42120.0 * 1.25 / 4096.0)) * 4096)

	# ── a release zeroes exactly its liveness columns and clears its rows ──
	var z = core.make_arena(STRIDE, 0)
	z.add(_buf(100, 10.0), 100, PackedFloat32Array(), 1.0)
	var mid: Dictionary = z.add(_buf(600, 20.0), 600, PackedFloat32Array(), 1.0)   # rows 1, 2, 3
	z.add(_buf(100, 30.0), 100, PackedFloat32Array(), 1.0)
	z.take_uploads(96)
	z.release(int(mid["off"]), 600)
	var zt: Dictionary = z.take_uploads(96)
	var got: PackedFloat32Array = z.read(100, 600)
	var want := _buf(600, 20.0)
	var only_live := true
	for i in 600:
		for f in STRIDE:
			var v: float = got[i * STRIDE + f]
			if (f == 0 or f == 4 or f == 8) and v != 0.0:
				only_live = false
			elif f != 0 and f != 4 and f != 8 and v != want[i * STRIDE + f]:
				only_live = false
	var rows_ok := (zt["rows"] as Array).size() == 1 and int((zt["rows"][0] as Array)[0]) == 32
	var rf: PackedFloat32Array = _floats(zt["rows"], 0)
	rows_ok = rows_ok and rf.size() == 24 and rf[5] == 0.0 and rf[13] == 0.0 and rf[21] == 0.0
	_chk(r, "a release zeroes floats 0, 4 and 8 of each of its instances and nothing else; its rows go to count 0",
		only_live and rows_ok and z.read(0, 100) == _buf(100, 10.0) and z.read(700, 100) == _buf(100, 30.0)
		and (zt["ranges"] as Array).size() == 1 and int((zt["ranges"][0] as Array)[0]) == 100 * STRIDE * 4)
	var reuse: Dictionary = z.add(_buf(100, 40.0), 100, PackedFloat32Array(), 1.0)
	var rt: Dictionary = z.take_uploads(96)
	_chk(r, "block rows reused after a release, the last freed first (row %d)" % (int((rt["rows"][0] as Array)[0]) / 32),
		int(reuse["off"]) == 100 and int((rt["rows"][0] as Array)[0]) == 3 * 32)

	# ── uploads merge adjacent ranges and stop at the limit ──
	var u = core.make_arena(STRIDE, 0)
	u.take_uploads(96)
	for k in 5:
		u.add(_buf(10, float(k)), 10, PackedFloat32Array(), 1.0)       # back to back: one range
	var ua: Dictionary = u.take_uploads(96)
	for k in 5:
		u.release(k * 10, 10)                                          # a range each, adjacent: they merge too
	u.add(_buf(10, 9.0), 10, PackedFloat32Array(), 1.0)                # first fit: 0, a range of its own
	var p1: Dictionary = u.take_uploads(1)
	var p2: Dictionary = u.take_uploads(1)
	var p3: Dictionary = u.take_uploads(1)
	_chk(r, "uploads: adjacent ranges merged, at most max_ranges a frame, the rest queued (%d; %d %s, %d %s, %d %s)" % [
		(ua["ranges"] as Array).size(), (p1["ranges"] as Array).size(), str(p1["more"]), (p2["ranges"] as Array).size(),
		str(p2["more"]), (p3["ranges"] as Array).size(), str(p3["more"])],
		(ua["ranges"] as Array).size() == 1 and _floats(ua["ranges"], 0).size() == 50 * STRIDE
		and (p1["ranges"] as Array).size() == 1 and bool(p1["more"]) and (p2["ranges"] as Array).size() == 1
		and not bool(p2["more"]) and (p3["ranges"] as Array).is_empty() and not bool(p3["more"]))

	# ── payload ranges survive a realloc, in order ──
	var f = core.make_arena(STRIDE, 4096)
	var rows_a := _buf(3, 70.0)
	var rows_b := _buf(2, 80.0)
	f.write_at(10, 3, rows_a, Vector3(1, 2, 3), 4.0)
	f.write_at(500, 2, rows_b, Vector3(5, 6, 7), 8.0)
	var ft: Dictionary = f.take_uploads(96)
	var fr: Array = ft["ranges"]
	_chk(r, "a fixed arena's first frame: the whole buffer, then each payload in order, as it came (%d ranges)" % fr.size(),
		bool(ft["realloc"]) and fr.size() == 3 and int((fr[0] as Array)[0]) == 0
		and _floats(fr, 0).size() == 4096 * STRIDE and int((fr[1] as Array)[0]) == 10 * STRIDE * 4
		and _floats(fr, 1) == rows_a and int((fr[2] as Array)[0]) == 500 * STRIDE * 4 and _floats(fr, 2) == rows_b
		and f.read(10, 3) != rows_a)

	# ── refusals change nothing ──
	var q = core.make_arena(STRIDE, 0)
	q.add(_buf(10, 1.0), 10, PackedFloat32Array(), 1.0)
	var before: Dictionary = q.stats()
	var short: Dictionary = q.add(_buf(5, 1.0), 10, PackedFloat32Array(), 1.0)
	var zero: Dictionary = q.add(_buf(5, 1.0), 0, PackedFloat32Array(), 1.0)
	var fixed_add: Dictionary = f.add(_buf(5, 1.0), 5, PackedFloat32Array(), 1.0)
	var stale: bool = q.release(3, 7)
	q.release(0, 10)
	var twice: bool = q.release(0, 10)
	_chk(r, "refused, nothing changed: a buffer shorter than n, n of 0, an add to a fixed arena, a release of what was never handed out or twice",
		short.is_empty() and zero.is_empty() and fixed_add.is_empty() and not stale and not twice
		and int(before["n"]) == 10 and int(q.stats()["n"]) == 10 and int(q.stats()["free_ranges"]) == 1)

	# ── through ForestIndirect: the GDScript arena's bytes, the same sequence ──
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5743
	var ni: Node3D = _planted()
	var nh: Array = []
	var frames := 0
	var sha := HashingContext.new()
	sha.start(HashingContext.HASH_SHA256)
	var most := 0
	for step in 600:
		if step == 300:
			# A burst: far more ranges dirty than one frame sends (UPLOADS_PER_FRAME), drained over frames.
			for _k in 160:
				var bb := _buf(3, float(_k))
				nh.append(ni.add_block("T", bb, 3, 0, {}))
			for _k in 160:
				var kk := rng.randi_range(0, nh.size() - 1)
				ni.free_block(nh[kk])
				nh.remove_at(kk)
			most = maxi(most, (ni._sp["0/T"]["arena"].stats()["dirty"] as int))
		var roll := rng.randi_range(0, 99)
		if roll < 55 or nh.is_empty():
			var n := rng.randi_range(1, 1300) if roll % 7 != 0 else rng.randi_range(2000, 9000)
			var b := _buf(n, rng.randf_range(-3000.0, 3000.0))
			# The kernel's clusters for the native side (radius without the reach), none for the GDScript (its walk).
			var plan := {"clusters": core.plan_walk(b, n, STRIDE, 0.0)} if roll % 3 != 0 else {}
			nh.append(ni.add_block("T", b, n, 0, plan))
		elif roll < 90:
			var k := rng.randi_range(0, nh.size() - 1)
			ni.free_block(nh[k])
			nh.remove_at(k)
		else:
			frames += 1
			sha.update(_frame(ni))
	for _f in 40:
		frames += 1
		sha.update(_frame(ni))
	var digest := sha.finish().hex_encode()
	_chk(r, "600 adds and releases, a burst of %d dirty ranges drained over frames among them: the GDScript arena's bytes (%d frames; sha256 %s)" % [
		most, frames, digest.left(12)], frames > 40 and most > Ind.UPLOADS_PER_FRAME and digest == UPLOADS_SHA)
	ni.free()

	# ── reserve (a card arena pre-sized when a fill ends, so a drive never forces a regrow) ──
	var rv = core.make_arena(STRIDE, 0)
	rv.add(_buf(100, 1.0), 100, PackedFloat32Array(), 1.0)
	rv.take_uploads(96)
	var res_grew: bool = rv.reserve(5000)
	var res_t: Dictionary = rv.take_uploads(96)
	var res_have: bool = rv.reserve(6000)                          # 6000 rounds to 8192: already there
	var res_fixed: bool = core.make_arena(STRIDE, 4096).reserve(9000)
	var res_big: bool = rv.reserve(1 << 25)
	# The CPU buffer reserves the capacity too: an append within it never moves (copies) the whole buffer: 2.5 ms for a
	# card arena of 10 MB, measured.
	_chk(r, "reserve: the capacity rounded up to 4096 instances (the CPU buffer's too), and a realloc that sends the whole arena; a capacity it has, a fixed arena or one past the limit, refused (%d)" % int(rv.stats()["cap"]),
		res_grew and int(rv.stats()["cap"]) == 8192 and bool(res_t["realloc"]) and int(res_t["cap"]) == 8192
		and (res_t["ranges"] as Array).size() == 1 and _floats(res_t["ranges"], 0) == _buf(100, 1.0)
		and not res_have and not res_fixed and not res_big and int(rv.stats()["n"]) == 100
		and int(rv.stats()["reserved"]) >= 8192 * STRIDE)
	# The block table too: a regrow of the rows rebuilds the GPU side the same way (rows in proportion to the instances).
	var rb = core.make_arena(STRIDE, 0)
	for _k in 300:
		rb.add(_buf(10, 1.0), 10, PackedFloat32Array(), 1.0)       # 300 blocks, a row each: 512 rows
	rb.take_uploads(96)
	var rows_grew: bool = rb.reserve(9000)
	var rows_t: Dictionary = rb.take_uploads(96)
	_chk(r, "reserve: the block table in proportion: 300 rows for 3000 instances, 900 for 9000: 1024 rows (%d), sent whole" % int(rb.stats()["bcap"]),
		rows_grew and int(rb.stats()["bcap"]) == 1024 and int(rb.stats()["cap"]) == 12288 and bool(rows_t["realloc"])
		and int(rows_t["bcap"]) == 1024 and (rows_t["rows"] as Array).size() == 1
		and ((rows_t["rows"][0] as Array)[1] as PackedByteArray).size() == 1024 * 32)
	var ti: Node3D = _planted()
	var csp := {"key": "1/C", "name": "C", "tier": 1, "stride": STRIDE, "radius": 2.0, "meshes": [null],
		"bins": [{}], "surfaces": 1, "cast_mask": 0, "colors": true, "custom": false, "gi": false, "material": RID(),
		"thin_start": 0.0, "thin_max": 0.0}
	csp.merge(ti._arena_state(STRIDE))
	ti._sp["1/C"] = csp
	ti.add_block("T", _buf(1000, 1.0), 1000)
	ti.add_block("C", _buf(3000, 2.0), 3000, Ind.TIER_CARD)
	# A released block leaves its range behind (the arena's high-water stays 6000): the reservation is of what LIVES;
	# reserving the high-water compounded at every fill (a teleport doubled the card arenas: 122 → 224 MB, measured).
	ti.free_block(ti.add_block("C", _buf(3000, 3.0), 3000, Ind.TIER_CARD))
	ti._take(ti._sp["0/T"])
	ti._take(ti._sp["1/C"])
	ti._deltas.clear()
	ti.reserve_tier(Ind.TIER_CARD, 3.0)
	var ccap := int(ti._sp["1/C"]["arena"].stats()["cap"])
	var mcap := int(ti._sp["0/T"]["arena"].stats()["cap"])
	var cdelta: bool = ti._deltas.has("1/C") and not ti._deltas.has("0/T")
	ti.free()
	# A mesh-tier arena starts at MESH_MIN_CAP (no mesh arena regrew past 8192 on a drive into a forest,
	# and a regrow rebuilds every LOD band's MultiMesh in one frame, 2-5 ms); a card arena starts small (reserved 3x when
	# a fill ends).
	var mi: Node3D = Ind.new()
	mi._ok = true
	var m_sp: Dictionary = mi._species("WfArenaNoMesh", Ind.TIER_MESH)
	var c_sp: Dictionary = mi._species("WfArenaNoMesh", Ind.TIER_CARD)
	var m_cap := int(m_sp["arena"].stats()["cap"])
	var c_cap := int(c_sp["arena"].stats()["cap"])
	mi.free()
	_chk(r, "a mesh-tier arena starts at %d instances, a card arena small (%d, %d)" % [Ind.MESH_MIN_CAP, m_cap, c_cap],
		Ind.MESH_MIN_CAP == 8192 and m_cap == 8192 and c_cap == 0)
	# The pacing: while driving at most `realloc_limit` arenas rebuild their GPU side a frame; the ring
	# can meet a dozen species in one step, each a mesh arena of MESH_MIN_CAP (22 ms in one frame, measured); the rest wait
	# for the next frames. A fill's end lifts it once (realloc_free_once): the reserve's rebuilds land inside the fill.
	var pi: Node3D = _planted()
	pi._live = true
	for k in ["0/A", "0/B", "0/C"]:
		var ps := {"key": k, "name": k, "tier": 0, "stride": STRIDE, "radius": 2.0, "meshes": [],
			"bins": [{}], "surfaces": 1, "cast_mask": 0, "colors": false, "custom": true, "gi": true, "material": RID(),
			"thin_start": 0.0, "thin_max": 0.0}
		ps.merge(pi._arena_state(STRIDE))
		pi._sp[k] = ps
		pi._deltas[k] = true
	var pending := func() -> int:
		var c := 0
		for k in ["0/A", "0/B", "0/C"]:
			c += 1 if bool(pi._sp[k]["arena"].stats()["realloc"]) else 0
		return c
	var q0: int = pending.call()
	pi.realloc_limit = 1
	pi.update(Vector3.ZERO)
	var q1: int = pending.call()
	var carried: bool = pi._deltas.size() == 2
	pi.update(Vector3.ZERO)
	var q2: int = pending.call()
	for k in ["0/A", "0/B", "0/C"]:
		pi._sp[k]["arena"].reserve(20000)
		pi._deltas[k] = true
	pi.realloc_free_once = true
	pi.update(Vector3.ZERO)
	var q3: int = pending.call()
	var once: bool = not pi.realloc_free_once
	pi._live = false
	pi.free()
	_chk(r, "the pacing: one arena's GPU side a frame while driving, the rest carried; a fill's end lifts it once (%d %d %d %d)" % [
		q0, q1, q2, q3], q0 == 3 and q1 == 2 and carried and q2 == 1 and q3 == 0 and once)
	_chk(r, "reserve_tier: every card arena at 3x its live instances (not its high-water), rounded to 4096, its realloc sent; the mesh tier as it was (%d, %d)" % [ccap, mcap],
		ccap == 12288 and mcap == 2048 and cdelta)

	# ── a handle that outlived a clear_all frees nothing in the arena made after it ──
	var ci: Node3D = _planted()
	var old_h: Dictionary = ci.add_block("T", _buf(50, 1.0), 50)
	ci._take(ci._sp["0/T"])
	ci._sp.clear()                                               # clear_all's arena drop (no render thread here)
	ci._deltas.clear()
	var donor: Node3D = _planted()
	ci._sp["0/T"] = donor._sp["0/T"]
	donor.free()
	var new_h: Dictionary = ci.add_block("T", _buf(50, 2.0), 50)
	ci.free_block(old_h)                                         # same key, same offset, same count: another arena
	var live_after: int = int(ci._sp["0/T"]["arena"].stats()["live"])
	_chk(r, "a handle from before a clear_all frees nothing in the new arena (same key, offset and count; %d live)" % live_after,
		int(old_h["off"]) == int(new_h["off"]) and live_after == 1
		and ci._sp["0/T"]["arena"].read(0, 50) == _buf(50, 2.0))
	ci.free()
	return r
