# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Tests: a ForestSpeciesPack from the dictionary a test's species catalog used to be ({"species": {id: {kind,
## trunk_radius, crown, mature, young, alpha_cut}}, "default_pack": {"mesh_dir", "ext"}}), each species' mesh where that
## catalog's default pack put it, so a test's species resolve as they did. Not saved: never built.


static func make(cat: Dictionary) -> ForestSpeciesPack:
	var p := ForestSpeciesPack.new()
	p.name = "test"
	var dp: Dictionary = cat.get("default_pack", {})
	var list: Array[ForestSpecies] = []
	var sp: Dictionary = cat.get("species", {})
	for id in sp:
		var e: Dictionary = sp[id]
		var s := ForestSpecies.new()
		s.id = str(id)
		s.kind = str(e.get("kind", "tree"))
		s.crown = str(e.get("crown", "broadleaf"))
		s.trunk_radius = float(e.get("trunk_radius", ForestSpecies.DEFAULT_TRUNK_RADIUS))
		s.mature = bool(e.get("mature", false))
		s.young = bool(e.get("young", false))
		s.alpha_cut = float(e.get("alpha_cut", ForestSpecies.DEFAULT_ALPHA_CUT))
		if dp.has("mesh_dir"):
			s.mesh = str(dp["mesh_dir"]) + str(id) + str(dp.get("ext", ""))
		list.append(s)
	p.species = list
	return p
