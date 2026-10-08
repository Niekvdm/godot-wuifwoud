# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## A flora profile as the Types dialog edits it: the whole document (every key kept in its order, `_comment` keys and
## keys it does not know included), its forest types and their lanes, the edits the dialog makes, undo snapshots, and
## the file written back in a stable form. A lane is one mix a type grows: the type's own (its `mixes`), else the pool
## its old pool key names, else the map's default for the lane (the profile's pool of the lane's name), else the
## fallback flora's pool of that name. Opening a profile converts every old reference to a pool not named for its lane
## into the type's own mix, a copy of that pool, so the forest it grows is the same (`converted` says what it did; the
## first write carries it). Pure apart from reading and writing its file.

## The forest types (their defaults, their loader).
const TypesRes := preload("res://addons/wuifwoud/forest_types.gd")
## A type's lanes by style, as the dialog shows them; a band lane (coast, mid, high) has a dead row too (dead_lane()).
const LANES := {"natural": ["coast", "mid", "high", "bush"], "bushes": ["bush"], "grid": ["grid"],
	"mix": ["trees", "bush"]}
## The Defaults row's lanes: the map's default pools.
const DEFAULT_LANES := ["coast", "mid", "high", "bush", "grid"]
## Every lane a type can own, its dead rows included.
const ALL_LANES := ["coast", "mid", "high", "bush", "grid", "trees", "dead.coast", "dead.mid", "dead.high"]
## The pool a lane takes when its type has no mix of its own and names none.
const DEFAULT_POOL := {"coast": "coast", "mid": "mid", "high": "high", "bush": "bush", "grid": "orchard",
	"trees": "mid"}
## The old per-type keys naming a lane's pool (a band's are under `pools`, a dead row's under `dead`).
const LEGACY_KEY := {"bush": "bush_pool", "grid": "pool", "trees": "tree_pool"}
## What a weighted lane holds (Copy from… offers lanes of the same kind); a dead row's kind is "dead".
const KIND := {"coast": "trees", "mid": "trees", "high": "trees", "grid": "trees", "trees": "trees", "bush": "bushes"}
## A type's settings when its entry does not say: what the forest takes without them.
const VALUE_DEFAULTS := {"density_per_m2": 0.0, "pitch_m": TypesRes.DEFAULT_PITCH_M, "clump": 0.0,
	"understory": TypesRes.DEFAULT_UNDERSTORY, "dead_frac": TypesRes.DEFAULT_DEAD_FRAC, "edge_wall_m": 0.0,
	"edge_wall_mult": 1.0, "tree_share": TypesRes.DEFAULT_TREE_SHARE}
## A new type's density (trees a square metre).
const NEW_DENSITY := 0.03
## The bands when the profile has none: the forest's own.
const BAND_DEFAULTS := {"coast_top_m": 120.0, "mid_top_m": 420.0, "treeline_m": 700.0, "treeline_keep": 0.4}
## The highest type id.
const ID_MAX := 255
## A weighted lane's lightest entry.
const WEIGHT_MIN := 0.1
## Its heaviest.
const WEIGHT_MAX := 10.0

## The document, every key kept in its order.
var doc := {}
## Its file ("": none yet).
var path := ""
## Why the last open() or write() failed ("": it did not): the parser's message and line, the wrong shape, or a file
## changed on disk since it was read.
var problem := ""
## The fallback flora's pools ({"species", "dead"}): what a lane inherits when the profile lacks the pool.
var fallback := {"species": {}, "dead": {}}
## What opening converted, a line a type and a line a removed pool; the dialog says it at the first write.
var converted := PackedStringArray()
var _disk := ""            # the file's text as last read or written: a write over another text is refused


# --- reading and writing ---

## Read profile `p_path`, `p_fallback` the fallback flora's pools: OK, or why not (`problem` says it; the document is
## empty then). The old pool references are converted (`converted`).
func open(p_path: String, p_fallback := {}) -> Error:
	path = p_path
	if not FileAccess.file_exists(p_path):
		doc = {}
		problem = "%s does not exist" % p_path
		return ERR_FILE_NOT_FOUND
	return open_text(FileAccess.get_file_as_string(p_path), p_fallback)


