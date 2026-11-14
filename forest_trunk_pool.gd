# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
# addons/wuifwoud/forest_trunk_pool.gd
@tool
class_name ForestTrunkPool
extends Node3D
## DYNAMIC tree collision: the forest is 300k+ MultiMesh instances; per-tree
## StaticBodies would drown the physics server, and 99.9% of them are nowhere
## near a car. A fixed POOL of cylinder shapes teleports onto the trunks
## around every vehicle instead (trees are deterministic on all peers, so the
## collisions agree in MP with ZERO sync). One StaticBody3D, `pool_size`
## CollisionShape3D children; a shape not assigned this pass is disabled.
##
## Optimised to do (almost) nothing when nothing changes:
## - MOVE GATE: no vehicle moved > move_gate_m since the last pass → skip.
## - INCREMENTAL DIFF: trunks are static, so a moving vehicle only changes
##   the boundary of its set: shapes keep their assignment (keyed by
##   quantised trunk position) and only the delta teleports.
## - HYSTERESIS: an assigned trunk survives until radius + release_slack_m,
##   so the boundary doesn't flap shapes on/off every pass.
## - NEAREST-FIRST: over budget, the closest trunks win; they are the ones
##   a car can actually hit.
## - SHARES (member_share, optional): a game ranks the group's members. A
##   PRIMARY member (unset: every member) gets everything above. A SECONDARY
##   member (AI traffic, say) gets trunks within secondary_radius_m, and only
##   the colliders no primary trunk wants: a primary trunk takes one back when
##   none is free. A NONE member (a car that cannot reach a trunk, or that
##   another peer simulates) gets nothing and never wakes the move gate.
##
## The spawner owns the trunk registry (`trunks_near`, flat [x,y,z,r] quads)
## and adds this node as a child; nothing else needs wiring.

## A member's share of the pool: member_share's answer for each member of collision_group.
enum Share { NONE, SECONDARY, PRIMARY }

## Added to the rank (squared distance) of a trunk only secondary members want: it ranks after every primary trunk.
const _SECONDARY_RANK := 1.0e9

## Colliders in the pool.
@export var pool_size: int = 128
## Trunks within this of a vehicle get a collider.
@export var radius_m: float = 45.0
## How often the pool is refreshed (s).
@export var refresh_s: float = 0.35
## A vehicle must move this far before the pool looks again.
@export var move_gate_m: float = 4.0
## An assigned trunk keeps its collider until this far past radius_m.
@export var release_slack_m: float = 6.0
## Trunks within this of a SECONDARY member get a collider (member_share), kept until this far plus release_slack_m.
@export var secondary_radius_m: float = 20.0

## ForestSpawner (has trunks_near)
var source: Node = null
## Set by the forest from its ForestConfig before the pool enters the tree: the group whose members get trunk
## colliders around them, and the trunk body's physics layer, mask and metadata.
var collision_group: StringName = &"vehicles"
## The colliders' physics layer.
var trunk_layer: int = 1
## The colliders' physics mask.
var trunk_mask: int = 1
## Metadata set on the colliders' body.
var trunk_meta: Dictionary = {}
## Each member's share of the pool: a Callable(member: Node3D) -> Share, asked for every member of collision_group on
## every pass, so keep it cheap. Unset: every member is PRIMARY.
var member_share: Callable = Callable()

var _body: StaticBody3D
var _shapes: Array[CollisionShape3D] = []
var _accum := 0.0
var _last_pos: Dictionary = {}     # member instance id -> [Vector2, Share] at its last move
var _assigned: Dictionary = {}     # trunk key (Vector2i) -> shape index
var _free_shapes: Array[int] = []

func _ready() -> void:
	_body = StaticBody3D.new()
	_body.name = "TreeTrunks"
	_body.collision_layer = trunk_layer
	_body.collision_mask = trunk_mask
	for k in trunk_meta:
		_body.set_meta(StringName(k), trunk_meta[k])   # the game's: rotor blades strike trunks as wood
	add_child(_body)
	for i in range(pool_size):
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = 0.25
		cyl.height = 5.0
		cs.shape = cyl
		cs.disabled = true
		_body.add_child(cs)
		_shapes.append(cs)
		_free_shapes.append(i)

func _physics_process(dt: float) -> void:
	if Engine.is_editor_hint() or source == null:
		return
	_accum += dt
	if _accum < refresh_s:
		return
	_accum = 0.0
	_refresh()

static func _tkey(x: float, z: float) -> Vector2i:
	return Vector2i(int(roundf(x * 2.0)), int(roundf(z * 2.0)))

