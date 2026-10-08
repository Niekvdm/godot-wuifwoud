# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## ForestTrees: the trees file: a round trip in stable bytes (one item a line, keys in
## order, defaults left out, 0.01 rounding as an item comes in), a malformed item dropped and named while the rest
## load, next_id set above every id, an empty set no file, an unreadable file or a wrong schema no items; the trees an
## item plants (a single tree at its point; a row at both ends and evenly between, nudged within bounds; a short row
## one tree; a repeated point harmless); seeds that are the item's own; every planted tree in exactly one cell; the
## clearance of a tree and of a row; near() (copies, by id, an item whose clearance alone reaches the rectangle). Edits:
## add, snapshots that undo and redo, deletion and ownership, picking; the live sets per scene and per folder; an
## import's catch-up.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const TreesRes := preload("res://addons/wuifwoud/forest_trees.gd")
const DIR := "user://wf_b2c_trees"
const PATH := "user://wf_b2c_trees/forest/trees.json"
const ROW := {"id": 1, "kind": "row", "points": [[10.0, 10.0], [50.0, 10.0]], "type": 1, "spacing_m": 8.0,
	"clear_m": 2.5, "source": "osm_id:7"}
const TREE := {"id": 2, "kind": "tree", "at": [100.0, 30.0], "type": 2, "age": 0.8, "species": "W_Old",
	"clear_m": 3.0}


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func _doc(items: Array, extra := {}) -> Dictionary:
	var d := {"schema": "wuifwoud_trees/1", "items": items}
	d.merge(extra, true)
	return d


static func _write(text: String) -> void:
	DirAccess.make_dir_recursive_absolute(PATH.get_base_dir())
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(text)
	f.close()


static func _clean() -> void:
	for d in [PATH.get_base_dir(), DIR.path_join("a"), DIR.path_join("b"), DIR]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d))


static func _bases(pl: Array) -> Array:
	return pl.map(func(x): return x["base"])


static func _seeds(pl: Array) -> Array:
	return pl.map(func(x): return x["seed"])


## Every planted tree's nudge within `along` m along x and `across` m along y (a row along x), and at least one nudged.
static func _nudged_within(pl: Array, along: float, across: float) -> bool:
	var moved := false
	for x in pl:
		var d: Vector2 = (x["p"] as Vector2) - (x["base"] as Vector2)
		if absf(d.x) > along + 1e-3 or absf(d.y) > across + 1e-3:
			return false
		if d.length() > 1e-4:
			moved = true
	return moved


