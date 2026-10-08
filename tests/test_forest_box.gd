# Copyright (c) 2026 Digitzone
# SPDX-License-Identifier: MIT
extends RefCounted
## The frame's box: the commit and the card flush draw on one deadline; the commit checks it between
## species slots and the flush between a card cell's species; the box's first commit and first flush item land whatever
## the clock says; a card cell stays touched until its last species is in and starts over when touched again; a cell
## released while touched gains no block; the catch-up box is a fill's, never a drive's.
##
## Run with a unit-suite runner: static run() returns {name, passed, failed, details}.

const Veg := preload("res://addons/wuifwoud/forest_spawner.gd")


## The spawner with its installs recorded instead of drawn: the box's rules are the spawner's own code.
class Rec extends Veg:
	var slots: Array = []      # [chunk key, species] a commit installed
	var cards: Array = []      # [card cell, species] a flush installed
	var admitted: Array = []   # cells whose scatter job a stream tick submitted

	func _commit_slot(ck: Vector2i, mesh_name: String, _bucket: Vector2i, _packed: Dictionary, _chunk: Dictionary) -> int:
		slots.append([ck, mesh_name])
		OS.delay_usec(300)
		return 1

	func _flush_card_slot(bc: Vector2i, mesh_name: String) -> void:
		cards.append([bc, mesh_name])
		OS.delay_usec(300)

	func _scatter_cell(k: Vector2i, cells: Dictionary, _cell_m: float, _bb_tier: bool) -> void:
		admitted.append(k)
		cells[k] = {"pts": [], "done": true, "nodes": []}
		OS.delay_usec(300)


## The GPU path's arenas, recording what a fill's end asks of them.
class FakeInd extends Node3D:
	var reserved: Array = []
	var realloc_limit := 0
	var realloc_free_once := false

	func reserve_tier(tier: int, mult: float) -> void:
		reserved.append([tier, mult])


static func _chk(r: Dictionary, n: String, ok: bool) -> void:
	if ok:
		r.passed += 1
	else:
		r.failed += 1
		r.details.append("✗ " + n)


## A finished place job for chunk `k` of `cells` with `n` species slots and no trunks, crowns or cards.
static func _job(cells: Dictionary, k: Vector2i, n: int) -> Dictionary:
	var entry := {"pts": [], "done": false, "nodes": [], "placing": true}
	cells[k] = entry
	var species := {}
	for i in n:
		species["0,0/S%d" % i] = {"buf": PackedFloat32Array(), "n": 1, "mesh": "S%d" % i, "bucket": Vector2i.ZERO}
	return {"cells": cells, "key": k, "entry": entry, "species": species, "bbs": {}, "trunks": {}, "crowns": {}}


