# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
@tool
class_name ForestHizPyramid
extends RefCounted
## A hierarchical-Z pyramid built from the frame's resolved depth, for the GPU-driven
## vegetation cull to reject instances hidden behind terrain and other trees.
##
## WHY THIS EXISTS. The forest's compute cull tests distance and frustum only, so on a
## wooded slope it submits every tree in front of the camera whether or not anything is in
## the way. Measured on a 50 km² island: ~10 700 mesh trees inside 300 m, of which the frustum
## keeps roughly a third and, at ground level in a closed canopy, a few hundred contribute
## pixels. The rest are drawn and depth-rejected: cheap in the opaque pass because of the
## depth prepass, but they still pay full vertex processing and alpha-test shading in the
## prepass itself, which is where 2.42 ms of the forest's cost sits.
##
## Godot's own occlusion culling cannot reach them: on the indirect path each BAND is one
## RenderingServer instance whose AABB is a camera-centred box the size of the band, so it
## is never occluded, and per-instance occlusion never happens at all. An OccluderInstance3D
## in the scene does nothing for the forest.
##
## FOUR THINGS MEASURED FIRST (a depth-access probe), because each
## one changes the code and none of them is safe to assume:
##   * `RenderSceneBuffersRD.get_depth_texture()` from a POST_OPAQUE compositor callback is
##     a valid RID.
##   * With `access_resolved_depth = true` it comes back RESOLVED even under MSAA 2x:
##     format R32_SFLOAT, SAMPLING and STORAGE usage, no depth-attachment bit. So it can be
##     bound straight into a compute pass as an image, with no sampler and no resolve of
##     our own.
##   * Its size is the viewport's INTERNAL size, i.e. after 3D scaling, not the target.
##   * REVERSE-Z: z(1 m) = 0.049988 vs z(1000 m) = 0.000037. Near is larger.
##
## ONE FRAME OF LATENCY, BY CONSTRUCTION. The depth this reads is the previous frame's:
## the cull for frame N runs on the render thread before frame N has drawn anything. That
## is the normal arrangement for GPU-driven culling and the reason every rounding choice
## here is conservative: a stale pyramid must never cull something that turned out to be
## visible, or the world develops holes when the camera turns.

const _SHADER := "res://addons/wuifwoud/shaders/hiz_build.glsl"
## Start the pyramid at half the depth buffer. The cull tests bounding spheres, not
## silhouettes, so the top mip's precision is wasted on it, and halving first makes the
## whole build a quarter of the work.
const FIRST_DIVISOR := 2
## Below this the reduction costs more in dispatch overhead than it saves.
const MIN_MIP_PX := 8

var _rd: RenderingDevice = null
var _shader := RID()
var _pipeline := RID()
var _tex := RID()
var _mip_views: Array[RID] = []
var _sampler := RID()
var _size := Vector2i.ZERO
var _mips := 0
var _uniform_sets: Array[RID] = []

## The view-projection the pyramid was built with, and the frame it was built on. The cull
## must project instances with THIS matrix, not the current one, or it tests against a
## picture taken from somewhere else.
var view_projection := Projection()
## The frame the pyramid was last built in (-1: never).
var built_frame := -1


## Whether a pyramid has been built.
func is_ready() -> bool:
	return _tex.is_valid() and _mips > 0


## The pyramid's texture.
func texture() -> RID:
	return _tex


## The sampler the cull reads it with.
func sampler() -> RID:
	return _sampler


## The size of its top mip.
func size() -> Vector2i:
	return _size


## How many mips it has.
func mip_count() -> int:
	return _mips


## ONE PYRAMID FOR THE WHOLE FRAME. Every VegetationIndirect field on the path has its own
## compositor effect, and all of them want the same picture: building it once each would pay
## for it again and produce identical textures. Whoever gets there first on a given frame
## builds it.
static var _shared = null


## The one pyramid every field shares.
static func shared():
	if _shared == null:
		# `new()` on the script itself, not on the class_name: this file must load even when
		# the editor's global class cache has not caught up with it.
		_shared = (load("res://addons/wuifwoud/forest_hiz_pyramid.gd") as GDScript).new()
	return _shared


