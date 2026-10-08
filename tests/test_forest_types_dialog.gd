# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The Types dialog, headless: the Defaults row then a row per type in the profile's order, the first type selected,
## each row's style and density, what the first write converts said, the forest's problems with the profile shown; +
## New type written, its undo (the selection falls back) and redo; Duplicate; Delete asks, naming the import rules that
## paint it, Cancel keeps it; a row dropped on another moves it; a failed write and a file changed on disk are said,
## nothing kept, the undo steps unchanged, Reopen; a type the forest refuses survives every write; Esc closes; no forest;
## no profile and Create a profile…; a read-only profile; a profile that does not read.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Fix := preload("res://addons/wuifwoud/tests/fixtures/types_fixture.gd")
const ROOT := "user://wf_e2_types_dialog"
const STARTER_FLORA := "res://addons/wuifwoud/packs/starter/starter_flora.json"


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## The type rows shown, by id.
static func _ids(d: Node) -> Array:
	var out := []
	var list: Node = d.find_child("Types", true, false)
	if list != null:
		for c in list.get_children():
			if String(c.name).begins_with("Type_"):
				out.append(int(String(c.name).substr(5)))
	return out


static func _disk(path: String) -> Dictionary:
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}


## The ids of the types on disk (entries without one left out).
static func _disk_ids(path: String) -> Array:
	return (_disk(path).get("types", []) as Array).filter(func(t): return t is Dictionary and t.has("id")).map(
		func(t): return int(t["id"]))


static func _text(n: Node, nm: String) -> String:
	if n == null:
		return ""
	var l := n.find_child(nm, true, false) as Label
	return l.text if l != null else ""


