# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
extends RefCounted
## A species' picture for the editor's tiles: its dressed mesh (ForestAssets._dress) under a fixed sun and sky, from a
## three-quarter view (ELEVATION_DEG above the horizon, YAW_DEG round from +Z), the whole tree framed, rendered at
## RENDER_PX on a transparent background and box-filtered to PX by finish() (image work: a worker may run it). Like the
## impostor baker it renders in a SubViewport under a host and is read `settle` drawn frames after it begins; the caller
## draws the frames and calls step() once after each. The pack build makes one a species, beside its sheets.

## The picture's size in pixels.
const PX := 256
## The rendered size: twice PX, box-filtered down (the edge antialiasing; an MSAA resolve against the clear background
## would darken every edge).
const RENDER_PX := 512
## The view's height above the horizon (degrees).
const ELEVATION_DEG := 20.0
## The view's turn round the tree from +Z (degrees).
const YAW_DEG := 35.0
## The camera's field of view (degrees).
const FOV_DEG := 30.0
## Frames drawn before the picture is read (the species' mesh and materials are new to the renderer).
const SETTLE := 6
## The sun: pitch and yaw (degrees).
const SUN_DEG := Vector2(-48.0, 150.0)

## Frames drawn before the picture is read (tests may lower it).
var settle := SETTLE
var _vp: SubViewport = null
var _cam: Camera3D = null
var _subject: MeshInstance3D = null
var _ab := AABB()
var _wait := 0
var _busy := false
var _reaim := false
var _raw: Image = null


## The viewport under `host` (the editor's base control, the command line's root, a render suite's host).
func setup(host: Node) -> void:
	var world := World3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.70, 0.76, 0.86)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = env
	_vp = SubViewport.new()
	_vp.size = Vector2i(RENDER_PX, RENDER_PX)
	_vp.world_3d = world
	_vp.transparent_bg = true
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(_vp)
	_cam = Camera3D.new()
	_cam.fov = FOV_DEG
	_vp.add_child(_cam)
	_cam.current = true
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(SUN_DEG.x, SUN_DEG.y, 0.0)
	sun.light_energy = 1.1
	# NO SHADOW: a shadowed render came out a few pixels different from one build to the next (its filtering), and the
	# picture must be the same bytes whoever builds it, every time.
	sun.shadow_enabled = false
	_vp.add_child(sun)
	_subject = MeshInstance3D.new()
	_vp.add_child(_subject)


## Starts the picture of `dressed` (a species' combined mesh with its own materials); false when it has no surface.
func begin(dressed: ArrayMesh) -> bool:
	if dressed == null or dressed.get_surface_count() == 0:
		return false
	_subject.mesh = dressed
	_ab = dressed.get_aabb()
	_cam.transform = camera_for(_ab)
	_wait = settle
	_reaim = true
	_busy = true
	_raw = null
	return true


## Once after each drawn frame: true when the picture is read (or none is being made).
func step() -> bool:
	if not _busy:
		return true
	if _reaim:
		# A camera placed in the frame the picture begins can miss its first aim (the impostor baker measured it):
		# placed again once a frame has been drawn.
		_reaim = false
		_cam.transform = camera_for(_ab)
	_wait -= 1
	if _wait > 0:
		return false
	_raw = _vp.get_texture().get_image()
	_busy = false
	return true


## The render at RENDER_PX (null until step() read it); finish() makes the stored picture of it.
func result() -> Image:
	return _raw


## Whether a picture is being made.
func busy() -> bool:
	return _busy


## Stop now.
func abort() -> void:
	_busy = false


## Free the viewport.
func free_nodes() -> void:
	if _vp != null and is_instance_valid(_vp):
		_vp.queue_free()
	_vp = null


## The camera framing bounds `ab` from the picture's view: the bounds' sphere fills the view.
static func camera_for(ab: AABB) -> Transform3D:
	var centre := ab.get_center()
	var r := maxf(ab.size.length() * 0.5, 0.01)
	var dist := r / sin(deg_to_rad(FOV_DEG) * 0.5)
	var el := deg_to_rad(ELEVATION_DEG)
	var yaw := deg_to_rad(YAW_DEG)
	var dir := Vector3(sin(yaw) * cos(el), sin(el), cos(yaw) * cos(el))
	var pos := centre + dir * dist
	return Transform3D(Basis.looking_at(centre - pos, Vector3.UP), pos)


## The stored picture of a render: PX square, box-filtered in premultiplied alpha (so the clear background puts no dark
## fringe on the edges), then straight again for drawing. Null for none. Image work only.
static func finish(src: Image) -> Image:
	if src == null or src.is_empty():
		return null
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	img.premultiply_alpha()
	img.resize(PX, PX, Image.INTERPOLATE_BILINEAR)
	for y in PX:
		for x in PX:
			var c := img.get_pixel(x, y)
			if c.a > 0.0 and c.a < 1.0:
				img.set_pixel(x, y, Color(c.r / c.a, c.g / c.a, c.b / c.a, c.a))
	return img