## open() from the file's text; `p_convert` false keeps the old pool references as they are.
func open_text(text: String, p_fallback := {}, p_convert := true) -> Error:
	doc = {}
	problem = ""
	converted = PackedStringArray()
	_disk = text
	fallback = {"species": _dict(p_fallback.get("species")), "dead": _dict(p_fallback.get("dead"))}
	var j := JSON.new()
	if j.parse(text) != OK:
		problem = "%s (line %d)" % [j.get_error_message(), j.get_error_line()]
		return ERR_PARSE_ERROR
	if typeof(j.data) != TYPE_DICTIONARY:
		problem = "the profile is not a JSON object"
		return ERR_INVALID_DATA
	var why := problem_of(j.data)
	if why != "":
		problem = why
		return ERR_INVALID_DATA
	doc = j.data
	for t in types():
		if typeof(t) == TYPE_DICTIONARY and typeof(t.get("id")) == TYPE_FLOAT and float(int(t["id"])) == float(t["id"]):
			t["id"] = int(t["id"])
	if p_convert:
		converted = convert_legacy()
	return OK


## Why a parsed profile's shape is wrong ("" when it is right): a key the dialog edits holds the wrong kind.
static func problem_of(d: Dictionary) -> String:
	for k in ["species", "dead", "bands"]:
		if d.has(k) and typeof(d[k]) != TYPE_DICTIONARY:
			return "'%s' is not an object" % k
	if d.has("types") and typeof(d["types"]) != TYPE_ARRAY:
		return "'types' is not a list"
	return ""


## Whether profile `p` ships inside Wuifwoud (the starter flora): shown, never written.
static func is_read_only(p: String) -> bool:
	return p.begins_with(ForestConfig._addon_dir() + "/")


## The file's text: the document with its keys in their order, two-space indents, an array of plain values (a pool
## entry, a list of dead trees) on one line, a type's id a whole number.
func text() -> String:
	return _emit(doc, 0, "") + "\n"


## The document written to its file: OK, or why not (`problem` says it). A read-only profile is never written, nor one
## changed on disk since it was read (an edit made in a text editor is not overwritten: reopen it).
func write() -> Error:
	problem = ""
	if path == "" or is_read_only(path):
		problem = "%s is read-only" % path
		return ERR_FILE_NO_PERMISSION
	if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) != _disk:
		problem = "%s changed on disk since it was read: reopen it" % path.get_file()
		return ERR_FILE_CANT_WRITE
	var out := text()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		var e := FileAccess.get_open_error()
		problem = "could not write %s (%s)" % [path, error_string(e)]
		return e
	f.store_string(out)
	f.close()
	_disk = out
	return OK


## A copy of the document, for undo.
func snapshot() -> Dictionary:
	return doc.duplicate(true)


## Put a snapshot back.
func restore(s: Dictionary) -> void:
	doc = s.duplicate(true)


static func _emit(v, depth: int, key: String) -> String:
	var pad := "  ".repeat(depth + 1)
	var end := "  ".repeat(depth)
	if typeof(v) == TYPE_DICTIONARY:
		if (v as Dictionary).is_empty():
			return "{}"
		var parts := PackedStringArray()
		for k in v:
			parts.append(pad + JSON.stringify(str(k)) + ": " + _emit(v[k], depth + 1, str(k)))
		return "{\n" + ",\n".join(parts) + "\n" + end + "}"
	if typeof(v) == TYPE_ARRAY:
		if (v as Array).is_empty():
			return "[]"
		if (v as Array).all(func(x): return typeof(x) != TYPE_DICTIONARY and typeof(x) != TYPE_ARRAY):
			var flat := PackedStringArray()
			for x in v:
				flat.append(_scalar(x, ""))
			return "[" + ", ".join(flat) + "]"
		var items := PackedStringArray()
		for x in v:
			items.append(pad + _emit(x, depth + 1, ""))
		return "[\n" + ",\n".join(items) + "\n" + end + "]"
	return _scalar(v, key)


## A plain value: a whole number under `id` without a decimal, another whole number with one (3.0), the rest as JSON
## writes it at full precision (it reads back to the same number).
static func _scalar(v, key: String) -> String:
	if typeof(v) == TYPE_INT:
		return str(v)
	if typeof(v) == TYPE_FLOAT and is_finite(v) and float(int(v)) == v and absf(v) < 1.0e15:
		return str(int(v)) if key == "id" else str(int(v)) + ".0"
	return JSON.stringify(v, "", false, true)


