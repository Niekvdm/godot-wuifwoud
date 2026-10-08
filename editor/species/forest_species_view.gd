# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends Control
## A species in 3D for the Species dialog: a World3D of its own (a fixed sky and sun, a ground disc), the species drawn
## as the forest draws it (ForestAssets.view_parts: its own materials, a LOD level at a time, its impostor card), seen
## through a camera that orbits it (drag), zooms (the wheel) and resets (a double click). Modes: "model", "card",
## "compare" (one camera: the model on the left, the card on the right) and "sheets" (the bake's albedo and normal
## sheets, the view the card is drawing outlined). The card modes say why there is no card, or that it is the last
## bake's. Renders only while visible; its world goes with it.

## The camera moved (Inspect reads its distance and elevation).
signal camera_moved

## The forest's assets.
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
## The impostor baker (its view lookup).
const BakerRes := preload("res://addons/wuifwoud/species/forest_impostor_baker.gd")
## The modes.
const MODES := ["model", "card", "compare", "sheets"]
## The ground's render layer.
const GROUND_LAYER := 1
## The model's render layer.
const MODEL_LAYER := 2
## The card's render layer.
const CARD_LAYER := 4
## The trunk ring's colour.
const RING_COLOUR := Color(0.31, 0.76, 0.97, 0.45)
## The camera's turn round the tree at rest (degrees).
const DEFAULT_YAW := 35.0
## Its height above the horizon at rest (degrees).
const DEFAULT_PITCH := 18.0
## The camera's field of view (degrees).
const FOV_DEG := 35.0

## The mode.
var mode := "model"
## The level drawn.
var lod := 0
## The camera's turn (degrees).
var yaw := DEFAULT_YAW
## The camera's height above the horizon (degrees).
var pitch := DEFAULT_PITCH
## The camera's distance from the tree's centre (m); 0: framed.
var dist := 0.0
## ForestAssets.view_parts of the species shown.
var parts := {}
## The species shown.
var sp = null
var _state := "built"
var _world: World3D
var _left: SubViewportContainer
var _right: SubViewportContainer
var _cam_l: Camera3D
var _cam_r: Camera3D
var _model: MeshInstance3D
var _card: MeshInstance3D
var _ring: MeshInstance3D
var _ground: MeshInstance3D
var _sheets: HBoxContainer
var _outline: Panel
var _note: Label
var _framed := 10.0
var _centre := Vector3.ZERO
var _drag := false


func _init() -> void:
	clip_contents = true
	mouse_filter = MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, 190)
	_world = World3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.36, 0.45, 0.53)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.70, 0.76, 0.86)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_world.environment = env
	var h := HBoxContainer.new()
	h.name = "Views"
	h.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 1)
	h.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(h)
	var l := _viewport("Left")
	_left = l[0]
	_cam_l = l[1]
	var r := _viewport("Right")
	_right = r[0]
	_cam_r = r[1]
	h.add_child(_left)
	h.add_child(_right)
	var vp_l := _left.get_child(0) as SubViewport
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 150.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	vp_l.add_child(sun)
	_ground = MeshInstance3D.new()
	_ground.name = "Ground"
	var disc := CylinderMesh.new()
	disc.height = 0.02
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	_ground.mesh = disc
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.25, 0.30, 0.22)
	_ground.material_override = gm
	_ground.layers = GROUND_LAYER
	vp_l.add_child(_ground)
	_model = MeshInstance3D.new()
	_model.name = "Model"
	_model.layers = MODEL_LAYER
	vp_l.add_child(_model)
	_card = MeshInstance3D.new()
	_card.name = "Card"
	_card.layers = CARD_LAYER
	vp_l.add_child(_card)
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	_ring.layers = MODEL_LAYER
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.albedo_color = RING_COLOUR
	_ring.material_override = rm
	_ring.mesh = CylinderMesh.new()
	vp_l.add_child(_ring)
	_sheets = HBoxContainer.new()
	_sheets.name = "Sheets"
	_sheets.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_sheets.visible = false
	_sheets.mouse_filter = MOUSE_FILTER_IGNORE
	for nm in ["Albedo", "Normal"]:
		var tr := TextureRect.new()
		tr.name = nm
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_horizontal = SIZE_EXPAND_FILL
		_sheets.add_child(tr)
	add_child(_sheets)
	_outline = Panel.new()
	_outline.name = "Outline"
	var ob := StyleBoxFlat.new()
	ob.draw_center = false
	ob.set_border_width_all(2)
	ob.border_color = Color("ffd54a")
	_outline.add_theme_stylebox_override("panel", ob)
	_outline.mouse_filter = MOUSE_FILTER_IGNORE
	_outline.visible = false
	add_child(_outline)
	_note = Label.new()
	_note.name = "Note"
	_note.set_anchors_and_offsets_preset(PRESET_CENTER_TOP)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.add_theme_color_override("font_color", Color("ffcc80"))
	_note.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_note)