func _refresh() -> void:
	if not is_inside_tree() or source == null:
		return
	# MOVE GATE: parked convoy = zero work. Also fires on members appearing,
	# vanishing (the id-set changes) or changing share. A NONE member is no
	# member here.
	var primary: Array = []
	var secondary: Array = []
	var moved := false
	var seen_ids: Dictionary = {}
	var ranked := member_share.is_valid()
	for v in get_tree().get_nodes_in_group(collision_group):
		if not (v is Node3D) or not is_instance_valid(v):
			continue
		var share: int = int(member_share.call(v)) if ranked else Share.PRIMARY
		if share == Share.PRIMARY:
			primary.append(v)
		elif share == Share.SECONDARY:
			secondary.append(v)
		else:
			continue
		var id: int = v.get_instance_id()
		seen_ids[id] = true
		var p3: Vector3 = (v as Node3D).global_position
		var p2 := Vector2(p3.x, p3.z)
		var lp = _last_pos.get(id)
		if lp == null or int(lp[1]) != share or (lp[0] as Vector2).distance_to(p2) > move_gate_m:
			moved = true
			_last_pos[id] = [p2, share]
	if _last_pos.size() != seen_ids.size():
		moved = true
		for id in _last_pos.keys():
			if not seen_ids.has(id):
				_last_pos.erase(id)
	if not moved and not _assigned.is_empty():
		return
	if primary.is_empty() and secondary.is_empty():
		_release_all()
		return
	# Desired set: nearest-first within radius of any member, every primary
	# trunk ahead of every trunk only secondary members want.
	var cand: Dictionary = {}   # key -> [rank, x, y, z, r]
	_want(cand, primary, radius_m, 0.0)
	_want(cand, secondary, secondary_radius_m, _SECONDARY_RANK)
	# HYSTERESIS + stale RELEASE: keep current assignments while a member
	# stays within its radius + slack; free the rest. Note the colliders only
	# secondary members hold: primary trunks may take them back below.
	var slack2 := (radius_m + release_slack_m) * (radius_m + release_slack_m)
	var slack2_s := (secondary_radius_m + release_slack_m) * (secondary_radius_m + release_slack_m)
	var lent: Array = []   # [rank, key]
	for k in _assigned.keys():
		var c = cand.get(k)
		if c != null:
			if float(c[0]) >= _SECONDARY_RANK:
				lent.append([float(c[0]), k])
			continue
		var sp: Vector3 = _shapes[_assigned[k]].global_position
		var at := Vector2(sp.x, sp.z)
		if _any_within(primary, at, slack2):
			continue
		if _any_within(secondary, at, slack2_s):
			lent.append([INF, k])   # past every wanted trunk: the first to go
			continue
		_release(k)
	# New trunks, nearest first, into freed shapes (none free and none lent:
	# nothing to place, so no list to build and sort).
	if _free_shapes.is_empty() and lent.is_empty():
		return
	var fresh: Array = []
	for k in cand:
		if not _assigned.has(k):
			fresh.append([cand[k], k])
	if not lent.is_empty():
		_take_back(fresh, lent)
	if _free_shapes.is_empty():
		return
	fresh.sort_custom(func(a, b): return float((a[0] as Array)[0]) < float((b[0] as Array)[0]))
	for entry in fresh:
		if _free_shapes.is_empty():
			break
		var rec: Array = entry[0]
		var idx2: int = _free_shapes.pop_back()
		var cs := _shapes[idx2]
		(cs.shape as CylinderShape3D).radius = float(rec[4])
		cs.global_position = Vector3(float(rec[1]), float(rec[2]) + 2.2, float(rec[3]))
		cs.disabled = false
		_assigned[entry[1]] = idx2

## The trunks within `r` of each of `members` into `cand` (key -> [rank, x, y, z, r]), ranked by squared distance
## plus `bias`; a trunk several members want keeps its lowest rank.
func _want(cand: Dictionary, members: Array, r: float, bias: float) -> void:
	for v in members:
		var p3: Vector3 = (v as Node3D).global_position
		var p2 := Vector2(p3.x, p3.z)
		var flat: PackedFloat32Array = source.trunks_near(p2, r)
		for i in range(0, flat.size(), 4):
			var k := _tkey(flat[i], flat[i + 2])
			var rank := Vector2(flat[i], flat[i + 2]).distance_squared_to(p2) + bias
			var prev = cand.get(k)
			if prev == null or rank < float((prev as Array)[0]):
				cand[k] = [rank, flat[i], flat[i + 1], flat[i + 2], flat[i + 3]]

## Primary trunks waiting in `fresh` take back `lent` colliders ([rank, key], the ones only secondary members hold),
## the farthest first, when too few colliders are free: only as many as they need, so none goes back to a secondary
## trunk.
func _take_back(fresh: Array, lent: Array) -> void:
	var want := 0
	for entry in fresh:
		if float((entry[0] as Array)[0]) < _SECONDARY_RANK:
			want += 1
	if want <= _free_shapes.size():
		return
	lent.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	for e in lent:
		if _free_shapes.size() >= want:
			break
		_release(e[1])

## Is any of `members` within sqrt(`r2`) of `at` (ground plane)?
static func _any_within(members: Array, at: Vector2, r2: float) -> bool:
	for v in members:
		var vp: Vector3 = (v as Node3D).global_position
		if at.distance_squared_to(Vector2(vp.x, vp.z)) <= r2:
			return true
	return false

## Trunk `k`'s collider back to the free list.
func _release(k: Vector2i) -> void:
	var idx: int = _assigned[k]
	_shapes[idx].disabled = true
	_free_shapes.append(idx)
	_assigned.erase(k)

func _release_all() -> void:
	for k in _assigned.keys():
		var idx: int = _assigned[k]
		_shapes[idx].disabled = true
		_free_shapes.append(idx)
	_assigned.clear()
