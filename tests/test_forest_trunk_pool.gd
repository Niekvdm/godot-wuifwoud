# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The trunk colliders (ForestTrunkPool) and their query (ForestSpawner.trunks_near). With no member_share every member
## gets the trunks within radius_m, nearest first over budget, kept to radius_m + release_slack_m, and a pass with
## nothing moved queries nothing. With one: a PRIMARY member gets exactly what it got without (an all-primary share
## matches no share through a run of moves); a SECONDARY member gets the trunks within secondary_radius_m, kept to that
## plus the slack, and only colliders no primary trunk wants (a primary trunk takes one back, the farthest first); a
## NONE member gets nothing and never wakes the move gate; a member changing share is seen without moving. The set
## the forest hands over reaches the pool. trunks_near returns what a scan of every cell returns, in the same order,
## across cell edges, west and south of the origin, and for a trunk filed just across its cell's edge.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Pool := preload("res://addons/wuifwoud/forest_trunk_pool.gd")
const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const GROUP := &"test_trunk_pool_members"


## A trunk registry with the forest's query: every trunk within r of p, flat [x, y, z, radius] quads.
class FakeSource extends Node:
	var trunks := PackedFloat32Array()
	var calls := 0

	func add(x: float, z: float = 0.0) -> void:
		trunks.append_array(PackedFloat32Array([x, 0.0, z, 0.25]))

	func trunks_near(p: Vector2, r: float) -> PackedFloat32Array:
		calls += 1
		var out := PackedFloat32Array()
		for i in range(0, trunks.size(), 4):
			if Vector2(trunks[i], trunks[i + 2]).distance_to(p) <= r:
				out.append_array(trunks.slice(i, i + 4))
		return out


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## The test's classifier: a member's `kind` meta, "ai" SECONDARY, "rails" NONE, anything else PRIMARY.
static func _share(v: Node3D) -> int:
	match String(v.get_meta(&"kind", "")):
		"ai":
			return Pool.Share.SECONDARY
		"rails":
			return Pool.Share.NONE
	return Pool.Share.PRIMARY


static func _pool(root: Node, src: FakeSource, size: int, share: Callable = Callable()) -> Node3D:
	var p = Pool.new()
	p.pool_size = size
	p.source = src
	p.collision_group = GROUP
	p.member_share = share
	root.add_child(p)
	p.set_physics_process(false)   # passes only when the test says
	return p


static func _car(root: Node, x: float, kind: String = "", z: float = 0.0) -> Node3D:
	var n := Node3D.new()
	root.add_child(n)
	n.add_to_group(GROUP)
	n.global_position = Vector3(x, 0.0, z)
	if kind != "":
		n.set_meta(&"kind", kind)
	return n


static func _put(n: Node3D, x: float, z: float = 0.0) -> void:
	n.global_position = Vector3(x, 0.0, z)


## The x of every trunk with a collider, sorted.
static func _xs(pool: Node3D) -> Array:
	var out: Array = []
	for cs in pool._shapes:
		if not (cs as CollisionShape3D).disabled:
			out.append(snappedf((cs as CollisionShape3D).global_position.x, 0.01))
	out.sort()
	return out


