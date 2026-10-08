# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestTypes
extends RefCounted
## The forest types of a flora profile: what a forest map's R channel names. A type is a STYLE (natural
## forest, bushes only, a planted grid, a light mix of trees and bushes) with its own density, pools and
## stand numbers, under a stable numeric id (1-255) that the maps store, so reordering the list changes nothing.
##
## A type's lanes: its own mix when its `mixes` names one (`coast`, `mid`, `high`, `bush`; a grid's `grid`; a mix's
## `trees`; `dead` by band), else a pool taken by name from the profile's (and the fallback flora's) `species` / `dead`,
## the old keys (`pools`, `bush_pool`, `pool`, `tree_pool`, `dead`) naming it or the lane's default name. A type may
## carry an `icon` (a glyph name) and a `colour` (#rrggbb) for the editor. The age subsets (young, mature) are built
## here, once, on the main thread, so placement workers never ask the species packs. A bad type is named in `errors`
## and dropped; the rest load. Immutable after load_list: workers read it.

## A type's styles.
const STYLES := ["natural", "bushes", "grid", "mix"]
## The elevation bands a pool is named by.
const BANDS := ["coast", "mid", "high"]
## A grid's tree spacing by default (m).
const DEFAULT_PITCH_M := 7.0
## A natural type's bush share by default.
const DEFAULT_UNDERSTORY := 0.35
## A natural type's dead share by default.
const DEFAULT_DEAD_FRAC := 0.03
## A mix's tree share by default.
const DEFAULT_TREE_SHARE := 0.6

## Int -> Dictionary: a normalised type (see load_list)
var by_id := {}
## Types refused, named once each.
var errors: PackedStringArray = []


## The types of `list` (a profile's `types`): each lane its own mix, else the pool its name takes from `species` /
## `dead`. The species `disabled` names leave the own mixes (the pools come without them already). `is_young` and
## `is_mature` (species name -> bool) build the age subsets.
func load_list(list, species: Dictionary, dead: Dictionary, is_young: Callable, is_mature: Callable,
		disabled := PackedStringArray()) -> void:
	by_id.clear()
	errors.clear()
	if typeof(list) != TYPE_ARRAY:
		errors.append("types must be a list")
		return
	for e in list:
		var t := _one(e, species, dead, is_young, is_mature, disabled)
		if t.is_empty():
			continue
		if by_id.has(t["id"]):
			errors.append("type id %d is used twice: '%s' is dropped" % [t["id"], t["name"]])
			continue
		by_id[t["id"]] = t


## The type ids in the profile's order (the workspace library's).
func order() -> PackedInt32Array:
	return PackedInt32Array(by_id.keys())


## The type ids, sorted.
func ids() -> PackedInt32Array:
	var out := PackedInt32Array(by_id.keys())
	out.sort()
	return out


## The type with id `id` ({} for none).
func get_type(id: int) -> Dictionary:
	return by_id.get(id, {})