static func _dict(v) -> Dictionary:
	return v if typeof(v) == TYPE_DICTIONARY else {}


# --- the types ---

## The type entries, in the profile's order (the entries themselves).
func types() -> Array:
	var t = doc.get("types", [])
	return t if typeof(t) == TYPE_ARRAY else []


## The type ids in the profile's order (entries without a whole-number id left out).
func type_ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	for t in types():
		if typeof(t) == TYPE_DICTIONARY and typeof(t.get("id")) == TYPE_INT:
			out.append(int(t["id"]))
	return out


## Type `id`'s entry ({}: none).
func type_of(id: int) -> Dictionary:
	for t in types():
		if typeof(t) == TYPE_DICTIONARY and typeof(t.get("id")) == TYPE_INT and int(t["id"]) == id:
			return t
	return {}


## Where type `id` is in the list (-1: nowhere).
func index_of(id: int) -> int:
	var l := types()
	for i in l.size():
		if typeof(l[i]) == TYPE_DICTIONARY and typeof(l[i].get("id")) == TYPE_INT and int(l[i]["id"]) == id:
			return i
	return -1


## The first id no type has (1-255); 0 when every one is taken.
func next_id() -> int:
	var used := {}
	for id in type_ids():
		used[id] = true
	for id in range(1, ID_MAX + 1):
		if not used.has(id):
			return id
	return 0


## Type `id`'s setting `key`: its entry's, else what the forest takes without one ("" for a key with no default).
func value_of(id: int, key: String) -> Variant:
	return type_of(id).get(key, VALUE_DEFAULTS.get(key, ""))


# --- lanes ---

## The lanes style `style` shows (a band lane's dead row is with_dead()'s).
static func lanes_for(style: String) -> Array:
	return (LANES.get(style, []) as Array).duplicate()


## `lanes` with each band lane's dead row right after it.
static func with_dead(lanes: Array) -> Array:
	var out := []
	for l in lanes:
		out.append(l)
		if l in TypesRes.BANDS:
			out.append(dead_lane(l))
	return out


## A band's dead row: "dead.mid" for "mid".
static func dead_lane(band: String) -> String:
	return "dead." + band


## Whether `lane` is a dead row.
static func is_dead(lane: String) -> bool:
	return lane.begins_with("dead.")


## The pool `lane` takes by default: a dead row's in `dead` (its band), a lane's in `species` (DEFAULT_POOL).
static func default_pool(lane: String) -> String:
	return lane.substr(5) if is_dead(lane) else String(DEFAULT_POOL.get(lane, lane))


## What `lane` holds: "trees", "bushes" or "dead".
static func kind_of(lane: String) -> String:
	return "dead" if is_dead(lane) else String(KIND.get(lane, "trees"))


## Lane `lane` of type `id` (0: the Defaults row): {"entries": a copy ([[id, weight], …], a dead row [id, …]), "from":
## "own" (the type's mix) | "map" (the profile's pool) | "fallback" (the fallback flora's) | "none" (no pool has it),
## "pool": the pool's name ("" for an own mix)}.
func lane_of(id: int, lane: String) -> Dictionary:
	if id != 0:
		var own = _own(type_of(id), lane)
		if own != null:
			return {"entries": (own as Array).duplicate(true), "from": "own", "pool": ""}
	var nm := pool_name(id, lane)
	var group := "dead" if is_dead(lane) else "species"
	var mine = doc.get(group)
	if typeof(mine) == TYPE_DICTIONARY and (mine as Dictionary).has(nm):
		var m = mine[nm]
		return {"entries": (m as Array).duplicate(true) if typeof(m) == TYPE_ARRAY else [], "from": "map", "pool": nm}
	var fb: Dictionary = fallback.get(group, {})
	if typeof(fb.get(nm)) == TYPE_ARRAY:
		return {"entries": (fb[nm] as Array).duplicate(true), "from": "fallback", "pool": nm}
	return {"entries": [], "from": "none", "pool": nm}


## The pool lane `lane` of type `id` takes when it has no mix of its own: the one its old key names, else the lane's
## default.
func pool_name(id: int, lane: String) -> String:
	var ref = _legacy_ref(type_of(id), lane) if id != 0 else null
	return str(ref) if ref != null else default_pool(lane)


