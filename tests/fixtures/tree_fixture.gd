# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Tests: a tree to prepare, build and bake without any pack's assets: a trunk box under separate
## leaf quads, saved as a scene of one or more MeshInstance3D (named `<name>_LOD0`, `_LOD1`… for an authored chain); a
## species naming it; a mesh's bytes as the rendering server holds them; a user:// folder removed.


## A trunk box (surface 0, material `bark`) under `cards` separate leaf quads (surface 1, material `leaf`).
static func tree_mesh(cards: int, bark: String, leaf: String) -> ArrayMesh:
	var m := ArrayMesh.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.4, 4.0, 0.4)
	var a: Array = box.get_mesh_arrays()
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	for i in v.size():
		v[i] += Vector3(0.0, 2.0, 0.0)
	a[Mesh.ARRAY_VERTEX] = v
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	var mb := StandardMaterial3D.new()
	mb.resource_name = bark
	m.surface_set_material(0, mb)
	var lv := PackedVector3Array()
	var ln := PackedVector3Array()
	var lt := PackedFloat32Array()
	var luv := PackedVector2Array()
	var li := PackedInt32Array()
	for q in cards:
		var ang := TAU * float(q) / float(cards)
		var c := Vector3(cos(ang) * 1.2, 3.5 + 0.3 * float(q % 3), sin(ang) * 1.2)
		var right := Vector3(-sin(ang), 0.0, cos(ang)) * 0.5
		var base := lv.size()
		for corner in [[-1, 0], [1, 0], [1, 1], [-1, 1]]:
			lv.append(c + right * float(corner[0]) + Vector3(0.0, float(corner[1]), 0.0))
			ln.append(Vector3(cos(ang), 0.0, sin(ang)))
			lt.append_array(PackedFloat32Array([-sin(ang), 0.0, cos(ang), 1.0]))
			luv.append(Vector2(0.5 + 0.5 * float(corner[0]), 1.0 - float(corner[1])))
		li.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var la := []
	la.resize(Mesh.ARRAY_MAX)
	la[Mesh.ARRAY_VERTEX] = lv
	la[Mesh.ARRAY_NORMAL] = ln
	la[Mesh.ARRAY_TANGENT] = lt
	la[Mesh.ARRAY_TEX_UV] = luv
	la[Mesh.ARRAY_INDEX] = li
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, la)
	var ml := StandardMaterial3D.new()
	ml.resource_name = leaf
	m.surface_set_material(1, ml)
	return m


## A scene of one MeshInstance3D a mesh, named `names[i]`, saved at `path` and loaded REPLACING any cached copy (a test
## that rewrites a scene must not prepare the old one).
static func scene(path: String, meshes: Array, names: Array) -> void:
	var root := Node3D.new()
	for i in meshes.size():
		var mi := MeshInstance3D.new()
		mi.name = String(names[i])
		mi.mesh = meshes[i]
		root.add_child(mi)
		mi.owner = root
	var ps := PackedScene.new()
	ps.pack(root)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	ResourceSaver.save(ps, path)
	root.free()
	ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)


static func species(id: String, mesh: String, names := PackedStringArray()) -> ForestSpecies:
	var s := ForestSpecies.new()
	s.id = id
	s.mesh = mesh
	s.foliage_materials = names
	return s


## A mesh as the rendering server holds it, surface by surface, the material left out.
static func mesh_bytes(m: ArrayMesh) -> PackedByteArray:
	var out := PackedByteArray()
	for si in m.get_surface_count():
		var d: Dictionary = RenderingServer.mesh_get_surface(m.get_rid(), si)
		d.erase("material")
		out.append_array(var_to_bytes(d))
		out.append_array(m.surface_get_name(si).to_utf8_buffer())
	return out


static func rm_tree(dir: String) -> void:
	var abs := ProjectSettings.globalize_path(dir)
	var d := DirAccess.open(abs)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(abs.path_join(f))
	for sub in d.get_directories():
		rm_tree(dir.path_join(sub))
	DirAccess.remove_absolute(abs)
