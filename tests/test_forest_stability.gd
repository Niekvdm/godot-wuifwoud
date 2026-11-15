# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## Distance stability: what the forest does with its viewport's anti-aliasing. The alpha-to-coverage variants are the
## shaders' own source with one define, placed before the render mode it selects; a temporal filter is TAA or an
## upscaler that accumulates (FSR2, MetalFX temporal), not a spatial one; the hand-over share follows it
## (handover_frac with one, handover_frac_native without); the mesh trees' pushes skip the card materials that share
## their list; the A2C switch moves leaves and cards and leaves bark; the forest's frame tick reads the viewport and
## switches the dither, the hand-over and A2C; the cull's globals carry the LOD jitter; a far cell's material gets the
## cost switches, the still mode and its height span.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")
const VA := preload("res://addons/wuifwoud/forest_assets.gd")
const Ind := preload("res://addons/wuifwoud/forest_indirect.gd")
const FarRes := preload("res://addons/wuifwoud/forest_far.gd")
const ForestConfigRes := preload("res://addons/wuifwoud/forest_config.gd")


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


static func run() -> Dictionary:
	var r := {"name": "forest_stability", "passed": 0, "failed": 0, "details": []}
	# The variant's source: one define right after the shader_type line, before the render mode.
	var code := "// c\nshader_type spatial;\n#ifdef WF_A2C\nrender_mode a;\n#else\nrender_mode b;\n#endif\n"
	_chk(r, "a2c_code puts the define after the shader_type line",
		VA.a2c_code(code) == "// c\nshader_type spatial;\n#define WF_A2C\n#ifdef WF_A2C\nrender_mode a;\n#else\nrender_mode b;\n#endif\n")
	for pair in [[VA._wind_shader_res(), VA.wind_shader_a2c()], [VA._billboard_shader_res(), VA.billboard_shader_a2c()]]:
		var base: Shader = pair[0]
		var v: Shader = pair[1]
		var at := v.code.find("\n#define WF_A2C\n")
		_chk(r, "%s: its variant defines WF_A2C once, before its render mode, and is otherwise the same source"
			% base.resource_path.get_file(),
			v.code.count("\n#define WF_A2C\n") == 1 and at > v.code.find("shader_type") and at < v.code.find("render_mode")
			and v.code.replace("\n#define WF_A2C\n", "\n") == base.code and base.code.contains("#ifdef WF_A2C"))

	# A temporal filter: TAA, FSR2, MetalFX temporal; not bilinear, FSR 1, MetalFX spatial; none without a viewport.
	var vp := SubViewport.new()
	var cases := [[false, Viewport.SCALING_3D_MODE_BILINEAR, false], [true, Viewport.SCALING_3D_MODE_BILINEAR, true],
		[false, Viewport.SCALING_3D_MODE_FSR2, true], [false, Viewport.SCALING_3D_MODE_METALFX_TEMPORAL, true],
		[false, Viewport.SCALING_3D_MODE_FSR, false], [false, Viewport.SCALING_3D_MODE_METALFX_SPATIAL, false]]
	var ok := not Veg.temporal_filter_on(null)
	for c in cases:
		vp.use_taa = c[0]
		vp.scaling_3d_mode = c[1]
		ok = ok and Veg.temporal_filter_on(vp) == c[2]
	vp.free()
	_chk(r, "a temporal filter is TAA, FSR2 or MetalFX temporal (and nothing without a viewport)", ok)

	# The hand-over share follows the filter.
	var vs = Veg.new()
	vs.handover_frac = 0.3
	vs.handover_frac_native = 0.02
	vs._aa_temporal = true
	var with_f: float = vs._handover_frac_now()
	vs._aa_temporal = false
	var without_f: float = vs._handover_frac_now()
	_chk(r, "the hand-over share is handover_frac under a temporal filter (%.2f), handover_frac_native without (%.2f)"
		% [with_f, without_f], is_equal_approx(with_f, 0.3) and is_equal_approx(without_f, 0.02))

	# push_lod_params: the mesh trees' numbers onto the tree materials, never onto a card's (same list, same names).
	var saved: Array = VA._live_materials.duplicate()
	VA._live_materials.clear()
	var tree_m := ShaderMaterial.new()
	tree_m.resource_name = "W_StabilityTree"
	var card_m := ShaderMaterial.new()
	card_m.resource_name = "W_StabilityTree"
	card_m.set_meta(&"wf_card", true)
	card_m.set_shader_parameter("thin_start_m", 1200.0)
	card_m.set_shader_parameter("thin_max", 0.55)
	VA._live_materials.append_array([tree_m, card_m])
	vs.foliage_thin_start_m = 80.0
	vs.foliage_thin_max = 0.6
	vs.leaf_mip_alpha = 0.3
	vs.thin_coverage = 0.7
	vs.push_lod_params()
	_chk(r, "a card keeps its own thinning through push_lod_params (thin_start_m %s, thin_max %s)"
		% [str(card_m.get_shader_parameter("thin_start_m")), str(card_m.get_shader_parameter("thin_max"))],
		is_equal_approx(float(card_m.get_shader_parameter("thin_start_m")), 1200.0)
		and is_equal_approx(float(card_m.get_shader_parameter("thin_max")), 0.55))
	_chk(r, "a tree material gets the thinning, the coverage pair and the hand-over share (no filter: native)",
		is_equal_approx(float(tree_m.get_shader_parameter("thin_start_m")), 80.0)
		and is_equal_approx(float(tree_m.get_shader_parameter("leaf_mip_scale")), 0.3)
		and is_equal_approx(float(tree_m.get_shader_parameter("thin_coverage")), 0.7)
		and is_equal_approx(float(tree_m.get_shader_parameter("handover_frac")), 0.02))
	vs._push_handover()
	_chk(r, "_push_handover reaches the card too (%s)" % str(card_m.get_shader_parameter("handover_frac")),
		is_equal_approx(float(card_m.get_shader_parameter("handover_frac")), 0.02))
	vs.free()

	# The A2C switch: leaves and cards onto their variants and back; bark stays.
	var leaf := ShaderMaterial.new()
	leaf.shader = VA._wind_shader_res()
	leaf.set_shader_parameter("foliage_mask", 1.0)
	leaf.set_shader_parameter("alpha_cut", 0.5)
	var bark := ShaderMaterial.new()
	bark.shader = VA._wind_shader_res()
	bark.set_shader_parameter("foliage_mask", 0.0)
	var card := ShaderMaterial.new()
	card.shader = VA._billboard_shader_res()
	card.set_meta(&"wf_card", true)
	VA._live_materials.clear()
	VA._live_materials.append_array([leaf, bark, card])
	VA.set_alpha_to_coverage(true)
	_chk(r, "A2C on: leaves and cards on their variants, bark on the opaque shader",
		leaf.shader == VA.wind_shader_a2c() and card.shader == VA.billboard_shader_a2c()
		and bark.shader == VA._wind_shader_res())
	_chk(r, "a material keeps its parameters across the swap (alpha_cut %s)" % str(leaf.get_shader_parameter("alpha_cut")),
		is_equal_approx(float(leaf.get_shader_parameter("alpha_cut")), 0.5))
	VA.set_alpha_to_coverage(false)
	_chk(r, "A2C off: every material back on its opaque shader",
		leaf.shader == VA._wind_shader_res() and card.shader == VA._billboard_shader_res()
		and bark.shader == VA._wind_shader_res())

	# The frame tick reads the viewport: TAA moves the dither and takes the temporal hand-over; MSAA switches A2C on.
	var tree := Engine.get_main_loop() as SceneTree
	var root := tree.root
	var was := [root.use_taa, root.msaa_3d, root.scaling_3d_mode]
	root.use_taa = false
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	ForestConfigRes.use(ForestConfigRes.new())
	var vf: Node3D = Veg.new()
	vf.indirect_mmi = false
	vf.tree_collision = false
	vf.handover_frac = 0.3
	vf.msaa_alpha_to_coverage = true
	root.add_child(vf)
	await tree.process_frame
	await tree.process_frame
	var still := float(vf._dither_sent)
	root.use_taa = true
	root.msaa_3d = Viewport.MSAA_2X
	var seen := {}
	for i in 4:
		await tree.process_frame
		seen[vf._dither_sent] = true
	_chk(r, "no filter: the dither holds still (frame %.0f)" % still, still == 0.0)
	_chk(r, "under TAA the dither moves every frame (%d values in 4 frames)" % seen.size(), seen.size() >= 3)
	_chk(r, "under TAA a leaf takes handover_frac (%s)" % str(leaf.get_shader_parameter("handover_frac")),
		vf._aa_temporal and is_equal_approx(float(leaf.get_shader_parameter("handover_frac")), 0.3))
	_chk(r, "under MSAA the leaves are on the A2C variant", VA._a2c_on and leaf.shader == VA.wind_shader_a2c())
	vf.temporal_dither = false
	root.msaa_3d = Viewport.MSAA_DISABLED
	await tree.process_frame
	await tree.process_frame
	_chk(r, "temporal_dither off: still under TAA; MSAA off: A2C off",
		float(vf._dither_sent) == 0.0 and not VA._a2c_on and leaf.shader == VA._wind_shader_res())
	root.use_taa = was[0]
	root.msaa_3d = was[1]
	root.scaling_3d_mode = was[2]
	vf.queue_free()
	await tree.process_frame
	ForestConfigRes.use(null)
	VA._live_materials.clear()
	VA._live_materials.append_array(saved)

	# The cull's globals carry the LOD jitter (camera's w).
	var ind = Ind.new()
	ind.lod_jitter = 0.12
	var g: PackedFloat32Array = ind._globals_bytes().to_float32_array()
	_chk(r, "the cull's globals carry lod_jitter in the camera's w (%.3f)" % g[3], is_equal_approx(g[3], 0.12))
	ind.free()

	# A far cell's material: the cost switches and the height span of its mesh.
	var far = FarRes.new()
	far.set_opt(false, true)
	far.set_still_mode(true)
	far.set_late_draw(true)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(4.0, 6.0, 4.0)
	mi.mesh = bm
	mi.position = Vector3(0.0, 10.0, 0.0)
	var fm := ShaderMaterial.new()
	far._opt_to(fm, mi)
	var span: Vector2 = fm.get_shader_parameter("y_span")
	_chk(r, "a far cell's material gets the switches and its mesh's height span (%s)" % str(span),
		fm.get_shader_parameter("near_collapse") == false and fm.get_shader_parameter("layer_prune") == true
		and fm.get_shader_parameter("still_mode") == true and fm.render_priority == FarRes.LATE_PRIORITY
		and span.is_equal_approx(Vector2(7.0, 13.0)) and float(fm.get_shader_parameter("tri_reach_m")) > 16.0)
	mi.free()
	far.free()
	return r