## The pool an old key of entry `t` names for `lane`, or null.
static func _legacy_ref(t: Dictionary, lane: String):
	if is_dead(lane):
		var dn = t.get("dead")
		return (dn as Dictionary).get(lane.substr(5)) if typeof(dn) == TYPE_DICTIONARY else null
	if lane in TypesRes.BANDS:
		var pn = t.get("pools")
		return (pn as Dictionary).get(lane) if typeof(pn) == TYPE_DICTIONARY else null
	return t.get(LEGACY_KEY[lane]) if LEGACY_KEY.has(lane) else null


## Entry `t`'s own mix for `lane` (the array itself), or null.
static func _own(t: Dictionary, lane: String):
	var m = t.get("mixes")
	if typeof(m) != TYPE_DICTIONARY:
		return null
	if is_dead(lane):
		var dm = (m as Dictionary).get("dead")
		if typeof(dm) != TYPE_DICTIONARY:
			return null
		var row = (dm as Dictionary).get(lane.substr(5))
		return row if typeof(row) == TYPE_ARRAY else null
	var mix = (m as Dictionary).get(lane)
	return mix if typeof(mix) == TYPE_ARRAY else null


## Entry `t`'s own mix for `lane` set to `entries`.
static func _put_own(t: Dictionary, lane: String, entries: Array) -> void:
	if typeof(t.get("mixes")) != TYPE_DICTIONARY:
		t["mixes"] = {}
	var m: Dictionary = t["mixes"]
	if is_dead(lane):
		if typeof(m.get("dead")) != TYPE_DICTIONARY:
			m["dead"] = {}
		(m["dead"] as Dictionary)[lane.substr(5)] = entries
	else:
		m[lane] = entries


## Entry `t`'s old key for `lane` taken out (an empty `pools` or `dead` with it).
static func _drop_ref(t: Dictionary, lane: String) -> void:
	if is_dead(lane) or lane in TypesRes.BANDS:
		var key := "dead" if is_dead(lane) else "pools"
		var names = t.get(key)
		if typeof(names) == TYPE_DICTIONARY:
			(names as Dictionary).erase(lane.substr(5) if is_dead(lane) else lane)
			if (names as Dictionary).is_empty():
				t.erase(key)
	elif LEGACY_KEY.has(lane):
		t.erase(LEGACY_KEY[lane])


# --- the conversion ---

## Every old reference to a pool not named for its lane becomes the type's own mix, a copy of that pool as the forest
## resolves it (the profile's, else the fallback flora's), and the reference goes; one whose lane already has an own mix
## just goes; one to a pool no one has stays (the forest names it); one naming its lane's default stays. Then a pool that
## only those references named goes too, unless a lane defaults to it. What it did: a line a type, a line a pool.
func convert_legacy() -> PackedStringArray:
	var said := PackedStringArray()
	var named := {}            # "species/<pool>" | "dead/<pool>" -> true: named by a converted reference
	for t in types():
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var lanes := PackedStringArray()
		var from := PackedStringArray()
		for lane in ALL_LANES:
			var ref = _legacy_ref(t, lane)
			if ref == null or str(ref) == default_pool(lane):
				continue
			if _own(t, lane) != null:
				_drop_ref(t, lane)
				continue
			var group := "dead" if is_dead(lane) else "species"
			var pool = _pool_in(group, str(ref))
			if pool == null:
				continue
			_put_own(t, lane, (pool as Array).duplicate(true))
			_drop_ref(t, lane)
			named[group + "/" + str(ref)] = true
			lanes.append(lane)
			if not from.has(str(ref)):
				from.append(str(ref))
		if not lanes.is_empty():
			said.append("%s: %s own their mix now (from pool %s)" % [str(t.get("name", "a type")), ", ".join(lanes),
				", ".join(from)])
	for key in named:
		var group := String(key).get_slice("/", 0)
		var nm := String(key).get_slice("/", 1)
		var pools = doc.get(group)
		if typeof(pools) != TYPE_DICTIONARY or not (pools as Dictionary).has(nm):
			continue
		if _defaulted(group, nm) or _still_named(group, nm):
			continue
		(pools as Dictionary).erase(nm)
		said.append("pool %s removed (no type names it now)" % nm)
	return said