static func run() -> Dictionary:
	var r := {"name": "forest_trees", "passed": 0, "failed": 0, "details": []}
	_clean()

	# ── a round trip in stable bytes ──
	_write(JSON.stringify(_doc([ROW, TREE], {"next_id": 3, "removed": ["osm_id:9"]})))
	var t = TreesRes.new()
	t.configure(PATH)
	var text: String = t.text()
	var back = TreesRes.new()
	back.parse(JSON.parse_string(text))
	var lines := text.split("\n")
	_chk(r, "a file reads back to the same items; the text is schema, next_id, one item a line in key order, removed (%s)" % str(t.errors),
		t.errors.is_empty() and t.items.size() == 2 and back.items == t.items and back.removed == ["osm_id:9"]
		and back.next_id == 3 and lines[1] == " \"schema\": \"wuifwoud_trees/1\"," and lines[2] == " \"next_id\": 3,"
		and lines[4] == "  {\"id\":1,\"kind\":\"row\",\"points\":[[10.0,10.0],[50.0,10.0]],\"type\":1,\"spacing_m\":8.0,\"clear_m\":2.5,\"source\":\"osm_id:7\"},"
		and lines[5] == "  {\"id\":2,\"kind\":\"tree\",\"at\":[100.0,30.0],\"type\":2,\"age\":0.8,\"species\":\"W_Old\",\"clear_m\":3.0}"
		and lines[7] == " \"removed\": [\"osm_id:9\"]")
	var se: Error = t.save()
	var b1 := FileAccess.get_file_as_bytes(PATH)
	var again = TreesRes.new()
	again.configure(PATH)
	again.save()
	_chk(r, "saving writes the text; read and saved again, the same bytes (%s)" % error_string(se),
		se == OK and b1 == text.to_utf8_buffer() and FileAccess.get_file_as_bytes(PATH) == b1)
	var raw := ROW.duplicate(true)
	raw["points"] = [[3323.9404296875, -3371.509765625], [3262.8896484375, -3362.490234375]]
	var tr = TreesRes.new()
	tr.parse(_doc([raw]))
	_chk(r, "coordinates are kept to 0.01 as they come in, so the file and the forest agree (%s)" % tr.text().get_slice("\n", 4),
		tr.text().contains("\"points\":[[3323.94,-3371.51],[3262.89,-3362.49]]")
		and (tr.items[1]["points"] as PackedVector2Array)[0] == Vector2(3323.94, -3371.51))

	# ── a malformed item, an empty set, an unreadable file ──
	var bad := ["not an object", {"id": 0, "kind": "tree", "at": [0, 0], "type": 1},
		{"id": 3, "kind": "bush", "at": [0, 0], "type": 1}, {"id": 4, "kind": "row", "points": [[0, 0]], "type": 1},
		{"id": 5, "kind": "tree", "at": [0, 0], "type": 300},
		{"id": 6, "kind": "row", "points": [[0, 0], [9, 0]], "type": 1, "spacing_m": 0.5},
		{"id": 7, "kind": "tree", "at": [0, 0], "type": 1, "clear_m": -1}, {"id": 8, "kind": "tree", "at": [0, 0], "type": 1},
		{"id": 8, "kind": "tree", "at": [1, 1], "type": 1},
		{"id": 2, "kind": "tree", "at": [0, 0], "type": 1, "source": "osm_id:1", "edited": "yes"}]
	var tb = TreesRes.new()
	tb.parse(_doc(bad, {"next_id": 2}))
	_chk(r, "a malformed item is dropped and named, the rest load (an 'edited' that is not true or false too); a second id 8 is dropped; next_id below an id is set above it (%s)" % str(tb.errors),
		tb.items.keys() == [8] and tb.items[8]["at"] == Vector2.ZERO and tb.errors.size() == 10 and tb.next_id == 9
		and str(tb.errors).contains("item 2: edited"))
	var te = TreesRes.new()
	te.configure(PATH)
	var had: int = te.items.size()
	te.set_state({})
	var ee: Error = te.save()
	_chk(r, "an empty set is no file: saving it deletes the file (%d items before; %s)" % [had, error_string(ee)],
		had == 2 and ee == OK and te.is_empty() and not FileAccess.file_exists(PATH))
	_write("{ broken")
	var tu = TreesRes.new()
	tu.configure(PATH)
	var ts = TreesRes.new()
	ts.parse({"schema": "other/1", "items": [ROW]})
	_chk(r, "an unreadable file or a wrong schema: no items, said (%s; %s)" % [str(tu.errors), str(ts.errors)],
		tu.items.is_empty() and str(tu.errors).contains("not a JSON object") and ts.items.is_empty()
		and str(ts.errors).contains("schema"))
	# A set that did not read its file whole is never saved over it (final review #2): the file may be a merge to fix by
	# hand, and what was dropped would be gone. A next_id set above the ids drops nothing.
	tu.add({"kind": "tree", "at": Vector2(1, 1), "type": 1, "age": 0.0, "species": "", "clear_m": 3.0, "edited": false})
	var ue: Error = tu.save()
	tu.apply(tu.deletion(1))
	var ue2: Error = tu.save()
	var tn = TreesRes.new()
	tn.parse(_doc([ROW], {"next_id": 1}))
	_chk(r, "a set whose file did not read whole is not saved over it, even emptied; one that only lifted next_id is whole (%s, %s; %s)" % [
		error_string(ue), error_string(ue2), str([tu.whole, tb.whole, ts.whole, tn.whole, t.whole])],
		ue == ERR_FILE_CORRUPT and ue2 == ERR_FILE_CORRUPT and FileAccess.get_file_as_string(PATH) == "{ broken"
		and not tu.whole and not tb.whole and not ts.whole and tn.whole and tn.errors.size() == 1 and t.whole)

	# ── the trees an item plants ──
	var row: Dictionary = t.items[1]
	var pl: Array = TreesRes.planted(row, 0)
	var bs := _bases(pl)
	var even := true
	for i in range(1, bs.size()):
		even = even and is_equal_approx((bs[i] as Vector2).distance_to(bs[i - 1]), 8.0)
	_chk(r, "a 40 m row at 8 m: six trees, at both ends and 8 m apart, each nudged within 0.8 m along and 0.3 m across (%s)" % str(bs),
		pl.size() == 6 and bs[0] == Vector2(10, 10) and bs[5] == Vector2(50, 10) and even and _nudged_within(pl, 0.8, 0.3))
	var one: Array = TreesRes.planted(t.items[2], 0)
	var r44 := {"id": 5, "kind": "row", "points": PackedVector2Array([Vector2(0, 0), Vector2(44, 0)]), "type": 1,
		"spacing_m": 8.0, "clear_m": 2.5}
	var short := r44.duplicate(true)
	short["points"] = PackedVector2Array([Vector2(0, 0), Vector2(0.3, 0)])
	var rep := r44.duplicate(true)
	rep["points"] = PackedVector2Array([Vector2(0, 0), Vector2(0, 0), Vector2(16, 0)])
	var p44: Array = TreesRes.planted(r44, 0)
	var pshort: Array = TreesRes.planted(short, 0)
	var prep: Array = TreesRes.planted(rep, 0)
	_chk(r, "a single tree stands at its point; 44 m at 8 m is seven trees 7.33 m apart; a 0.3 m row is one tree at its first point, not nudged; a repeated point changes nothing (%d, %d, %s)" % [
		p44.size(), pshort.size(), str(_bases(prep))],
		one.size() == 1 and one[0]["p"] == Vector2(100, 30) and one[0]["base"] == Vector2(100, 30)
		and p44.size() == 7 and is_equal_approx((p44[1]["base"] as Vector2).x, 44.0 / 6.0)
		and pshort.size() == 1 and pshort[0]["p"] == Vector2.ZERO
		and _bases(prep) == [Vector2(0, 0), Vector2(8, 0), Vector2(16, 0)])
	var t2 = TreesRes.new()
	t2.set_state(t.state())
	var other_tree: Dictionary = t2.items[2]
	other_tree["at"] = Vector2(5, 5)                                     # a reference: t2's item moves
	var retyped := row.duplicate(true)
	retyped["type"] = 3
	var s0: int = int(pl[2]["seed"])
	_chk(r, "a tree's seed is its own item's (id, index, type) and forest_seed: another item changed, the same; forest_seed or the type changed, another",
		_seeds(TreesRes.planted(t2.items[1], 0)) == _seeds(pl) and int(TreesRes.planted(row, 5)[2]["seed"]) != s0
		and int(TreesRes.planted(retyped, 0)[2]["seed"]) != s0 and s0 == hash(Vector4i(1, 2, 1, 0)))
	var all: Array = t.near(Rect2(0, 0, 256, 256))
	var n := 0
	for gx in 4:
		for gz in 4:
			n += TreesRes.trees_in(all, Rect2(gx * 64, gz * 64, 64, 64), 0).size()
	var total := 0
	for it in all:
		total += TreesRes.planted(it, 0).size()
	_chk(r, "every planted tree is in exactly one cell: sixteen 64 m cells hold them all, once (%d of %d)" % [n, total],
		n == total and total == 7)

	# ── the clearance, near() ──
	var zero: Dictionary = (t.items[2] as Dictionary).duplicate(true)
	zero["clear_m"] = 0.0
	var nr := [t.items[1], t.items[2]]
	_chk(r, "clearance: within 2.5 m of the row's line or 3 m of the tree; not beyond, nor 3 m past the row's end; clear_m 0 clears nothing",
		TreesRes.cleared(nr, Vector2(30, 12)) and not TreesRes.cleared(nr, Vector2(30, 13))
		and TreesRes.cleared(nr, Vector2(102, 30)) and not TreesRes.cleared(nr, Vector2(103.5, 30))
		and TreesRes.cleared(nr, Vector2(52, 10)) and not TreesRes.cleared(nr, Vector2(53, 10))
		and not TreesRes.cleared([zero], Vector2(100, 30)))
	var nb: Array = t.near(Rect2(52, 0, 10, 20))
	_chk(r, "near: copies, by id; an item whose clearance alone reaches the rectangle is there, with no tree in it (%d)" % nb.size(),
		nb.size() == 1 and int(nb[0]["id"]) == 1 and not is_same(nb[0], t.items[1])
		and TreesRes.trees_in(nb, Rect2(52, 0, 10, 20), 0).is_empty() and t.near(Rect2(200, 200, 10, 10)).is_empty())
	# ── edits: add, and its snapshots put back and forward ──
	var ed = TreesRes.new()
	ed.configure(DIR.path_join("a/trees.json"))
	ed.set_state(t.state())
	var rev: int = ed.revision
	var before: Dictionary = ed.snapshot([ed.next_id])
	var nid: int = ed.add({"kind": "tree", "at": Vector2(60, 60), "type": 1, "age": 0.0, "species": "", "clear_m": 3.0,
		"edited": false})
	var after: Dictionary = ed.snapshot([nid])
	var added: bool = nid == 3 and ed.next_id == 4 and ed.dirty and ed.revision > rev \
		and ed.pick_tree(Vector2(60.5, 60), 1.0) == 3
	ed.apply(before)
	var undone: bool = not ed.items.has(3) and ed.next_id == 3 and ed.pick_tree(Vector2(60.5, 60), 1.0) == -1
	ed.apply(after)
	_chk(r, "add takes the next id, dirties the set and is found; its snapshots before and after undo and redo it (%s)" % str([added, undone]),
		added and undone and ed.items.has(3) and ed.next_id == 4)
	var del: Dictionary = ed.deletion(1)
	var hand_del: Dictionary = ed.deletion(3)
	var tc: Dictionary = TreesRes.touched(ed.items[1])
	var th: Dictionary = TreesRes.touched(ed.items[3])
	_chk(r, "deleting an imported item adds its source to removed, a hand-made one nothing; a change marks an imported item edited, a hand-made one not (%s)" % str(del),
		del["items"] == {1: null} and del["removed"] == ["osm_id:7", "osm_id:9"] and hand_del["removed"] == ["osm_id:9"]
		and bool(tc["edited"]) and not bool(th.get("edited", false)))
	_chk(r, "picking: the nearest tree, row vertex or row line within the radius; nothing beyond it (%s; %s)" % [
		str(ed.pick_vertex(Vector2(49, 10.5), 2.0)), str(ed.pick_line(Vector2(30, 11), 2.0))],
		ed.pick_tree(Vector2(101, 30), 2.0) == 2 and ed.pick_tree(Vector2(104, 30), 2.0) == -1
		and ed.pick_vertex(Vector2(49, 10.5), 2.0) == [1, 1] and ed.pick_vertex(Vector2(30, 10), 2.0).is_empty()
		and ed.pick_line(Vector2(30, 11), 2.0) == [1, 1, Vector2(30, 10)] and ed.pick_line(Vector2(30, 14), 2.0).is_empty())

	# ── the live sets: unsaved per scene and per folder; an import's catch-up ──
	ed.scene_path = "wf_b2c_trees_isle.tscn"
	var other = TreesRes.new()
	other.configure(DIR.path_join("b/trees.json"))
	other.add({"kind": "tree", "at": Vector2(1, 1), "type": 1, "age": 0.0, "species": "", "clear_m": 3.0, "edited": false})
	other.scene_of = func() -> String: return "wf_b2c_trees_other.tscn"
	var un: Array = TreesRes.unsaved_for("wf_b2c_trees_isle.tscn")
	_chk(r, "unsaved sets per scene (scene_of before scene_path), every scene's for \"\"; live_for finds a folder written either way (%d)" % un.size(),
		un.size() == 1 and un[0] == ed and TreesRes.unsaved_for("").has(other)
		and TreesRes.live_for(DIR.path_join("a") + "/") == [ed] and TreesRes.live_for("user://wf_b2c_trees/./b") == [other])
	var ds: Error = ed.save()
	_chk(r, "a saved set is clean and no longer unsaved; its file holds it (%s)" % error_string(ds),
		ds == OK and not ed.dirty and TreesRes.unsaved_for("wf_b2c_trees_isle.tscn").is_empty()
		and FileAccess.file_exists(DIR.path_join("a/trees.json")))
	var swap = TreesRes.new()
	swap.path = ed.path
	swap.set_state({"items": {7: {"id": 7, "kind": "tree", "at": Vector2(3, 3), "type": 1, "age": 0.0, "species": "",
		"clear_m": 3.0, "edited": false}}, "next_id": 8})
	swap.save()                                       # an import's swap, as the editor sees it
	var g0: int = ed.generation
	var reached: int = TreesRes.imported({"dir": DIR.path_join("a"), "trees_file": "written"})
	var none: int = TreesRes.imported({"dir": DIR.path_join("a"), "trees_file": "unchanged"})
	_chk(r, "an import that wrote a folder's trees file reaches every live set reading it (read again, generation on, clean); one that left it reaches none; another folder's set is untouched (%d, %d)" % [reached, none],
		reached == 1 and none == 0 and ed.items.keys() == [7] and ed.generation == g0 + 1 and not ed.dirty
		and other.generation == 0 and other.items.size() == 1)
	_clean()
	return r