static func run() -> Dictionary:
	var r := {"name": "forest_box", "passed": 0, "failed": 0, "details": []}
	var v := Rec.new()

	# ── the commit: the box's first slot lands however late; then the deadline, between slots ──
	v.commit_budget_ms = 0.0                     # a box that has already run out
	v._filling = false
	for i in 3:
		v._place_ready.append(_job(v._chunks, Vector2i(i, 0), 4))
	v._collect_place()
	var after_one := v.slots.size()
	v._collect_place()
	var after_two := v.slots.size()
	v.commit_budget_ms = 1000.0
	v._collect_place()
	_chk(r, "a spent box still lands its first slot, one a call; a box with room lands every slot (%d, %d, %d of 12)" % [
		after_one, after_two, v.slots.size()],
		after_one == 1 and after_two == 2 and v.slots.size() == 12 and v._place_ready.is_empty()
		and v._chunks.values().all(func(c): return bool(c["done"])))

	# ── the flush: one card cell's species at a time, a cell touched until its last species is in ──
	var a := Vector2i(0, 0)
	var b := Vector2i(1, 0)
	for c in [a, b]:
		v._bb_cells[c] = {"pts": [], "done": true, "nodes": []}
		v._bb_accum[c] = {"P": {}, "Q": {}, "R": {}}
		v._bb_touched[c] = true
	v.commit_budget_ms = 0.0
	v._flush_billboards()
	var one: Array = v.cards.duplicate()
	var still_a := v._bb_touched.has(a)
	v.commit_budget_ms = 1.0                     # ~3 species at 0.3 ms each
	v._flush_billboards()
	var two := v.cards.size()
	v.commit_budget_ms = 1000.0
	v._flush_billboards()
	_chk(r, "the flush lands a cell's species one at a time under the box, the first always; a cell stays touched until its last species (%s; %d; %d of 6)" % [
		str(one), two, v.cards.size()],
		one == [[a, "P"]] and still_a and two > 1 and two < 6 and v.cards.size() == 6 and v._bb_touched.is_empty()
		and v._bb_left.is_empty())

	# Touched again while part-flushed: every species again. Released while touched: nothing for it.
	v.cards.clear()
	v._bb_touched[a] = true
	v.commit_budget_ms = 0.0
	v._flush_billboards()                        # P
	v._bb_touched[a] = true                      # a job landed for it meanwhile (_commit_place's touch)
	v._bb_left.erase(a)
	v.commit_budget_ms = 1000.0
	v._flush_billboards()
	var again: Array = v.cards.map(func(x): return x[1])
	v.cards.clear()
	v._bb_touched[b] = true
	v._bb_cells.erase(b)                         # released while touched
	v._flush_billboards()
	_chk(r, "a cell touched again while part-flushed flushes every species again; one released while touched, none (%s; %d)" % [
		str(again), v.cards.size()],
		again == ["P", "P", "Q", "R"] and v.cards.is_empty() and not v._bb_accum.has(b) and v._bb_touched.is_empty())

	# ── in the pump's frame (its box open) the commit leaves the card flush to the frame's end, after the resolve, so the
	#    flush takes what the box has left; a direct call (the editor preview, tests) still flushes when it returns ──
	v.cards.clear()
	v._bb_cells[a] = {"pts": [], "done": true, "nodes": []}
	var pj := _job(v._chunks, Vector2i(7, 0), 1)
	pj["bbs"] = {a: {"P": {}}}
	v._place_ready.append(pj)
	v.commit_budget_ms = 1000.0
	v._box_open()
	v._collect_place()
	var in_frame := v.cards.size()
	v._flush_billboards()
	var at_end := v.cards.size()
	v._box_until_us = 0
	v.cards.clear()
	var dj := _job(v._chunks, Vector2i(8, 0), 1)
	dj["bbs"] = {a: {"Q": {}}}
	v._place_ready.append(dj)
	v._collect_place()
	var direct := v.cards.size()
	_chk(r, "in the pump's frame the commit leaves the flush to the frame's end; a direct call flushes on return (%d, %d, %d)" % [
		in_frame, at_end, direct], in_frame == 0 and at_end >= 1 and direct >= 1 and v._bb_touched.is_empty())

	# ── one box for both: what the commit spent, the flush does not get ──
	v.cards.clear()
	v.slots.clear()
	v._bb_cells[b] = {"pts": [], "done": true, "nodes": []}
	v._bb_accum[b] = {"P": {}, "Q": {}, "R": {}}
	v._bb_touched[b] = true
	v._place_ready.append(_job(v._chunks, Vector2i(5, 0), 6))
	v.commit_budget_ms = 1.0
	v._box_open()
	v._collect_place()                            # the commit spends the box; its trailing flush gets its floor only
	v._flush_billboards()                         # the same box: spent
	v._box_until_us = 0
	_chk(r, "the commit and the flush share one box: a spent box leaves the flush its first item only (%d slots, %d cards)" % [
		v.slots.size(), v.cards.size()], v.slots.size() >= 1 and v.slots.size() < 6 and v.cards.size() == 1)

	# ── the stream tick (its `stream` row): while driving, a ring step's cells are open at once and their jobs
	#    submitted under the stream's share, the first always; one released meanwhile, never; a fill, all at once ──
	v._filling = false
	var ring := {}
	v._stream_ring(Vector2(32.0, 32.0), ring, 64.0, 200.0, false)
	var entered := ring.size()
	var open_now := ring.values().all(func(e): return not bool(e["done"]) and bool(e.get("admitting", false)))
	v._admit_pending()
	var first_tick := v.admitted.size()
	var gone: Vector2i = (v._admit_queue.back() as Array)[1]
	v._release_cell(gone, ring, false)
	for _t in 200:
		v._admit_pending()
	var filled := {}
	v.admitted.clear()
	v._filling = true
	v._stream_ring(Vector2(32.0, 32.0), filled, 64.0, 200.0, false)
	_chk(r, "while driving a ring step's cells are open at once, their jobs under the stream's share (%d of %d the first tick), one released meanwhile never; a fill scatters all at once (%d)" % [
		first_tick, entered, v.admitted.size()],
		entered > 10 and open_now and first_tick >= 1 and first_tick < entered and not ring.has(gone)
		and ring.size() == entered - 1 and ring.values().all(func(e): return bool(e["done"]))
		and v.admitted.size() == filled.size() and v._admit_queue.is_empty())
	v.admitted.clear()

	# ── a fill's end reserves both tiers' arenas once its cards are drawn, never while driving, again
	#    after the next fill ──
	var fi := FakeInd.new()
	v._indirect = fi
	v._bb_touched.clear()
	v._filling = true
	v._reserve_after_fill()                      # still filling: nothing yet
	var res_during := fi.reserved.size()
	v._filling = false
	v._bb_touched[Vector2i(9, 9)] = true
	v._reserve_after_fill()                      # every cell resolved, its cards not all drawn: not yet
	var res_undrawn := fi.reserved.size()
	v._bb_touched.clear()
	v._reserve_after_fill()                      # drawn: once
	var lifted := fi.realloc_free_once
	fi.realloc_free_once = false
	v._reserve_after_fill()                      # driving: never again
	var res_once: Array = fi.reserved.duplicate()
	var drive_limit := fi.realloc_limit
	v._filling = true
	v._reserve_after_fill()
	v._filling = false
	v._reserve_after_fill()                      # the next fill's end: again
	var res_twice := fi.reserved.size()
	v._filling = true
	v._reserve_after_fill()
	var fill_limit := fi.realloc_limit
	v._indirect = null
	fi.free()
	_chk(r, "a fill's end reserves the card and the mesh arenas once its cards are drawn, %.0fx; never while driving; again after the next fill (%s; %d)" % [
		Veg.ARENA_RESERVE_MULT, str(res_once), res_twice],
		res_during == 0 and res_undrawn == 0 and res_once == [[1, 3.0], [0, 3.0]] and Veg.ARENA_RESERVE_MULT == 3.0
		and res_twice == 4)
	_chk(r, "the arenas' pacing: one GPU rebuild a frame while driving, none limited while filling, lifted once at a fill's end (%d %d %s)" % [
		drive_limit, fill_limit, lifted], drive_limit == 1 and fill_limit == 0 and lifted)

	# ── the near forest is busy until its cards are drawn: the far forest starts and plans nothing meanwhile, so the
	#    first fill's card flush keeps the frame's box ──
	v._settled = true
	v._bb_touched.clear()
	var nb_idle: bool = v.near_busy()
	v._bb_touched[Vector2i(3, 3)] = true
	var nb_cards: bool = v.near_busy()
	v._bb_touched.clear()
	_chk(r, "the near forest is busy while its cards are not all drawn, idle once they are (%s, %s)" % [nb_cards, nb_idle],
		nb_cards and not nb_idle)

	# ── the catch-up box: a fill's, never a drive's ──
	v.commit_budget_ms = 2.5
	v.commit_budget_catchup_mult = 3.2
	v._mesh_frontier_m = 40.0
	v._filling = true
	var fill_box: float = v._commit_box_ms()
	v._filling = false
	var drive_box: float = v._commit_box_ms()
	v._filling = false
	v.rebuild_for_quality()
	var rebuilt: bool = v._filling
	v._filling = false
	v.regrow_all()
	var regrown: bool = v._filling
	_chk(r, "the catch-up box while the ring fills, the base box while driving; a quality rebuild and a Re-grow are fills (%.1f %.1f %s %s)" % [
		fill_box, drive_box, rebuilt, regrown],
		is_equal_approx(fill_box, 8.0) and is_equal_approx(drive_box, 2.5) and rebuilt and regrown)
	v.free()
	return r