## The pool the forest takes for `nm` in `group` ("species" | "dead"): the profile's when it has the name (null when that
## is not a list), else the fallback flora's, else null.
func _pool_in(group: String, nm: String):
	var mine = doc.get(group)
	if typeof(mine) == TYPE_DICTIONARY and (mine as Dictionary).has(nm):
		return mine[nm] if typeof(mine[nm]) == TYPE_ARRAY else null
	var fb: Dictionary = fallback.get(group, {})
	return fb[nm] if typeof(fb.get(nm)) == TYPE_ARRAY else null


static func _defaulted(group: String, nm: String) -> bool:
	if group == "dead":
		return nm in TypesRes.BANDS
	return DEFAULT_POOL.values().has(nm)


func _still_named(group: String, nm: String) -> bool:
	for t in types():
		if typeof(t) != TYPE_DICTIONARY:
			continue
		for lane in ALL_LANES:
			if (group == "dead") != is_dead(lane):
				continue
			var ref = _legacy_ref(t, lane)
			if ref != null and str(ref) == nm:
				return true
	return false


# --- as the forest loads it ---

## The pools the forest reads: the profile's `species` and `dead` over the fallback flora's, a pool replaced whole.
func merged_pools() -> Dictionary:
	var out := {}
	for group in ["species", "dead"]:
		var m: Dictionary = (fallback.get(group, {}) as Dictionary).duplicate(true)
		var mine = doc.get(group)
		if typeof(mine) == TYPE_DICTIONARY:
			for k in mine:
				m[k] = mine[k]
		out[group] = m
	return out


## The types as the forest loads them, the species `disabled` names left out; the age subsets from `is_young` /
## `is_mature` (none without them).
func resolve(is_young := Callable(), is_mature := Callable(), disabled := PackedStringArray()) -> ForestTypes:
	var none := func(_n: String) -> bool: return false
	var pools := merged_pools()
	var ft: ForestTypes = TypesRes.new()
	ft.load_list(doc.get("types", []), TypesRes.drop_species(pools["species"], disabled),
		TypesRes.drop_species(pools["dead"], disabled), is_young if is_young.is_valid() else none,
		is_mature if is_mature.is_valid() else none, disabled)
	return ft


## What the forest refuses in the profile as it is (ForestTypes' errors).
func load_errors() -> PackedStringArray:
	return resolve().errors


# --- the edits: each changes the document and returns "" (done) or why not (nothing changed then) ---

## + New type: the next free id, "New type", natural, NEW_DENSITY, every lane inherited. Its id; 0 when every id is
## taken (nothing added).
func add_type() -> int:
	var id := next_id()
	if id == 0:
		return 0
	_list().append({"id": id, "name": "New type", "style": "natural", "density_per_m2": NEW_DENSITY})
	return id


## Type `id` duplicated right after it: a new id, "<name> copy", its settings and its own lanes copied. The new id; 0
## when there is no type `id` or no free id.
func duplicate_type(id: int) -> int:
	var t := type_of(id)
	var nid := next_id()
	if t.is_empty() or nid == 0:
		return 0
	var c: Dictionary = t.duplicate(true)
	c["id"] = nid
	c["name"] = "%s copy" % str(t.get("name", "type %d" % id))
	_list().insert(index_of(id) + 1, c)
	return nid


## Type `id` deleted.
func delete_type(id: int) -> String:
	var i := index_of(id)
	if i < 0:
		return "there is no type %d" % id
	_list().remove_at(i)
	return ""


## Type `id` moved to position `to` of the list (the library's order; ids never change).
func move_type(id: int, to: int) -> String:
	var i := index_of(id)
	if i < 0:
		return "there is no type %d" % id
	var l := _list()
	var t = l[i]
	l.remove_at(i)
	l.insert(clampi(to, 0, l.size()), t)
	return ""


