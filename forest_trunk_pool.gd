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
##
## The spawner owns the trunk registry (`trunks_near`, flat [x,y,z,r] quads)
## and adds this node as a child; nothing else needs wiring.

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

var _body: StaticBody3D
var _shapes: Array[CollisionShape3D] = []
var _accum := 0.0
var _last_pos: Dictionary = {}     # vehicle instance id -> Vector2
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
	# MOVE GATE: parked convoy = zero work. Also fires on vehicles appearing
	# or vanishing (the id-set changes).
	var vehicles: Array = []
	var moved := false
	var seen_ids: Dictionary = {}
	for v in get_tree().get_nodes_in_group(collision_group):
		if not (v is Node3D) or not is_instance_valid(v):
			continue
		vehicles.append(v)
		var id: int = v.get_instance_id()
		seen_ids[id] = true
		var p3: Vector3 = (v as Node3D).global_position
		var p2 := Vector2(p3.x, p3.z)
		var lp = _last_pos.get(id)
		if lp == null or (lp as Vector2).distance_to(p2) > move_gate_m:
			moved = true
			_last_pos[id] = p2
	if _last_pos.size() != seen_ids.size():
		moved = true
		for id in _last_pos.keys():
			if not seen_ids.has(id):
				_last_pos.erase(id)
	if not moved and not _assigned.is_empty():
		return
	if vehicles.is_empty():
		_release_all()
		return
	# Desired set: nearest-first within radius of any vehicle.
	var cand: Dictionary = {}   # key -> [d2, x, y, z, r]
	for v in vehicles:
		var p3b: Vector3 = (v as Node3D).global_position
		var p2b := Vector2(p3b.x, p3b.z)
		var flat: PackedFloat32Array = source.trunks_near(p2b, radius_m)
		for i in range(0, flat.size(), 4):
			var k := _tkey(flat[i], flat[i + 2])
			var d2 := Vector2(flat[i], flat[i + 2]).distance_squared_to(p2b)
			var prev = cand.get(k)
			if prev == null or d2 < float((prev as Array)[0]):
				cand[k] = [d2, flat[i], flat[i + 1], flat[i + 2], flat[i + 3]]
	# HYSTERESIS + stale RELEASE: keep current assignments while any vehicle
	# stays within radius + slack; free the rest.
	var slack2 := (radius_m + release_slack_m) * (radius_m + release_slack_m)
	for k in _assigned.keys():
		if cand.has(k):
			continue
		var idx: int = _assigned[k]
		var sp: Vector3 = _shapes[idx].global_position
		var keep := false
		for v in vehicles:
			var vp: Vector3 = (v as Node3D).global_position
			if Vector2(sp.x, sp.z).distance_squared_to(Vector2(vp.x, vp.z)) <= slack2:
				keep = true
				break
		if not keep:
			_shapes[idx].disabled = true
			_free_shapes.append(idx)
			_assigned.erase(k)
	# New trunks, nearest first, into freed shapes.
	var fresh: Array = []
	for k in cand:
		if not _assigned.has(k):
			fresh.append([cand[k], k])
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

func _release_all() -> void:
	for k in _assigned.keys():
		var idx: int = _assigned[k]
		_shapes[idx].disabled = true
		_free_shapes.append(idx)
	_assigned.clear()