static func run() -> Dictionary:
	var r := {"name": "forest_trunk_pool", "passed": 0, "failed": 0, "details": []}
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node3D.new()
	tree.root.add_child(root)
	await tree.process_frame   # the root enters the tree

	# ── no member_share: every member gets radius_m, nearest first, kept to radius + slack ──
	var src := FakeSource.new()
	root.add_child(src)
	for x in [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 196.0, 171.0]:
		src.add(x)
	var p = _pool(root, src, 8)
	var a := _car(root, 0.0)
	p._refresh()
	_chk(r, "a member gets the trunks within 45 m (%s)" % str(_xs(p)), _xs(p) == [10.0, 20.0, 30.0, 40.0])
	var calls := src.calls
	p._refresh()
	_put(a, 3.0)
	p._refresh()
	_chk(r, "nothing moved, or moved under the 4 m gate: no query (%d)" % (src.calls - calls), src.calls == calls)
	_put(a, -8.0)
	p._refresh()
	_chk(r, "a trunk 48 m off (past 45, inside 45 + 6) keeps its collider (%s)" % str(_xs(p)),
		_xs(p) == [10.0, 20.0, 30.0, 40.0])
	_put(a, -13.0)
	p._refresh()
	_chk(r, "at 53 m it lets go (%s)" % str(_xs(p)), _xs(p) == [10.0, 20.0, 30.0])
	p.free()
	p = _pool(root, src, 3)
	_put(a, 0.0)
	var b := _car(root, 200.0)
	p._refresh()
	_chk(r, "over budget the trunks nearest any member win: 196 (4 m from one), 10 and 20 (from the other), not 171 (29 m) (%s)" % str(_xs(p)),
		_xs(p) == [10.0, 20.0, 196.0])
	a.free()
	b.free()
	p._refresh()
	_chk(r, "the last member gone: every collider free (%d)" % p._assigned.size(),
		p._assigned.is_empty() and _xs(p).is_empty() and p._free_shapes.size() == 3)
	p.free()

	# ── an all-primary share is no share: the same colliders through a run of moves ──
	var dense := FakeSource.new()
	root.add_child(dense)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 400:
		dense.add(rng.randf_range(-300.0, 300.0), rng.randf_range(-60.0, 60.0))
	var plain = _pool(root, dense, 24)
	var ranked = _pool(root, dense, 24, func(_v: Node3D) -> int: return Pool.Share.PRIMARY)
	var cars: Array = []
	for i in 5:
		cars.append(_car(root, rng.randf_range(-250.0, 250.0), "", rng.randf_range(-40.0, 40.0)))
	var same := true
	for step in 60:
		for c in cars:
			if rng.randf() < 0.7:
				(c as Node3D).global_position += Vector3(rng.randf_range(-12.0, 12.0), 0.0, rng.randf_range(-6.0, 6.0))
		plain._refresh()
		ranked._refresh()
		same = same and plain._assigned == ranked._assigned and plain._free_shapes == ranked._free_shapes
	_chk(r, "an all-primary member_share assigns exactly what no member_share does, over 60 passes of 5 moving members",
		same and plain._assigned.size() == 24)
	plain.free()
	ranked.free()
	for c in cars:
		(c as Node3D).free()

	# ── shares: secondary radius and slack, NONE members, primary first, the take-back ──
	var s2 := FakeSource.new()
	root.add_child(s2)
	for x in [30.0, 35.0, 40.0, 510.0, 518.0, 530.0, 801.0, 802.0, 803.0, 804.0]:
		s2.add(x)
	p = _pool(root, s2, 8, _share)
	var ai := _car(root, 500.0, "ai")
	p._refresh()
	_chk(r, "a secondary member gets the trunks within 20 m: 510 and 518, not 530 (%s)" % str(_xs(p)),
		_xs(p) == [510.0, 518.0])
	_put(ai, 493.0)
	p._refresh()
	_chk(r, "a secondary trunk 25 m off (past 20, inside 20 + 6) keeps its collider (%s)" % str(_xs(p)),
		_xs(p) == [510.0, 518.0])
	_put(ai, 488.0)
	p._refresh()
	_chk(r, "at 30 m it lets go; 510 at 22 m stays (%s)" % str(_xs(p)), _xs(p) == [510.0])
	var rails := _car(root, 800.0, "rails")
	calls = s2.calls
	p._refresh()
	_put(rails, 860.0)
	p._refresh()
	_chk(r, "a NONE member gets nothing, and neither its arrival nor a 60 m move wakes the gate (%s, %d)" % [
		str(_xs(p)), s2.calls - calls], _xs(p) == [510.0] and s2.calls == calls)
	rails.set_meta(&"kind", "ai")
	_put(rails, 800.0)
	p._refresh()
	_chk(r, "the same car made secondary gets its four trunks (%s)" % str(_xs(p)),
		_xs(p) == [510.0, 801.0, 802.0, 803.0, 804.0])
	rails.free()
	ai.free()
	p.free()

	# Primary first: a small pool; the player's three trunks are farther from it than the AI car's from the AI car.
	p = _pool(root, s2, 4, _share)
	var player := _car(root, 0.0)
	ai = _car(root, 800.0, "ai")
	p._refresh()
	_chk(r, "primary trunks before secondary ones: the player's 30, 35, 40 and the AI car's nearest, 801 (%s)" % str(_xs(p)),
		_xs(p) == [30.0, 35.0, 40.0, 801.0])
	# The take-back: the AI car holds every collider while the player is away; the player arrives.
	_put(player, -2000.0)
	p._refresh()
	var away := _xs(p)
	_put(player, 0.0)
	p._refresh()
	_chk(r, "the AI car may hold every collider while no player wants one (%s); the player arriving takes three back, the AI car's farthest first (%s)" % [
		str(away), str(_xs(p))], away == [801.0, 802.0, 803.0, 804.0] and _xs(p) == [30.0, 35.0, 40.0, 801.0])
	player.set_meta(&"kind", "ai")
	p._refresh()
	_chk(r, "a member changing share is seen without moving: the player made secondary loses its 30-40 m trunks (%s)" % str(_xs(p)),
		_xs(p) == [801.0, 802.0, 803.0, 804.0])
	player.free()
	ai.free()
	p.free()

	# ── the forest hands its share to the pool, before or after the pool exists ──
	var f = Veg.new()
	var pick := func(_v: Node3D) -> int: return Pool.Share.NONE
	f.set_trunk_share(pick)
	var fp = Pool.new()
	f._trunk_pool = fp
	f.set_trunk_share(_share)
	_chk(r, "set_trunk_share keeps the share for the pool to come and reaches a pool that exists",
		f._trunk_share.get_method() == &"_share" and fp.member_share.get_method() == &"_share")
	fp.free()
	f._trunk_pool = null

	# ── trunks_near: the cells the disc touches, same trunks and order as a scan of every cell ──
	var cells := {}
	rng.seed = 9
	for i in 3000:
		var x := rng.randf_range(-200.0, 200.0)
		var z := rng.randf_range(-200.0, 200.0)
		var k := Vector2i(int(floor(x / 64.0)), int(floor(z / 64.0)))
		var cell: PackedFloat32Array = cells.get(k, PackedFloat32Array())
		cell.append_array(PackedFloat32Array([x, 1.0, z, 0.3]))
		cells[k] = cell
	# Filed by a position just under 64 m that float32 stores as 64.0: in cell 0, sitting on cell 1's edge.
	cells[Vector2i(0, 5)] = PackedFloat32Array([64.0, 1.0, 330.0, 0.3])
	f._trunk_cells = cells
	var keys: Array = cells.keys()
	keys.sort_custom(func(m: Vector2i, n: Vector2i) -> bool: return m.y < n.y or (m.y == n.y and m.x < n.x))
	var all_same := true
	var probes := 0
	for q in [[Vector2(0.0, 0.0), 45.0], [Vector2(63.9, -0.1), 45.0], [Vector2(-130.5, 70.0), 20.0],
			[Vector2(-64.0, -64.0), 63.0], [Vector2(150.0, -190.0), 5.0], [Vector2(109.0, 330.0), 45.0]]:
		var at: Vector2 = q[0]
		var rad: float = q[1]
		var want := PackedFloat32Array()
		for k in keys:
			var cell: PackedFloat32Array = cells[k]
			for i in range(0, cell.size(), 4):
				var dx := cell[i] - at.x
				var dz := cell[i + 2] - at.y
				if dx * dx + dz * dz <= rad * rad:
					want.append_array(cell.slice(i, i + 4))
		var got: PackedFloat32Array = f.trunks_near(at, rad)
		if got != want:
			all_same = false
			r.details.append("    trunks_near(%s, %s): %d trunks, a scan of every cell %d" % [at, rad, got.size() / 4, want.size() / 4])
		probes += want.size() / 4
	_chk(r, "trunks_near returns what a scan of every cell does, in order, at 6 points (%d trunks), the edge trunk too" % probes,
		all_same and probes > 50 and f.trunks_near(Vector2(109.0, 330.0), 45.0).size() == 4)
	f.free()

	root.queue_free()
	await tree.process_frame
	return r