## Type `id`'s setting `key` set to `value`, within the range the forest takes: a name is not empty; a density and a
## pitch are above 0; clump, dead share and tree share 0-1, understory 0-2, the edge wall 0 or more, its multiplier 1
## or more; an icon a name ("" takes it out); a colour or a far colour "#rrggbb" ("" takes it out).
func set_value(id: int, key: String, value) -> String:
	var t := type_of(id)
	if t.is_empty():
		return "there is no type %d" % id
	match key:
		"name":
			var nm := str(value).strip_edges()
			if nm == "":
				return "a type needs a name"
			t["name"] = nm
		"density_per_m2", "pitch_m":
			if float(value) <= 0.0:
				return "%s must be above 0" % ("the density" if key == "density_per_m2" else "the pitch")
			t[key] = float(value)
		"clump", "dead_frac", "tree_share":
			t[key] = clampf(float(value), 0.0, 1.0)
		"understory":
			t[key] = clampf(float(value), 0.0, 2.0)
		"edge_wall_m":
			t[key] = maxf(float(value), 0.0)
		"edge_wall_mult":
			t[key] = maxf(float(value), 1.0)
		"icon":
			if str(value) == "":
				t.erase("icon")
			else:
				t["icon"] = str(value)
		"colour", "far_color":
			var c := str(value) if value != null else ""
			if c == "":
				t.erase(key)
			elif not (c.begins_with("#") and Color.html_is_valid(c)):
				return "a colour is written #rrggbb (%s)" % c
			else:
				t[key] = c
		_:
			return "%s is not a type setting" % key
	return ""


## Type `id`'s style: every value that still applies kept; leaving a grid without a density takes it from the pitch.
func set_style(id: int, style: String) -> String:
	var t := type_of(id)
	if t.is_empty():
		return "there is no type %d" % id
	if not (style in TypesRes.STYLES):
		return "style %s is not one of %s" % [style, ", ".join(TypesRes.STYLES)]
	if style != "grid" and float(t.get("density_per_m2", 0.0)) <= 0.0:
		var pm := float(t.get("pitch_m", TypesRes.DEFAULT_PITCH_M))
		t["density_per_m2"] = 1.0 / (pm * pm)
	t["style"] = style
	return ""


## Lane `lane` of type `id` set to `entries`, its own mix from now on; of the Defaults row (id 0): the map's own pool
## of the lane's default name.
func set_lane(id: int, lane: String, entries: Array) -> String:
	if id == 0:
		var group := "dead" if is_dead(lane) else "species"
		if typeof(doc.get(group)) != TYPE_DICTIONARY:
			doc[group] = {}
		(doc[group] as Dictionary)[default_pool(lane)] = entries
		return ""
	var t := type_of(id)
	if t.is_empty():
		return "there is no type %d" % id
	_put_own(t, lane, entries)
	return ""


## Lane `lane` of type `id` back to what it inherits (its own mix dropped, `mixes` with it once empty); of the Defaults
## row: the map's own pool dropped, so the fallback flora's grows.
func reset_lane(id: int, lane: String) -> String:
	if id == 0:
		var pools = doc.get("dead" if is_dead(lane) else "species")
		if typeof(pools) == TYPE_DICTIONARY:
			(pools as Dictionary).erase(default_pool(lane))
		return ""
	var t := type_of(id)
	if t.is_empty():
		return "there is no type %d" % id
	var m = t.get("mixes")
	if typeof(m) != TYPE_DICTIONARY:
		return ""
	if is_dead(lane):
		var dm = (m as Dictionary).get("dead")
		if typeof(dm) == TYPE_DICTIONARY:
			(dm as Dictionary).erase(lane.substr(5))
			if (dm as Dictionary).is_empty():
				(m as Dictionary).erase("dead")
	else:
		(m as Dictionary).erase(lane)
	if (m as Dictionary).is_empty():
		t.erase("mixes")
	return ""


## Species `sp` added to lane `lane` of type `id`: an inheriting lane first takes a copy of what it inherits; a weighted
## lane's new entry weighs the lane's mean (1 in an empty lane), a dead row's has no weight. One already there is
## refused.
func add_to_lane(id: int, lane: String, sp: String) -> String:
	var entries: Array = lane_of(id, lane)["entries"]
	if names_in(entries).has(sp):
		return "%s is already in that lane" % sp
	entries.append(sp if is_dead(lane) else [sp, mean_weight(entries)])
	return set_lane(id, lane, entries)


## Species `sp` taken out of lane `lane` of type `id` (an inheriting lane gets its own mix without it).
func remove_from_lane(id: int, lane: String, sp: String) -> String:
	var entries: Array = lane_of(id, lane)["entries"]
	if not names_in(entries).has(sp):
		return "%s is not in that lane" % sp
	return set_lane(id, lane, entries.filter(func(e) -> bool: return _name(e) != sp))


