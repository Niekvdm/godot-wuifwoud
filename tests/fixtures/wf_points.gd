# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Test fixture: the native kernels' packed points as the dictionaries the GDScript scatter made
## ({"p", "type", "seed", "role", "age"}; a card's "mrole"; an item's "item" and "species") and back; a place job's
## instances as {"mesh", "xf", "color", "card", "key"}; a region's heights; a spawner's native scatter or place run here,
## on the calling thread. ROLES and UNDER_TAG mirror the native core's (its wf_rules.h).

const ROLES := ["tree", "dead", "wall", "understory", "bb", "scrubline", "edge"]
## An understory bush's seed is its tree's XOR this.
const UNDER_TAG := 0x0F0F0F0F0F0F0F0F


## A native scatter's packed points as dictionaries (`tables`: the job's, naming a pinned species); an Array (the
## GDScript base's points) as it is.
static func decode(pts, tables) -> Array:
	if pts is Array:
		return pts
	var d: Dictionary = pts
	var out := []
	var pos: PackedFloat32Array = d.get("pos", PackedFloat32Array())
	var info: PackedInt32Array = d.get("info", PackedInt32Array())
	var seeds: PackedInt64Array = d.get("seed", PackedInt64Array())
	var ages: PackedFloat32Array = d.get("age", PackedFloat32Array())
	var names: PackedStringArray = tables.species_names() if tables != null else PackedStringArray()
	for i in int(d.get("n", 0)):
		var f: int = info[2 * i]
		var pt := {"p": Vector2(pos[2 * i], pos[2 * i + 1]), "type": f & 0xFF, "seed": seeds[i],
			"role": ROLES[(f >> 8) & 0xF], "age": ages[i]}
		if pt["role"] == "bb":
			pt["mrole"] = ROLES[(f >> 12) & 0xF]
		if ((f >> 16) & 1) == 1:
			var sp: int = info[2 * i + 1]
			pt["item"] = true
			pt["species"] = names[sp] if sp >= 0 and sp < names.size() else ""
		out.append(pt)
	return out


## Dictionaries ({"p", "type", "seed", "role"; optional "mrole", "age", "item", "species"}) as packed points.
static func encode(list: Array, tables) -> Dictionary:
	var pos := PackedFloat32Array()
	var info := PackedInt32Array()
	var seeds := PackedInt64Array()
	var ages := PackedFloat32Array()
	for pt in list:
		var p: Vector2 = pt["p"]
		var role := ROLES.find(str(pt.get("role", "tree")))
		var mrole := ROLES.find(str(pt.get("mrole", pt.get("role", "tree"))))
		var item := 1 if bool(pt.get("item", false)) else 0
		pos.append(p.x)
		pos.append(p.y)
		info.append(int(pt["type"]) | (role << 8) | (mrole << 12) | (item << 16))
		var sp := str(pt.get("species", ""))
		info.append(int(tables.species_index(sp)) if sp != "" else -1)
		seeds.append(int(pt["seed"]))
		ages.append(float(pt.get("age", 0.0)))
	return {"n": list.size(), "pos": pos, "info": info, "seed": seeds, "age": ages}


## A place job's instances: each mesh tier instance {"mesh", "xf", "color", "card": false, "key": its slot's
## "bx,bz/species"}, then each card {…, "card": true, "key": its card cell}.
static func instances(job: Dictionary) -> Array:
	var out := []
	var species: Dictionary = job.get("species", {})
	for skey in species:
		var slot: Dictionary = species[skey]
		_unpack(out, slot["buf"], int(slot["n"]), str(slot["mesh"]), false, skey)
	var bbs: Dictionary = job.get("bbs", {})
	for cell in bbs:
		var per: Dictionary = bbs[cell]
		for mesh_name in per:
			_unpack(out, per[mesh_name]["buf"], int(per[mesh_name]["n"]), str(mesh_name), true, cell)
	return out


static func _unpack(out: Array, buf: PackedFloat32Array, n: int, mesh_name: String, card: bool, key) -> void:
	for i in n:
		var o := i * 16
		var b := Basis(Vector3(buf[o], buf[o + 4], buf[o + 8]), Vector3(buf[o + 1], buf[o + 5], buf[o + 9]),
			Vector3(buf[o + 2], buf[o + 6], buf[o + 10]))
		out.append({"mesh": mesh_name, "xf": Transform3D(b, Vector3(buf[o + 3], buf[o + 7], buf[o + 11])),
			"color": Color(buf[o + 12], buf[o + 13], buf[o + 14], buf[o + 15]), "card": card, "key": key})


## A region's heights, rs × rs: all `h`.
static func flat(rs: int, h: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(rs * rs)
	a.fill(h)
	return a


## A region's heights, rs × rs at 1 m from its corner `origin`: h_of(x, z) at each vertex (small regions: a call each).
static func region(rs: int, h_of: Callable, origin := Vector2.ZERO) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(rs * rs)
	for z in rs:
		for x in rs:
			a[z * rs + x] = float(h_of.call(origin.x + float(x), origin.y + float(z)))
	return a


## The spawner's native scatter of `rect` from the held maps of `locs` and `items` (as _items_for gives them): the job,
## its body run here.
static func scatter(vs, rect: Rect2, locs: Array, items := [], bb := false) -> Dictionary:
	var job: Dictionary = vs._scatter_job(rect, bb, locs, items)
	vs._run_scatter_job_body(job)
	return job


## The spawner's native place of `list` (dictionaries, as encode takes them) on `regions` ([location, heights, …], rs
## vertices a side at 1 m): the job, its body run here.
static func place(vs, list: Array, regions: Array, rs: int) -> Dictionary:
	var job: Dictionary = vs._place_job(encode(list, vs._tables_now()), regions, rs, 1.0)
	vs._run_place_job_body(job)
	return job