static func run() -> Dictionary:
	var r := {"name": "forest_types_dialog", "passed": 0, "failed": 0, "details": []}
	var fx := Fix.make(ROOT)
	var made: Array = Fix.dialog(fx)
	var d = made[0]
	var pl = made[1]
	var path: String = fx["profile"]
	# ── the list ──
	_chk(r, "the Defaults row, then a row per type in the profile's order (%s)" % str(_ids(d)),
		d.find_child("Defaults", true, false) != null and _ids(d) == [1, 2, 3, 7, 4])
	_chk(r, "the header names the scene and the profile; the first type selected (%s)" % _text(d, "Info"),
		_text(d, "Info").contains("fixture") and _text(d, "Info").contains("flora.json") and d.selected == 1)
	_chk(r, "a row: its style and density, or its pitch (%s; %s)" % [_text(d.find_child("Type_1", true, false), "Info"),
		_text(d.find_child("Type_7", true, false), "Info")],
		_text(d.find_child("Type_1", true, false), "Info") == "natural · 0.04 /m²"
		and _text(d.find_child("Type_7", true, false), "Info") == "grid · 6 m")
	_chk(r, "what the first write converts is said (%s)" % _text(d, "Note"), _text(d, "Note").contains("Ridge"))
	_chk(r, "the forest's problems with the profile shown (%s)" % _text(d, "Problems"),
		_text(d, "Problems").contains("No id"))
	# ── + New type, undo, redo ──
	d.new_type()
	_chk(r, "+ New type: written, selected, the conversion said once (%s)" % str(_disk_ids(path)),
		_disk_ids(path) == [1, 2, 3, 7, 4, 5] and d.selected == 5 and _text(d, "Note").contains("Converted")
		and not (_disk(path)["species"] as Dictionary).has("spare") and _ids(d) == [1, 2, 3, 7, 4, 5])
	d.undo()
	_chk(r, "undo: gone from the file, the selection falls back to the first type",
		_disk_ids(path) == [1, 2, 3, 7, 4] and d.selected == 1 and _ids(d) == [1, 2, 3, 7, 4])
	d.redo()
	_chk(r, "redo brings it back", _disk_ids(path) == [1, 2, 3, 7, 4, 5])
	# ── Duplicate, Delete ──
	d.type_menu_action(1, d.MENU_DUPLICATE)
	_chk(r, "Duplicate: right after the original, selected", _disk_ids(path) == [1, 6, 2, 3, 7, 4, 5] and d.selected == 6)
	pl.rules = [{"match": {}, "type": 6}, {"match": {}, "type": 2}, {"match": {}, "type": 6}]
	d.type_menu_action(6, d.MENU_DELETE)
	var asked := String(d.asking.get("text", ""))
	_chk(r, "Delete asks first: its texels grow nothing, the rules that paint it (%s)" % asked,
		asked.contains("grow nothing") and asked.contains("import rule 1, import rule 3") and _disk_ids(path).has(6)
		and d.find_child("Question", true, false) != null)
	d.cancel_question()
	_chk(r, "Cancel keeps it", _disk_ids(path).has(6) and d.asking.is_empty())
	d.delete_type(6)
	d.confirm_question()
	_chk(r, "confirmed, it is gone; the selection moves on", not _disk_ids(path).has(6) and d.selected == 2)
	# ── a row dropped on another ──
	var row7: Node = d.find_child("Type_7", true, false)
	row7._drop_data(Vector2.ZERO, {"kind": d.TYPE_KIND, "id": "5"})
	_chk(r, "a row dropped on another takes its place, ids unchanged (%s)" % str(_disk_ids(path)),
		_disk_ids(path) == [1, 2, 3, 5, 7, 4])
	# ── a failed write; a file changed on disk ──
	var depth: int = d._undo.size()
	var keep: String = d.profile.path
	d.profile.path = ROOT + "/no/such/folder/flora.json"
	d.new_type()
	_chk(r, "a failed write is said, nothing kept, the undo steps unchanged (%s)" % d.error,
		d.error.begins_with("Not written") and d._undo.size() == depth and d.profile.type_of(6).is_empty())
	d.profile.path = keep
	var on_disk := FileAccess.get_file_as_string(path)
	var hand := FileAccess.open(path, FileAccess.WRITE)
	hand.store_string(on_disk.replace("\"Scrub\"", "\"Heath\""))
	hand.close()
	d.new_type()
	_chk(r, "a file changed on disk is not written over; Reopen offered (%s)" % d.error,
		d.error.contains("changed on disk") and FileAccess.get_file_as_string(path).contains("Heath")
		and d.find_child("Reopen", true, false) != null)
	d.reopen()
	_chk(r, "Reopen reads it again; the undo steps go", d.profile.type_of(2).get("name") == "Heath"
		and d._undo.is_empty() and d.error == "")
	_chk(r, "a type the forest refuses stays in the file through every write",
		(_disk(path)["types"] as Array).any(func(t): return t is Dictionary and t.get("name") == "No id"))
	var closed := [0]
	d.closed.connect(func() -> void: closed[0] += 1)
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	d._input(esc)
	_chk(r, "Esc closes", closed[0] == 1)
	# ── no forest; no profile; read-only; does not read ──
	var nf = Fix.dialog(fx, {"has_forest": false})[0]
	_chk(r, "no forest: said", _text(nf, "MessageText").contains("No forest"))
	nf.free()
	var np: Array = Fix.dialog(fx, {"profile_path": ""})
	var dn = np[0]
	var pn = np[1]
	(dn.find_child("MessageAction", true, false) as Button).pressed.emit()
	_chk(r, "no profile: Create a profile… asks where, in the scene's folder (%s)" % str(pn.saves.map(func(s): return s[2])),
		pn.saves.size() == 1 and String(pn.saves[0][2]).begins_with(ROOT) and String(pn.saves[0][2]).ends_with(".json"))
	var dst := ROOT + "/made/new_flora.json"
	(pn.saves[0][3] as Callable).call(dst)
	_chk(r, "the default flora copied there, the forest told, the new profile shown",
		FileAccess.get_file_as_string(dst) == FileAccess.get_file_as_string(fx["flora"]) and pn.set_to == [dst]
		and dn.state == "ok" and _ids(dn) == [1] and _text(dn.find_child("Type_1", true, false), "Name") == "Woodland")
	dn.free()
	var ro = Fix.dialog(fx, {"profile_path": STARTER_FLORA})[0]
	var starter_text := FileAccess.get_file_as_string(STARTER_FLORA)
	ro.new_type()
	_chk(r, "a read-only profile: shown, Save a copy offered, a change refused, nothing written (%s)" % ro.error,
		ro.state == "read_only" and _ids(ro) == [1, 2, 3] and _text(ro, "MessageText").contains("read-only")
		and String(ro.error).begins_with("Read-only") and FileAccess.get_file_as_string(STARTER_FLORA) == starter_text
		and (ro.find_child("NewType", true, false) as Button).disabled)
	ro.free()
	var broken := ROOT + "/broken.json"
	var bf := FileAccess.open(broken, FileAccess.WRITE)
	bf.store_string("{\n  \"types\": [\n    {\"id\": 1 \"name\": \"x\"}\n  ]\n}\n")
	bf.close()
	var bd = Fix.dialog(fx, {"profile_path": broken})[0]
	bd.new_type()
	_chk(r, "a profile that does not read: named with its line, never written (%s)" % _text(bd, "MessageText"),
		bd.state == "broken" and _text(bd, "MessageText").contains("line")
		and FileAccess.get_file_as_string(broken).contains("\"id\": 1 \"name\""))
	bd.free()
	Fix.clean(ROOT)
	return r