## Species `sp`'s weight in lane `lane` of type `id`, clamped to WEIGHT_MIN-WEIGHT_MAX.
func set_weight(id: int, lane: String, sp: String, w: float) -> String:
	if is_dead(lane):
		return "a dead row has no weights"
	var entries: Array = lane_of(id, lane)["entries"]
	if not names_in(entries).has(sp):
		return "%s is not in that lane" % sp
	for i in entries.size():
		if _name(entries[i]) == sp:
			entries[i] = [sp, clampf(w, WEIGHT_MIN, WEIGHT_MAX)]
	return set_lane(id, lane, entries)


## Species `sp` moved from lane `from_lane` to `to_lane` of type `id`: weighted to weighted keeps its weight; into a dead
## row bare; from a dead row at the target's mean weight. Onto its own lane: nothing; onto a lane that has it: refused.
func move_between(id: int, from_lane: String, to_lane: String, sp: String) -> String:
	if from_lane == to_lane:
		return ""
	var src: Array = lane_of(id, from_lane)["entries"]
	var dst: Array = lane_of(id, to_lane)["entries"]
	if not names_in(src).has(sp):
		return "%s is not in that lane" % sp
	if names_in(dst).has(sp):
		return "%s is already in that lane" % sp
	var w := mean_weight(dst)
	for e in src:
		if _name(e) == sp and typeof(e) == TYPE_ARRAY and (e as Array).size() > 1:
			w = float(e[1])
	dst.append(sp if is_dead(to_lane) else [sp, w])
	var why := set_lane(id, from_lane, src.filter(func(e) -> bool: return _name(e) != sp))
	return why if why != "" else set_lane(id, to_lane, dst)


## Lane `lane` of type `id` set to a copy of lane `from_lane` of type `from_id` (0: the Defaults row): a dead row takes
## the names, a weighted lane takes a dead row's names at weight 1.
func copy_lane(id: int, lane: String, from_id: int, from_lane: String) -> String:
	var src: Array = lane_of(from_id, from_lane)["entries"]
	var out := []
	for e in src:
		if is_dead(lane):
			out.append(_name(e))
		else:
			out.append(e if typeof(e) == TYPE_ARRAY else [_name(e), 1.0])
	return set_lane(id, lane, out)


## The species a lane's entries name, in order.
static func names_in(entries: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for e in entries:
		out.append(_name(e))
	return out


## A lane's mean weight, snapped to 0.1 and within WEIGHT_MIN-WEIGHT_MAX (a bare entry weighs 1); 1 for an empty lane.
static func mean_weight(entries: Array) -> float:
	if entries.is_empty():
		return 1.0
	var tot := 0.0
	for e in entries:
		tot += float(e[1]) if typeof(e) == TYPE_ARRAY and (e as Array).size() > 1 else 1.0
	return clampf(snappedf(tot / entries.size(), 0.1), WEIGHT_MIN, WEIGHT_MAX)


## The bands, the forest's own for any the profile lacks.
func bands() -> Dictionary:
	var out: Dictionary = BAND_DEFAULTS.duplicate()
	var b = doc.get("bands")
	if typeof(b) == TYPE_DICTIONARY:
		for k in BAND_DEFAULTS:
			if (b as Dictionary).has(k):
				out[k] = float(b[k])
	return out


## Band `key` set: the coast's top under the mid's, the mid's under the treeline; the share kept above the treeline 0-1.
func set_band(key: String, value: float) -> String:
	if not BAND_DEFAULTS.has(key):
		return "%s is not a band" % key
	var b := bands()
	b[key] = value
	if key == "treeline_keep":
		if value < 0.0 or value > 1.0:
			return "the share kept above the treeline is 0-100 %"
	elif not (float(b["coast_top_m"]) < float(b["mid_top_m"]) and float(b["mid_top_m"]) < float(b["treeline_m"])):
		return "the bands must climb: the coast's top under the mid's, the mid's under the treeline"
	if typeof(doc.get("bands")) != TYPE_DICTIONARY:
		doc["bands"] = {}
	(doc["bands"] as Dictionary)[key] = value
	return ""


func _list() -> Array:
	if typeof(doc.get("types")) != TYPE_ARRAY:
		doc["types"] = []
	return doc["types"]


static func _name(e) -> String:
	return str(e[0]) if typeof(e) == TYPE_ARRAY else str(e)