func _viewport(nm: String) -> Array:
	var c := SubViewportContainer.new()
	c.name = nm
	c.stretch = true
	c.size_flags_horizontal = SIZE_EXPAND_FILL
	c.mouse_filter = MOUSE_FILTER_IGNORE
	var vp := SubViewport.new()
	vp.world_3d = _world
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	c.add_child(vp)
	var cam := Camera3D.new()
	cam.fov = FOV_DEG
	vp.add_child(cam)
	cam.current = true
	return [c, cam]


## Show species `sp` (its pack built in `dir`, `man` its built.json) in `state` (ForestPackBuild.state_of's).
func show_species(p_sp, dir: String, man: Dictionary, state := "built") -> void:
	sp = p_sp
	_state = state
	parts = VA.view_parts(sp, dir, man) if sp != null else {}
	lod = clampi(lod, 0, maxi(levels().size() - 1, 0))
	dist = 0.0
	_place()


## The levels drawn (the authored chain, else the combined mesh).
func levels() -> Array:
	return parts.get("levels", [])


## Level `i`'s triangle count.
func tris(i: int) -> int:
	if i < 0 or i >= levels().size():
		return 0
	var m: ArrayMesh = levels()[i]
	var n := 0
	for si in m.get_surface_count():
		var idx = m.surface_get_arrays(si)[Mesh.ARRAY_INDEX]
		n += (idx as PackedInt32Array).size() / 3 if idx != null else (m.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


## Show level `i`.
func set_lod(i: int) -> void:
	lod = clampi(i, 0, maxi(levels().size() - 1, 0))
	_place()


## A mode of MODES.
func set_mode(m: String) -> void:
	if MODES.has(m):
		mode = m
		_place()


## The leaves' alpha cut, live (no preparation).
func set_alpha_cut(v: float) -> void:
	var c: ArrayMesh = parts.get("combined")
	if c == null:
		return
	for si in c.get_surface_count():
		var m := c.surface_get_material(si) as ShaderMaterial
		if m != null and float(m.get_shader_parameter("foliage_mask")) > 0.5:
			m.set_shader_parameter("alpha_cut", v)


## The trunk ring at radius `r` (none at 0).
func set_trunk(r: float) -> void:
	var cm := _ring.mesh as CylinderMesh
	cm.top_radius = maxf(r, 0.001)
	cm.bottom_radius = maxf(r, 0.001)
	_ring.visible = r > 0.0 and not parts.is_empty()


## What the card modes say instead of (or over) the card; "" when the card is current.
func card_note() -> String:
	if parts.is_empty():
		return "Nothing to draw: the mesh is missing." if sp != null else ""
	if String(sp.kind) == "bush":
		return "A bush has no card."
	if (parts.get("ring", {}) as Dictionary).is_empty():
		return "Build to make the card."
	if _state == "needs":
		return "Changed since the bake: Build to see the new card."
	return ""


## The view (column, row) of the sheets the card draws for the camera now.
func view_cell() -> Vector2i:
	return BakerRes.view_cell((_cam_l.transform.origin - _target()).normalized())


## The camera's height above the horizon (degrees).
func elevation_deg() -> float:
	return pitch


## The camera's distance from the tree's centre (m).
func distance() -> float:
	return dist if dist > 0.0 else _framed


## A camera `dist` metres from `target`, `yaw_deg` round from +Z and `pitch_deg` above the horizon, looking at it.
static func orbit(yaw_deg: float, pitch_deg: float, d: float, target: Vector3) -> Transform3D:
	var y := deg_to_rad(yaw_deg)
	var p := deg_to_rad(pitch_deg)
	var dir := Vector3(sin(y) * cos(p), sin(p), cos(y) * cos(p))
	var pos := target + dir * d
	return Transform3D(Basis.looking_at(target - pos, Vector3.UP), pos)


func _target() -> Vector3:
	return _centre


## Everything placed for the species, the mode, the level and the camera.
func _place() -> void:
	var has := not parts.is_empty()
	_model.mesh = levels()[lod] if has and not levels().is_empty() else null
	var card: Dictionary = parts.get("card", {})
	var ring_ok := has and not (parts.get("ring", {}) as Dictionary).is_empty() and not card.is_empty()
	_card.mesh = card.get("mesh") if ring_ok else null
	_card.material_override = card.get("mat") if ring_ok else null
	_card.visible = ring_ok
	if has:
		var ab := (parts["combined"] as ArrayMesh).get_aabb()
		_centre = ab.get_center()
		_framed = maxf(ab.size.length() * 0.5, 0.5) / sin(deg_to_rad(FOV_DEG) * 0.5)
		_ground.scale = Vector3.ONE * maxf(ab.size.x, ab.size.z) * 0.9
		var h := ab.size.y
		(_ring.mesh as CylinderMesh).height = minf(h * 0.4, 4.0)
		_ring.position = Vector3(0.0, minf(h * 0.4, 4.0) * 0.5, 0.0)
		set_trunk(float(sp.trunk_radius))
	else:
		_ring.visible = false
	var both := mode == "compare"
	_right.visible = both
	_cam_l.cull_mask = GROUND_LAYER | (CARD_LAYER if mode == "card" else MODEL_LAYER)
	_cam_r.cull_mask = GROUND_LAYER | CARD_LAYER
	var sheets := mode == "sheets"
	(get_node("Views") as Control).visible = not sheets
	_sheets.visible = sheets
	var ring: Dictionary = parts.get("ring", {})
	(_sheets.get_node("Albedo") as TextureRect).texture = ring.get("albedo")
	(_sheets.get_node("Normal") as TextureRect).texture = ring.get("normal")
	_note.text = card_note() if mode != "model" else ("Nothing to draw: the mesh is missing." if sp != null and not has else "")
	_aim()


func _aim() -> void:
	var t := orbit(yaw, pitch, distance(), _target())
	_cam_l.transform = t
	_cam_r.transform = t
	_cam_l.far = distance() * 4.0 + 50.0
	_cam_r.far = _cam_l.far
	_place_outline()
	camera_moved.emit()


func _place_outline() -> void:
	var on := mode == "sheets" and not (parts.get("ring", {}) as Dictionary).is_empty()
	_outline.visible = on
	if not on:
		return
	var tr := _sheets.get_node("Albedo") as TextureRect
	var cell := view_cell()
	var side := minf(tr.size.x, tr.size.y)
	var origin := tr.position + (tr.size - Vector2(side, side)) * 0.5
	var px := side / float(BakerRes.GRID)
	_outline.position = origin + Vector2(cell) * px
	_outline.size = Vector2(px, px)


func _gui_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null:
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_drag = mb.pressed
			if mb.pressed and mb.double_click:
				yaw = DEFAULT_YAW
				pitch = DEFAULT_PITCH
				dist = 0.0
				_aim()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = distance() * 0.9
			_aim()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = distance() * 1.1
			_aim()
		accept_event()
		return
	var mm := ev as InputEventMouseMotion
	if mm != null and _drag:
		yaw -= mm.relative.x * 0.4
		pitch = clampf(pitch + mm.relative.y * 0.4, -5.0, 85.0)
		_aim()
		accept_event()