func _one(e, species: Dictionary, dead: Dictionary, is_young: Callable, is_mature: Callable,
		disabled: PackedStringArray) -> Dictionary:
	if typeof(e) != TYPE_DICTIONARY:
		errors.append("a type is not an object: %s" % str(e))
		return {}
	var d: Dictionary = e
	var nm := str(d.get("name", ""))
	var label := "type %s ('%s')" % [str(d.get("id", "?")), nm]
	var idv = d.get("id")
	if not (typeof(idv) in [TYPE_INT, TYPE_FLOAT]) or float(int(idv)) != float(idv) or int(idv) < 1 or int(idv) > 255:
		errors.append("%s: the id must be a whole number 1-255" % label)
		return {}
	if nm == "":
		errors.append("%s: it has no name" % label)
		return {}
	var style := str(d.get("style", ""))
	if not (style in STYLES):
		errors.append("%s: style '%s' is not one of %s" % [label, style, ", ".join(STYLES)])
		return {}
	var t := {"id": int(idv), "name": nm, "style": style}
	if style == "grid":
		var pm := float(d.get("pitch_m", DEFAULT_PITCH_M))
		if pm <= 0.0:
			errors.append("%s: pitch_m must be above 0" % label)
			return {}
		t["pitch"] = pm
		t["density"] = 1.0 / (pm * pm)
	else:
		var dn := float(d.get("density_per_m2", 0.0))
		if dn <= 0.0:
			errors.append("%s: density_per_m2 must be above 0" % label)
			return {}
		t["density"] = dn
		t["pitch"] = 1.0 / sqrt(dn)
	t["clump"] = clampf(float(d.get("clump", 0.0)), 0.0, 1.0)
	t["understory"] = clampf(float(d.get("understory", DEFAULT_UNDERSTORY)), 0.0, 2.0)
	t["edge_wall_m"] = float(d.get("edge_wall_m", 0.0))
	t["edge_wall_mult"] = maxf(float(d.get("edge_wall_mult", 1.0)), 1.0)
	t["dead_frac"] = clampf(float(d.get("dead_frac", DEFAULT_DEAD_FRAC)), 0.0, 1.0)
	var fc = d.get("far_color")
	if fc != null:
		if typeof(fc) == TYPE_STRING and String(fc).begins_with("#") and Color.html_is_valid(String(fc)):
			t["far_color"] = Color.html(String(fc))
		else:
			errors.append("%s: far_color must be \"#rrggbb\" (%s): ignored" % [label, str(fc)])
	var ic = d.get("icon")
	if ic != null:
		t["icon"] = str(ic)
	var co = d.get("colour")
	if co != null:
		if typeof(co) == TYPE_STRING and String(co).begins_with("#") and Color.html_is_valid(String(co)):
			t["colour"] = Color.html(String(co))
		else:
			errors.append("%s: colour must be \"#rrggbb\" (%s): ignored" % [label, str(co)])
	var mixes = d.get("mixes", {})
	if typeof(mixes) != TYPE_DICTIONARY:
		errors.append("%s: mixes must be an object" % label)
		return {}
	var dead_mix = (mixes as Dictionary).get("dead", {})
	if typeof(dead_mix) != TYPE_DICTIONARY:
		errors.append("%s: mixes.dead must be an object of dead-tree lists by band" % label)
		return {}
	mixes = drop_species(mixes, disabled)
	dead_mix = drop_species(dead_mix, disabled)
	var bush = _lane(mixes, "bush", species, str(d.get("bush_pool", "bush")), label)
	if bush == null:
		return {}
	t["bush"] = bush
	match style:
		"natural":
			var names: Dictionary = d["pools"] if typeof(d.get("pools")) == TYPE_DICTIONARY else {}
			var bands := {}
			var young := {}
			var mature := {}
			for b in BANDS:
				var p = _lane(mixes, b, species, str(names.get(b, b)), label)
				if p == null:
					return {}
				bands[b] = p
				young[b] = (p as Array).filter(func(x): return bool(is_young.call(str(x[0]))))
				mature[b] = (p as Array).filter(func(x): return bool(is_mature.call(str(x[0]))))
			t["bands"] = bands
			t["young"] = young
			t["mature"] = mature
			var dnames: Dictionary = d["dead"] if typeof(d.get("dead")) == TYPE_DICTIONARY else {}
			var dd := {}
			for b in BANDS:
				var dp = dead_mix[b] if (dead_mix as Dictionary).has(b) else dead.get(str(dnames.get(b, b)), [])
				dd[b] = dp if typeof(dp) == TYPE_ARRAY else []
			t["dead"] = dd
		"grid":
			var gp = _lane(mixes, "grid", species, str(d.get("pool", "orchard")), label)
			if gp == null:
				return {}
			t["pool"] = gp
		"mix":
			var tp = _lane(mixes, "trees", species, str(d.get("tree_pool", "mid")), label)
			if tp == null:
				return {}
			t["tree"] = tp
			t["tree_young"] = (tp as Array).filter(func(x): return bool(is_young.call(str(x[0]))))
			t["tree_mature"] = (tp as Array).filter(func(x): return bool(is_mature.call(str(x[0]))))
			t["tree_share"] = clampf(float(d.get("tree_share", DEFAULT_TREE_SHARE)), 0.0, 1.0)
	return t


## A type's lane `key`: its own mix (`mixes[key]`, a list), else the pool `name`; null with an error when neither is.
func _lane(mixes: Dictionary, key: String, species: Dictionary, name: String, label: String):
	if mixes.has(key):
		if typeof(mixes[key]) != TYPE_ARRAY:
			errors.append("%s: its own %s mix must be a list" % [label, key])
			return null
		return mixes[key]
	return _pool(species, name, label)


## A named pool, or null with an error when neither the profile nor the fallback flora has it. A pool authored as []
## is legal: its points grow nothing, as before.
func _pool(species: Dictionary, name: String, label: String):
	if not species.has(name) or typeof(species[name]) != TYPE_ARRAY:
		errors.append("%s names pool '%s', which neither the profile nor the fallback flora has" % [label, name])
		return null
	return species[name]


## `pools` (name -> [[id, weight], …] or [id, …]) without the species `ids` names: a new dictionary, each pool's other
## entries in their order with their weights (a pool left empty stays, empty). `pools` itself when `ids` is empty: a
## project with nothing switched off loads exactly what it loaded before.
static func drop_species(pools: Dictionary, ids: PackedStringArray) -> Dictionary:
	if ids.is_empty():
		return pools
	var gone := {}
	for id in ids:
		gone[String(id)] = true
	var out := {}
	for k in pools:
		var pool = pools[k]
		if typeof(pool) != TYPE_ARRAY:
			out[k] = pool
			continue
		out[k] = (pool as Array).filter(func(e) -> bool:
			return not gone.has(str(e[0]) if typeof(e) == TYPE_ARRAY else str(e)))
	return out