## Render thread only. `depth` is the resolved depth texture for this frame, `vp` the full
## view-projection it was rendered with (projection * inverse camera transform), not the
## projection alone, which is a mistake that leaves everything projected as if the camera sat
## at the origin looking down -Z.
func build(rd: RenderingDevice, depth: RID, depth_size: Vector2i, vp: Projection, frame: int) -> void:
	if rd == null or not depth.is_valid() or depth_size.x <= 0 or depth_size.y <= 0:
		return
	if frame == built_frame:
		return
	_rd = rd
	var want := Vector2i(maxi(depth_size.x / FIRST_DIVISOR, 1), maxi(depth_size.y / FIRST_DIVISOR, 1))
	if not _tex.is_valid() or want != _size:
		_alloc(want)
	if not _tex.is_valid():
		return

	# Uniform sets resolve BEFORE the list opens: _set_for may create (and replace)
	# sets/views, and creating or freeing resources during compute-list construction
	# is forbidden. The src chain (depth, then each mip's view) is deterministic, so
	# the whole pass binds pre-built sets only.
	var src := depth
	var src_size := depth_size
	var sets: Array = []
	for m in _mips:
		var us0 := _set_for(m, src)
		sets.append(us0)
		src = _mip_views[m]
	src = depth
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	for m in _mips:
		var dst_size := _mip_size(m)
		var us: RID = sets[m]
		if not us.is_valid():
			break
		rd.compute_list_bind_uniform_set(cl, us, 0)
		var pc := PackedInt32Array([dst_size.x, dst_size.y, src_size.x, src_size.y]).to_byte_array()
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, (dst_size.x + 7) / 8, (dst_size.y + 7) / 8, 1)
		# Each level reads what the previous one just wrote.
		rd.compute_list_add_barrier(cl)
		src = _mip_views[m]
		src_size = dst_size
	rd.compute_list_end()

	view_projection = vp
	built_frame = frame


## Free the pyramid's GPU resources (render thread).
func free_all() -> void:
	if _rd == null:
		return
	for u in _uniform_sets:
		if u.is_valid():
			_rd.free_rid(u)
	_uniform_sets.clear()
	for v in _mip_views:
		if v.is_valid():
			_rd.free_rid(v)
	_mip_views.clear()
	for r in [_tex, _sampler, _pipeline, _shader]:
		if (r as RID).is_valid():
			_rd.free_rid(r)
	_tex = RID()
	_sampler = RID()
	_pipeline = RID()
	_shader = RID()
	_mips = 0
	_size = Vector2i.ZERO


func _mip_size(m: int) -> Vector2i:
	return Vector2i(maxi(_size.x >> m, 1), maxi(_size.y >> m, 1))


func _alloc(want: Vector2i) -> void:
	free_all()
	_size = want
	_mips = 1
	while mini(_mip_size(_mips).x, _mip_size(_mips).y) >= MIN_MIP_PX and _mips < 14:
		_mips += 1

	var f := RDTextureFormat.new()
	f.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	f.width = _size.x
	f.height = _size.y
	f.depth = 1
	f.array_layers = 1
	f.mipmaps = _mips
	f.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	# STORAGE to write each level, SAMPLING so the cull can textureLod across levels,
	# CAN_COPY_FROM so a probe can read it back and check the thing actually contains depth.
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_tex = _rd.texture_create(f, RDTextureView.new(), [])
	if not _tex.is_valid():
		push_error("[Hiz] texture_create failed")
		return

	_mip_views.clear()
	for m in _mips:
		_mip_views.append(_rd.texture_create_shared_from_slice(
			RDTextureView.new(), _tex, 0, m, 1, RenderingDevice.TEXTURE_SLICE_2D))

	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)

	# Built before any uniform set needs it: the source binding is sampled now, so the
	# sampler is not optional.
	var src_file := load(_SHADER) as RDShaderFile
	if src_file == null:
		push_error("[Hiz] cannot load %s" % _SHADER)
		return
	_shader = _rd.shader_create_from_spirv(src_file.get_spirv())
	_pipeline = _rd.compute_pipeline_create(_shader)
	_uniform_sets.resize(_mips)
	for i in _mips:
		_uniform_sets[i] = RID()


## One uniform set per level. They are rebuilt whenever the source changes, which for level
## 0 is every frame: the engine hands out a different depth RID as buffers are recreated,
## and a set cached against a freed RID is a crash, not a stale picture.
func _set_for(m: int, src: RID) -> RID:
	if m < _uniform_sets.size() and _uniform_sets[m].is_valid():
		if m > 0:
			return _uniform_sets[m]
		_rd.free_rid(_uniform_sets[m])
		_uniform_sets[m] = RID()

	var a := RDUniform.new()
	a.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	a.binding = 0
	a.add_id(_sampler)
	a.add_id(src)
	var b := RDUniform.new()
	b.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	b.binding = 1
	b.add_id(_mip_views[m])
	var us := _rd.uniform_set_create([a, b], _shader, 0)
	if m < _uniform_sets.size():
		_uniform_sets[m] = us
	return us
