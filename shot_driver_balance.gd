extends Node
## Dev-only BALANCE HARNESS. Measures balance by running the REAL combat code
## (targeting, LOS, fire modes, projectile travel, abilities, decay chains)
## headless — nothing here re-implements a damage formula.
##
## Contract with the game: this driver only READS scripts/ and data/. It drives
## Main3D through the same entry points the UI uses (placing_id + _try_place,
## Tower3D.can_upgrade/next_cost/upgrade, WaveLoader.build_timeline + Main3D's
## own spawn runner). Nothing under scripts/, data/ or maps/ is modified.
##
## One process, many trials: project load is paid once. Every trial starts from
## _reset_board() and is checked by _verify_clean() — a leftover tower, enemy or
## in-flight shot silently corrupts every later number, so contamination is
## reported as a "!!" line rather than being absorbed into a reading. Section S
## proves that guard is not blind before anything else runs.
##
## Sections (select with BAL_SECTIONS, default all): S self-check, A dps matrix,
## B upgrade tiers, C control tower, D walking stream, E wave viability.
## BAL_E_LIMIT caps section E's wave count and BAL_DEBUG adds trial timings;
## both are iteration aids and change no measurement.
##
## Deterministic: seed(RNG_SEED) once, a fixed 1/60 s step, and no reliance on
## wall clock inside a trial. The one exception is section E's wall-clock budget,
## which SKIPS trailing waves on a machine too slow to finish them in time — that
## keeps the whole run near ten minutes at the cost of the tail's reproducibility.

# ---------------------------------------------------------------- tuning
const RNG_SEED := 20260823
const BIG_MONEY := 1000000000
const PROBE_HP := 1.0e9          # immortal probe HP; double precision keeps ~1e-7 resolution here

const A_SECONDS := 8.0           # dps-matrix trial length
const B_SECONDS := 8.0           # upgrade-tier trial length (same window as A, so the two compare)
const C_COHORT := 10             # control-tower trial: probes released per cohort
const C_GAP := 1.0               # control-tower cohort release gap
const C_CHECKPOINT := 18.0       # control-tower distance-covered mark
const C_MAX_S := 150.0           # control-tower trial cap (a fully jammed cohort crawls)
const EARLY_FRAC := 0.35         # "early" stands: nearest route point inside this fraction of the route

# Section B arena: immortal dummies parked on concentric rings around the stand,
# evenly spaced in ANGLE (not on the six hex axes, which would flatter a radial
# tower's default six spokes). This is the only probe that can see `range`,
# `targets`, `arc_angle` and `directions` — a single parked dummy cannot.
const ARENA_RINGS := [2.0, 4.0, 6.0, 8.0]   # tile distances from the stand
const ARENA_SPOKES := 12                     # dummies per ring
const ANCHOR_NEAR := 2.0                     # section A/B stand must be this close to the route, in tiles
const D_WARMUP := 10.0           # walking-stream lead-in (reaches steady state)
const D_WINDOW := 20.0           # walking-stream measured window
const D_GAP := 0.5               # walking-stream spawn gap
# Per-wave cap. Must exceed the slowest authored enemy's unimpeded walk time
# (printed in the section header) or a wave would "time out" while its survivors
# are merely still walking.
const E_TIMEOUT := 120.0
const E_ENEMY_CAP := 4000        # abort a wave whose decay chain explodes past this
const E_BUDGET_MS := 480000      # wall-clock budget for section E; later waves are SKIPPED
                                 # (override with BAL_E_BUDGET_MS; 0 = no budget)

# Reference enemy sizes used as stand-ins (all real values from data/enemies.json).
const STD_RADIUS := 16.0         # Quadlet-class body — the section B/C/D probe size
const D_STREAM_HP := 50.0        # walking-stream target HP (see section D header)
const D_STREAM_SPEED := 40.0     # walking-stream target speed (Bit-class, slow on purpose)

var main
var _path: PackedVector2Array
var _prefix := PackedFloat64Array()
var _path_cell_weight := {}      # Vector2i -> path sample points inside that cell
var _cov_cache := {}             # range_tiles -> Array of [cell, coverage] sorted desc
var _anchor := Vector2i.ZERO     # section A/B stand (see _setup_path for how it is chosen)
var _t0 := 0

# Walking-stream accounting (section D); see _d_reset.
var _d_dead_damage := 0.0
var _d_kills := 0
var _d_leaks := 0
var _d_live: Array = []
var _d_hp0 := 0.0

func drive(m) -> void:
	main = m
	_t0 = Time.get_ticks_msec()
	seed(RNG_SEED)
	main.money = BIG_MONEY
	_setup_path()
	var want := OS.get_environment("BAL_SECTIONS")
	if want == "":
		want = "SABCDE"
	p("")
	p("================ HexTD BALANCE HARNESS ================")
	p("seed=%d  fixed step=1/60s  map=%s  path samples=%d  length=%.0f units" % [
		RNG_SEED, main.map.display_name, _path.size(), _prefix[_prefix.size() - 1]])
	p("All damage figures come from the shipping combat code, not from formulas.")
	if want.contains("S"):
		await _section_self_check()
	if want.contains("A"):
		await _section_a()
	if want.contains("B"):
		await _section_b()
	if want.contains("C"):
		await _section_c()
	if want.contains("D"):
		await _section_d()
	if want.contains("E"):
		await _section_e()
	# Required, not tidiness: leaving live towers/enemies in the tree makes the
	# headless engine spin for a minute at shutdown instead of quitting.
	await _reset_board()
	p("")
	p("HARNESS COMPLETE — wall clock %.1f s" % [(Time.get_ticks_msec() - _t0) / 1000.0])
	p("=======================================================")

func p(s: String) -> void:
	print("BAL: ", s)

# ================================================================ setup helpers
func _setup_path() -> void:
	_path = main.board.get_path_points()
	_prefix.resize(_path.size())
	_prefix[0] = 0.0
	for i in range(1, _path.size()):
		_prefix[i] = _prefix[i - 1] + _path[i - 1].distance_to(_path[i])
	for pt in _path:
		var c: Vector2i = main.board.world_cell(pt)
		_path_cell_weight[c] = int(_path_cell_weight.get(c, 0)) + 1
	# Section A/B stand. Two requirements: a dummy parked on the nearest route
	# point must sit well inside every tower's range (so placement is not a
	# variable), and the stand must be central enough that the section B arena
	# rings are not half off-map. So: among buildable cells within ANCHOR_NEAR of
	# the route, take the one with the most on-map arena stands, nearest route
	# point breaking ties.
	var near: float = ANCHOR_NEAR * GameBoard3D.TOWER_RADIUS
	var best_score := -1
	var best_d := 1.0e18
	for c in main.map.buildable:
		var cell: Vector2i = c
		if not main.board.is_buildable(cell):
			continue
		var w: Vector2 = main.board.cell_center_world(cell)
		var d := 1.0e18
		for pt in _path:
			d = minf(d, w.distance_squared_to(pt))
		if d > near * near:
			continue
		var score := _arena_stands(w).size()
		if score > best_score or (score == best_score and d < best_d):
			best_score = score
			best_d = d
			_anchor = cell

## Buildable cells ranked by how much of the route their range covers (path
## sample points inside the range disk). Memoized per range_tiles.
func _coverage_rank(range_tiles: int) -> Array:
	if _cov_cache.has(range_tiles):
		var hit: Array = _cov_cache[range_tiles]
		return hit
	var reach: int = main.board.tower_reach(range_tiles)
	var rows: Array = []
	for c in main.map.buildable:
		var cell: Vector2i = c
		var rs: Dictionary = main.board.range_cell_set(cell, reach)
		var n := 0
		for pc in _path_cell_weight:
			if rs.has(pc):
				n += int(_path_cell_weight[pc])
		rows.append([cell, n])
	rows.sort_custom(func(a, b): return a[1] > b[1])
	_cov_cache[range_tiles] = rows
	return rows

## Best currently-buildable cell for a tower of this range (occupancy-aware, so
## repeated calls while building a loadout hand out distinct stands).
func _best_cell(range_tiles: int) -> Vector2i:
	for row in _coverage_rank(range_tiles):
		var cell: Vector2i = row[0]
		if main.board.is_buildable(cell):
			return cell
	return _anchor

func _coverage_of(range_tiles: int, cell: Vector2i) -> int:
	for row in _coverage_rank(range_tiles):
		if row[0] == cell:
			return int(row[1])
	return 0

# ================================================================ trial plumbing
## Full teardown. Towers, enemies and in-flight ordnance all have deferred
## lifetimes, so two frames are burned before the next trial is allowed to run.
func _reset_board() -> void:
	main._wave_running = false
	main._wave_awaiting_clear = false
	main._spawn_timeline = []
	main._wave_clock = 0.0
	main.game_over = false
	for e in main.board.enemies.duplicate():
		if is_instance_valid(e):
			e.queue_free()
	main.board.enemies.clear()
	for c in main.board.occupied.keys().duplicate():
		main.board.remove_tower(c)
	main.board.occupied.clear()
	for ch in main.board._entities.get_children():
		if ch is Projectile3D or ch is RadialProjectile3D or ch is ArcWave3D:
			ch.queue_free()
	_d_reset()
	await get_tree().process_frame
	await get_tree().process_frame
	main.money = BIG_MONEY
	main.lives = 99999

## [live enemies, occupied cells, in-flight ordnance] currently on the board.
func _clean_counts() -> Array:
	var ordnance := 0
	for ch in main.board._entities.get_children():
		if ch is Projectile3D or ch is RadialProjectile3D or ch is ArcWave3D:
			ordnance += 1
	return [main.board.enemies.size(), main.board.occupied.size(), ordnance]

## Report (never absorb) leftovers from the previous trial.
func _verify_clean(tag: String) -> void:
	var c := _clean_counts()
	if c[0] != 0 or c[1] != 0 or c[2] != 0:
		p("!! CONTAMINATION before %s: enemies=%d occupied-cells=%d ordnance=%d" % [
			tag, c[0], c[1], c[2]])

func _place(id: String, cell: Vector2i):
	main.placing_id = id
	var ok: bool = main._try_place(cell)
	main.placing_id = ""
	if not ok:
		return null
	return main.board.tower_at(cell)

func _steps(seconds: float) -> void:
	for _i in range(int(round(seconds * 60.0))):
		await get_tree().process_frame

## An indestructible, stationary copy of a real enemy: huge HP, no decay chain,
## no reward, speed 0 — but `ecc`, `encrypted`, shape and radius (which is the
## hit radius for every solid) are preserved, because those change combat.
func _probe(src: EnemyData) -> EnemyData:
	var d := EnemyData.new()
	d.id = src.id + "__probe"
	d.display_name = src.display_name
	d.shape = src.shape
	d.color = src.color
	d.health = PROBE_HP
	d.speed = 0.0
	d.reward = 0
	d.glow = 0.0
	d.side = src.side
	d.length = src.length
	d.width = src.width
	d.radius = src.radius
	d.sides = src.sides
	d.reduces_to_id = ""
	d.reduces_to = null
	d.reduce_count = 1
	d.ecc = src.ecc
	d.encrypted = src.encrypted
	d.rank = src.rank
	return d

## A synthetic probe built from flags + radius alone (section B/C/D references).
func _synth(pid: String, radius: float, is_ecc: bool, is_enc: bool, hp: float, spd: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = pid
	d.display_name = pid
	d.shape = "icosahedron"
	d.health = hp
	d.speed = spd
	d.reward = 0
	d.glow = 0.0
	d.radius = radius
	d.side = radius * 2.0
	d.reduces_to_id = ""
	d.reduces_to = null
	d.reduce_count = 1
	d.ecc = is_ecc
	d.encrypted = is_enc
	return d

func _nearest_path_index(w: Vector2) -> int:
	var best := 0
	var best_d := 1.0e18
	for i in range(_path.size()):
		var d: float = w.distance_squared_to(_path[i])
		if d < best_d:
			best_d = d
			best = i
	return best

## Park one immortal dummy on the route beside `cell` and return it.
func _park_dummy(pd: EnemyData, cell: Vector2i):
	var i := _nearest_path_index(main.board.cell_center_world(cell))
	var e := Enemy3D.new()
	e.setup(pd, _path)
	e.place_on_path(i, _path[i])
	main.board.add_enemy(e)
	return e

## Distance this enemy has travelled along the route, in world units.
func _arclen(e) -> float:
	var i: int = e._index
	if i >= _path.size():
		return _prefix[_prefix.size() - 1]
	var base: float = _prefix[i]
	return base + _path[i].distance_to(e.pp)

# ================================================================ core measurement
## One tower vs one parked immortal dummy. Returns damage per second, -1 when the
## tower could not be placed, -2 when it cannot see the probe at all. `slot`/`tiers`
## optionally buy that many levels of one upgrade path through the real API first.
func _dps_trial(tower_id: String, pd: EnemyData, seconds: float, slot := -1, tiers := 0) -> float:
	await _reset_board()
	_verify_clean("dps %s" % tower_id)
	var t = _place(tower_id, _anchor)
	if t == null:
		return -1.0
	for _i in range(tiers):
		if not t.can_upgrade(slot):
			break
		t.upgrade(slot)
	# Blind is not the same reading as zero: an encrypted target is never even a
	# candidate without Cipher, so no trial is run and the cell is marked "---".
	if pd.encrypted and not t.data.cipher:
		return -2.0
	var e = _park_dummy(pd, _anchor)
	await get_tree().process_frame
	await _steps(seconds)
	var dealt: float = PROBE_HP - e.health
	return dealt / seconds

func _arena_positions() -> Array:
	return _arena_stands(main.board.cell_center_world(_anchor))

## Arena dummy stands around a plane point. Off-map cells are dropped: they sit
## outside every range set, so a dummy there is one no tower could ever engage.
func _arena_stands(c0: Vector2) -> Array:
	var out: Array = []
	for r in ARENA_RINGS:
		for k in range(ARENA_SPOKES):
			var ang: float = TAU * float(k) / float(ARENA_SPOKES)
			var w: Vector2 = c0 + Vector2(cos(ang), sin(ang)) * (float(r) * GameBoard3D.TOWER_RADIUS)
			if main.board.has_cell(main.board.world_cell(w)):
				out.append(w)
	return out

## One tower against the whole arena. Returns {dps, n}: total damage per second
## summed over every parked dummy, and how many were actually on the map.
func _arena_trial(tower_id: String, pd: EnemyData, seconds: float, slot := -1, tiers := 0) -> Dictionary:
	await _reset_board()
	_verify_clean("arena %s" % tower_id)
	var t = _place(tower_id, _anchor)
	if t == null:
		return {"dps": -1.0, "n": 0}
	for _i in range(tiers):
		if not t.can_upgrade(slot):
			break
		t.upgrade(slot)
	var dummies: Array = []
	for w in _arena_positions():
		var e := Enemy3D.new()
		e.setup(pd, _path)
		e.place_on_path(0, w)
		main.board.add_enemy(e)
		dummies.append(e)
	await get_tree().process_frame
	await _steps(seconds)
	var dealt := 0.0
	for e in dummies:
		if is_instance_valid(e):
			dealt += PROBE_HP - e.health
	return {"dps": dealt / seconds, "n": dummies.size()}

# ================================================================ S — self-check
func _section_self_check() -> void:
	p("")
	p("--- S. SELF-CHECK -------------------------------------------------------")
	p("The simple towers (single shot, no ramp, no splash) measured against a parked")
	p("immortal dummy for %.0f s, printed beside their paper figure damage x fire_rate." % A_SECONDS)
	p("A large gap on those means the harness is broken, not the game. Small ones are")
	p("expected: a tower fires on its first frame (a free shot inside the window) and")
	p("its cooldown is stepped in whole frames, so the real rate is")
	p("60/ceil(60/fire_rate) shots per second, not fire_rate.")
	p("The Beam is listed as a control and MUST read far below paper. Its paper")
	p("figure is `damage` alone — in laser mode that IS damage per second at full")
	p("charge and fire_rate is unused — and its damage ramps quadratically over")
	p("ramp_time, so an %.0f s window that starts cold cannot reach it." % A_SECONDS)
	p("Before that, the contamination guard is itself tested: a tower, a dummy and")
	p("live ordnance are deliberately left on the board and the guard is asked to")
	p("look, then the reset runs and it looks again. If the DIRTY line reads all")
	p("zeroes the guard is blind and every 'no contamination' below means nothing.")
	p("")
	var std := _synth("std", STD_RADIUS, false, false, PROBE_HP, 0.0)
	await _selftest_reset(std)
	p("")
	p("%-14s %8s %8s %8s  %s" % ["tower", "paper", "measured", "ratio", "verdict"])
	for id in ["basic", "slow", "machinegun", "laser"]:
		var td: TowerData = main.content.tower(id)
		if td == null:
			continue
		# Laser mode ignores fire_rate: `damage` is already damage per second at
		# full charge, so multiplying the two would invent a number the game has no
		# concept of.
		var paper: float = td.damage if td.fire_mode == "laser" else td.damage * td.fire_rate
		var got: float = await _dps_trial(id, std, A_SECONDS)
		var ratio: float = got / maxf(0.0001, paper)
		var verdict := "ok"
		if td.fire_mode != "single":
			verdict = "ramped/other mode — gap expected"
		elif ratio < 0.85 or ratio > 1.15:
			verdict = "CHECK HARNESS"
		p("%-14s %8.1f %8.1f %8.2f  %s" % [td.display_name, paper, got, ratio, verdict])

## Prove the contamination guard can actually see a dirty board, and that
## _reset_board clears every kind of leftover a trial produces.
func _selftest_reset(probe: EnemyData) -> void:
	await _reset_board()
	# A radial tower: its volley puts several spokes in the air at once, and they
	# fly for a fifth of a second, so the ordnance count is easy to catch.
	var tid := "radial"
	if main.content.tower(tid) == null:
		tid = str(main.content.tower_ids()[0])
	_place(tid, _anchor)
	_park_dummy(probe, _anchor)
	# PEAK over the window, not a single sample: a shot is only in flight for a
	# couple of frames, so an instantaneous read would miss it and the guard would
	# look blind when it is not.
	var dirty := [0, 0, 0]
	for _i in range(120):
		await get_tree().process_frame
		var c := _clean_counts()
		for k in range(3):
			dirty[k] = maxi(dirty[k], int(c[k]))
	await _reset_board()
	var clean := _clean_counts()
	var ok: bool = (dirty[0] > 0 and dirty[1] > 0 and dirty[2] > 0) \
		and clean[0] == 0 and clean[1] == 0 and clean[2] == 0
	p("reset self-test  DIRTY(peak) enemies=%d cells=%d ordnance=%d  ->  AFTER RESET enemies=%d cells=%d ordnance=%d  [%s]" % [
		dirty[0], dirty[1], dirty[2], clean[0], clean[1], clean[2],
		"guard works, reset clean" if ok else "FAILED — trials may contaminate each other"])

# ================================================================ A — dps matrix
func _section_a() -> void:
	p("")
	p("--- A. TOWER x ENEMY DPS MATRIX ----------------------------------------")
	p("Sustained damage per second against a PARKED immortal probe, %.0f s per cell." % A_SECONDS)
	p("Probes are synthetic copies of the real EnemyData with health=1e9, speed=0,")
	p("reward=0 and the decay chain cleared, so nothing dies and no split muddies")
	p("the reading — but `ecc` (90%% resist unless the tower has Bit Corruption),")
	p("`encrypted` (invisible without Cipher) and `radius` (the hit radius every")
	p("solid uses) are preserved verbatim.")
	p("GROUPING: rows are the distinct combat profiles (ecc, encrypted, radius).")
	p("Enemy ids that share all three behave identically here and share one row;")
	p("the legend below names the members of each row.")
	p("Tower and dummy sit at the same fixed stand every cell, so range/placement")
	p("is held constant — this is RAW OUTPUT, not effective output (see D).")
	p("CELL KEY:  number = dps.   ---  = tower cannot SEE this target at all")
	p("(encrypted, no Cipher).   0.0 = it sees the target and deals nothing.")
	p("")
	var profiles := _enemy_profiles()
	var tids: Array = main.content.tower_ids()
	var head := "%-22s" % "profile (ecc,enc,radius)"
	for id in tids:
		var td: TowerData = main.content.tower(str(id))
		head += "%9s" % td.display_name.substr(0, 9)
	p(head)
	for prof in profiles:
		var pd: EnemyData = prof["probe"]
		var label := "%s/%s r%-3d" % [
			"ECC" if pd.ecc else " - ", "ENC" if pd.encrypted else " - ", int(pd.radius)]
		var line := "%-22s" % label
		for id in tids:
			var td: TowerData = main.content.tower(str(id))
			if pd.encrypted and not td.cipher:
				line += "%9s" % "---"
				continue
			var dps: float = await _dps_trial(str(id), pd, A_SECONDS)
			line += "%9s" % _fmt_dps(dps)
		p(line)
	p("")
	p("LEGEND — enemy ids per row:")
	for prof in profiles:
		var pd: EnemyData = prof["probe"]
		var ids: Array = prof["ids"]
		p("  %s/%s r%-3d : %s" % [
			"ECC" if pd.ecc else " - ", "ENC" if pd.encrypted else " - ",
			int(pd.radius), ", ".join(ids)])

## Collapse data/enemies.json into distinct combat profiles: (ecc, encrypted, radius).
func _enemy_profiles() -> Array:
	var by_key := {}
	var order: Array = []
	for raw in main.content.enemy_ids():
		var eid := str(raw)
		var ed: EnemyData = main.content.enemy(eid)
		if ed == null:
			continue
		var key: Array = [ed.ecc, ed.encrypted, int(round(ed.radius))]
		if not by_key.has(key):
			by_key[key] = {"probe": _probe(ed), "ids": []}
			order.append(key)
		var slot: Dictionary = by_key[key]
		var ids: Array = slot["ids"]
		ids.append(eid)
	# Smallest bodies first, plain before ecc/encrypted, so the table reads as a ramp.
	order.sort_custom(func(a, b):
		if a[2] != b[2]:
			return a[2] < b[2]
		if a[0] != b[0]:
			return not a[0]
		return not a[1])
	var out: Array = []
	for k in order:
		out.append(by_key[k])
	return out

# ================================================================ B — upgrade tiers
func _section_b() -> void:
	p("")
	p("--- B. UPGRADE-TIER EFFICIENCY -----------------------------------------")
	p("For each tower and each upgrade slot, that slot is bought tier by tier from")
	p("0 to max with the OTHER slots left at 0, through the tower's own API")
	p("(can_upgrade / next_cost / upgrade). %.0f s per level against a parked" % B_SECONDS)
	p("immortal probe of radius %d. Three probes per level, so tiers whose only" % int(STD_RADIUS))
	p("payload is an ability flag are valued instead of reading as dead tiers:")
	p("  dps      plain probe (no ecc, not encrypted) — the headline number")
	p("  dps(ECC) ecc probe: 90%% resist unless the tier bought Bit Corruption")
	p("  dps(ENC) encrypted probe: unhittable unless the tier bought Cipher")
	p("A single parked dummy is blind to `range`, `targets`, `arc_angle` and")
	p("`directions`, so a fourth column adds an ARENA: plain immortal dummies on")
	p("rings at %s tiles from the stand, %d per ring evenly spaced in ANGLE (not on" % [
		str(ARENA_RINGS), ARENA_SPOKES])
	p("the six hex axes, which would flatter a radial tower's default six spokes);")
	p("%d of those stands are on the map and get a dummy. Reported as the" % _arena_positions().size())
	p("total damage per second summed over all of them. `arena` is the column to")
	p("read for breadth tiers; `dps` is the column to read for single-target power.")
	p("cum cost = tower cost + every tier bought so far.")
	p("marg/100c and arena-marg/100c = (this level - previous level) / this tier's")
	p("cost x 100, on the plain probe and on the arena. Near-zero on BOTH with a")
	p("real price attached is a dead tier; a large jump is a spike.")
	p("`---` = the tower cannot see the probe at all (encrypted, no Cipher yet).")
	p("")
	var plain := _synth("plain", STD_RADIUS, false, false, PROBE_HP, 0.0)
	var ecc := _synth("ecc", STD_RADIUS, true, false, PROBE_HP, 0.0)
	var enc := _synth("enc", STD_RADIUS, false, true, PROBE_HP, 0.0)
	for raw in main.content.tower_ids():
		var tid := str(raw)
		var td: TowerData = main.content.tower(tid)
		# Fresh board first: the previous tower's last trial still has its stand.
		await _reset_board()
		var probe_t = _place(tid, _anchor)
		if probe_t == null:
			p("!! could not stand %s for slot metadata — skipped" % td.display_name)
			continue
		var nslots: int = probe_t.slot_count()
		var maxes: Array = []
		var costs: Array = []
		for s in range(nslots):
			maxes.append(probe_t.slot_max(s))
			var cl: Array = []
			var tiers: Array = td.upgrades[s].get("tiers", [])
			for tier in tiers:
				cl.append(tier)
			costs.append(cl)
		var names: Array = []
		for s in range(nslots):
			names.append(probe_t.slot_name(s))
		await _reset_board()
		p("")
		p("%s  (base cost %d, %s mode, dmg %.0f, rate %.2f/s, range %d)" % [
			td.display_name, td.cost, td.fire_mode, td.damage, td.fire_rate, td.range_tiles])
		p("  %-12s %5s %9s %9s %9s %9s %9s %10s %10s  %s" % [
			"slot", "level", "cum cost", "dps", "dps(ECC)", "dps(ENC)", "arena",
			"marg/100c", "arena/100c", "tier grants"])
		for s in range(nslots):
			var prev := -1.0
			var prev_arena := -1.0
			var cum: int = td.cost
			var slot_t0: int = Time.get_ticks_msec()
			for lv in range(maxes[s] + 1):
				var d_plain: float = await _dps_trial(tid, plain, B_SECONDS, s, lv)
				var d_ecc: float = await _dps_trial(tid, ecc, B_SECONDS, s, lv)
				var d_enc: float = await _dps_trial(tid, enc, B_SECONDS, s, lv)
				var ar: Dictionary = await _arena_trial(tid, plain, B_SECONDS, s, lv)
				var d_arena: float = ar["dps"]
				var tier_cost := 0
				var grants := "(base)"
				if lv > 0:
					var tier: Dictionary = costs[s][lv - 1]
					tier_cost = int(tier.get("cost", 0))
					cum += tier_cost
					grants = _tier_grants(tier)
				var marg_txt := "         -"
				var amarg_txt := "         -"
				if lv > 0:
					marg_txt = "%10.3f" % [(d_plain - prev) / maxf(1.0, float(tier_cost)) * 100.0]
					amarg_txt = "%10.3f" % [(d_arena - prev_arena) / maxf(1.0, float(tier_cost)) * 100.0]
				p("  %-12s %5d %9d %9s %9s %9s %9s %10s %10s  %s" % [
					names[s] if lv == 0 else "", lv, cum, _fmt_dps(d_plain), _fmt_dps(d_ecc),
					_fmt_dps(d_enc), _fmt_dps(d_arena), marg_txt, amarg_txt, grants])
				prev = d_plain
				prev_arena = d_arena
			if OS.get_environment("BAL_DEBUG") != "":
				p("   dbg %s slot %d took %.1f s" % [
					tid, s, (Time.get_ticks_msec() - slot_t0) / 1000.0])

func _tier_grants(tier: Dictionary) -> String:
	var parts: Array = []
	for k in tier.keys():
		var key := str(k)
		if key == "cost":
			continue
		var v = tier[k]
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			var f := float(v)
			parts.append("%s%s%s" % [key, "+" if f >= 0.0 else "-", _num(absf(f))])
		else:
			parts.append("%s=%s" % [key, str(v)])
	if parts.is_empty():
		return "(nothing)"
	return " ".join(parts)

func _num(v: float) -> String:
	var s := "%.2f" % v
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s

## "---" = the tower cannot see this target at all; "n/a" = the trial never ran.
func _fmt_dps(v: float) -> String:
	if v <= -1.5:
		return "---"
	if v < 0.0:
		return "n/a"
	return "%.1f" % v

# ================================================================ C — control tower
# Cohort accounting: immortal probes are freed the moment they reach the goal,
# so their contribution is banked in the reached_goal handler instead of being
# read off the board at the end.
var _c_damage := 0.0
var _c_dist := 0.0
var _c_gone := 0
var _c_live: Array = []

func _c_reset() -> void:
	_c_damage = 0.0
	_c_dist = 0.0
	_c_gone = 0
	_c_live = []

func _c_on_leak(e) -> void:
	_c_gone += 1
	_c_damage += PROBE_HP - e.health
	_c_dist += _prefix[_prefix.size() - 1]
	_c_live.erase(e)

func _section_c() -> void:
	p("")
	p("--- C. CONTROL-TOWER VALUATION -----------------------------------------")
	p("The Jammer has damage 0, so a dps figure says nothing about it. It is")
	p("measured two other ways instead, both driving a fixed COHORT of %d immortal" % C_COHORT)
	p("probes (radius %d, speed %.0f, HP 1e9, no decay, no ecc, not encrypted)" % [
		int(STD_RADIUS), D_STREAM_SPEED])
	p("released one every %.1f s and then followed until the last one reaches the" % C_GAP)
	p("goal (cap %.0f s). A fixed cohort rather than a fixed window matters: slowing" % C_MAX_S)
	p("a stream shifts arrivals later, so a fixed window would score a working")
	p("Jammer as a LOSS purely because fewer enemies got past the tower in time.")
	p("")
	p("  1 SLOWDOWN — three readings, with and without the Jammer on the same cell:")
	p("      clear s   seconds until the whole cohort has reached the goal")
	p("      zone sec  total enemy-seconds spent inside the reference zone")
	p("                (a disk of the Jammer's own range around its stand)")
	p("      dist@%2.0fs  route distance the cohort has covered at the %.0f s mark" % [
		C_CHECKPOINT, C_CHECKPOINT])
	p("  2 UPLIFT — HP the partner tower removes from that same cohort, alone vs")
	p("    with the Jammer on the nearest buildable cell to it. Immortal probes")
	p("    mean this is pure output: no kills, no decay, no bounty feedback.")
	p("")
	var jam_td: TowerData = main.content.tower("jammer")
	if jam_td == null:
		p("no 'jammer' tower in data/towers.json — section C skipped")
		return
	var jam_cell := _early_stand(jam_td.range_tiles)
	var zone_r: float = float(main.board.tower_reach(jam_td.range_tiles)) * GameBoard3D.TOWER_RADIUS
	var zone_c: Vector2 = main.board.cell_center_world(jam_cell)
	p("Jammer stand for C1: cell %s — best route coverage among cells the stream" % str(jam_cell))
	p("meets in the first %d%% of the route, so the cohort actually reaches it." % int(EARLY_FRAC * 100.0))
	p("Reference zone: world radius %.0f around that cell. Jammer cost %d," % [zone_r, jam_td.cost])
	p("dos_freeze %.2fs, dos_slow_time %.2fs, dos_slow_factor %.2f, arc %.0f deg." % [
		jam_td.dos_freeze, jam_td.dos_slow_time, jam_td.dos_slow_factor, jam_td.arc_angle])
	p("")
	var base: Dictionary = await _control_trial("", Vector2i.ZERO, "", Vector2i.ZERO, zone_c, zone_r)
	var jam: Dictionary = await _control_trial("jammer", jam_cell, "", Vector2i.ZERO, zone_c, zone_r)
	p("C1 SLOWDOWN")
	p("  %-22s %10s %10s %12s" % ["setup", "clear s", "zone sec", "dist@%.0fs" % C_CHECKPOINT])
	p("  %-22s %10.1f %10.2f %12.0f" % [
		"cohort only", base["clear"], base["zone"], base["dist_cp"]])
	p("  %-22s %10.1f %10.2f %12.0f" % [
		"cohort + Jammer", jam["clear"], jam["zone"], jam["dist_cp"]])
	p("  -> clear time %+.1f %%   zone dwell %+.1f %%   distance at the mark %+.1f %%" % [
		_pct(base["clear"], jam["clear"]), _pct(base["zone"], jam["zone"]),
		_pct(base["dist_cp"], jam["dist_cp"])])
	p("")
	p("C2 UPLIFT (HP the partner removes from the whole cohort)")
	p("  %-14s %8s %10s %12s %12s %9s" % [
		"partner", "cost", "stand", "alone", "+ Jammer", "change"])
	for raw in main.content.tower_ids():
		var tid := str(raw)
		var td: TowerData = main.content.tower(tid)
		if tid == "jammer" or td.damage <= 0.0:
			continue
		var pcell := _early_stand(td.range_tiles)
		var solo: Dictionary = await _control_trial("", Vector2i.ZERO, tid, pcell, zone_c, zone_r)
		var duo: Dictionary = await _control_trial("jammer", Vector2i.ZERO, tid, pcell, zone_c, zone_r)
		if not bool(duo["ctrl_placed"]):
			p("  %-14s %8d %10s %12.0f %12s %9s" % [
				td.display_name, td.cost, str(pcell), solo["damage"], "no stand", "-"])
			continue
		p("  %-14s %8d %10s %12.0f %12.0f %8.1f%%" % [
			td.display_name, td.cost, str(pcell), solo["damage"], duo["damage"],
			_pct(solo["damage"], duo["damage"])])
	p("")
	p("C3 UPGRADE PATHS ON THE CONTROL TOWER")
	p("Section B prices upgrades in dps, which is blind on a damage-0 tower: every")
	p("Bandwidth and Signal tier reads 0.0 there whatever it bought. Same cohort as")
	p("C1, same FIXED reference zone (sized from the Jammer's BASE range, so a")
	p("range tier shows up as more dwell in that zone rather than by moving the")
	p("goalposts). `>=` on clear s means the cohort never finished inside the %.0f s cap." % C_MAX_S)
	p("  %-12s %5s %9s %10s %10s %12s  %s" % [
		"slot", "level", "cum cost", "clear s", "zone sec", "dist@%.0fs" % C_CHECKPOINT,
		"tier grants"])
	p("  %-12s %5s %9s %10.1f %10.2f %12.0f  %s" % [
		"(no Jammer)", "-", "0", base["clear"], base["zone"], base["dist_cp"], ""])
	var jam_slots: int = mini(3, jam_td.upgrades.size())
	for s in range(jam_slots):
		var tiers: Array = jam_td.upgrades[s].get("tiers", [])
		var sname := str(jam_td.upgrades[s].get("name", "Slot %d" % (s + 1)))
		var cum: int = jam_td.cost
		for lv in range(tiers.size() + 1):
			var grants := "(base)"
			if lv > 0:
				var tier: Dictionary = tiers[lv - 1]
				cum += int(tier.get("cost", 0))
				grants = _tier_grants(tier)
			var r: Dictionary = await _control_trial(
				"jammer", jam_cell, "", Vector2i.ZERO, zone_c, zone_r, s, lv)
			var clear_txt: String = ("%10.1f" % r["clear"]) if bool(r["cleared"]) \
				else (">=%7.0f" % r["clear"])
			p("  %-12s %5d %9d %s %10.2f %12.0f  %s" % [
				sname if lv == 0 else "", lv, cum, clear_txt, r["zone"], r["dist_cp"], grants])
	p("")
	p("A positive change is the Jammer buying its partner more time on target; a")
	p("negative one means the partner was already saturated (it never idles, so")
	p("holding enemies longer cannot add shots) or the Jammer's wedge never")
	p("overlapped the partner's engagement window.")

func _pct(from_v: float, to_v: float) -> float:
	return (to_v - from_v) / maxf(0.0001, absf(from_v)) * 100.0

## Best-coverage buildable cell among those the route reaches early, so a cohort
## released at the spawn actually walks through it inside the trial.
func _early_stand(range_tiles: int) -> Vector2i:
	var limit: int = int(float(_path.size()) * EARLY_FRAC)
	for row in _coverage_rank(range_tiles):
		var cell: Vector2i = row[0]
		if not main.board.is_buildable(cell):
			continue
		if _nearest_path_index(main.board.cell_center_world(cell)) <= limit:
			return cell
	return _anchor

## Closest buildable cell to `to` (used to seat the Jammer beside its partner).
func _nearest_buildable(to: Vector2i) -> Vector2i:
	var best := Vector2i.ZERO
	var found := false
	var best_d := 1.0e18
	var w: Vector2 = main.board.cell_center_world(to)
	for c in main.map.buildable:
		var cell: Vector2i = c
		if not main.board.is_buildable(cell):
			continue
		var d: float = w.distance_squared_to(main.board.cell_center_world(cell))
		if d < best_d:
			best_d = d
			best = cell
			found = true
	return best if found else to

## One cohort trial. Either tower id may be "" (not placed). When a control tower
## is named with a zero ctrl_cell it is seated on the nearest buildable cell to
## the damage tower, which is how the pair is meant to be played.
## Returns {clear, zone, dist_cp, damage, ctrl_placed}.
func _control_trial(ctrl_id: String, ctrl_cell: Vector2i, dmg_id: String, dmg_cell: Vector2i,
		zone_c: Vector2, zone_r: float, ctrl_slot := -1, ctrl_tiers := 0) -> Dictionary:
	await _reset_board()
	_verify_clean("cohort %s+%s" % [ctrl_id, dmg_id])
	_c_reset()
	var ctrl_placed := false
	var ctrl_spent := 0
	# Partner first: it keeps its own stand in both halves of the comparison, so
	# the only difference between the two runs is the control tower.
	if dmg_id != "" and _place(dmg_id, dmg_cell) == null:
		p("!! could not place %s at %s" % [dmg_id, str(dmg_cell)])
	if ctrl_id != "":
		var seat: Vector2i = ctrl_cell if ctrl_cell != Vector2i.ZERO else _nearest_buildable(dmg_cell)
		var ct = _place(ctrl_id, seat)
		ctrl_placed = ct != null
		if ct != null:
			for _i in range(ctrl_tiers):
				if not ct.can_upgrade(ctrl_slot):
					break
				ct.upgrade(ctrl_slot)
			ctrl_spent = ct.invested
	var pd := _synth("cohort", STD_RADIUS, false, false, PROBE_HP, D_STREAM_SPEED)
	var clock := 0.0
	var next_spawn := 0.0
	var spawned := 0
	var zone_seconds := 0.0
	var dist_cp := -1.0
	var dt := 1.0 / 60.0
	var clear := C_MAX_S
	var cleared := false
	var frames: int = int(round(C_MAX_S * 60.0))
	for _i in range(frames):
		if spawned < C_COHORT and clock >= next_spawn:
			var e := Enemy3D.new()
			e.setup(pd, _path)
			e.reached_goal.connect(_c_on_leak.bind(e))
			main.board.add_enemy(e)
			_c_live.append(e)
			spawned += 1
			next_spawn += C_GAP
		await get_tree().process_frame
		clock += dt
		for e in _c_live:
			if is_instance_valid(e) and e.pp.distance_to(zone_c) <= zone_r:
				zone_seconds += dt
		if dist_cp < 0.0 and clock >= C_CHECKPOINT:
			dist_cp = _c_dist
			for e in _c_live:
				if is_instance_valid(e):
					dist_cp += _arclen(e)
		if spawned >= C_COHORT and _c_gone >= C_COHORT:
			clear = clock
			cleared = true
			break
	if dist_cp < 0.0:
		dist_cp = _c_dist
	var damage := _c_damage
	for e in _c_live:
		if is_instance_valid(e):
			damage += PROBE_HP - e.health
	return {
		"clear": clear, "cleared": cleared, "zone": zone_seconds, "dist_cp": dist_cp,
		"damage": damage, "ctrl_placed": ctrl_placed, "ctrl_spent": ctrl_spent,
	}

# ================================================================ D — walking stream
func _d_reset() -> void:
	_d_dead_damage = 0.0
	_d_kills = 0
	_d_leaks = 0
	_d_live = []

func _d_on_kill(_amount: int, e) -> void:
	_d_kills += 1
	_d_dead_damage += _d_hp0
	_d_live.erase(e)

func _d_on_leak(e) -> void:
	_d_leaks += 1
	_d_dead_damage += maxf(0.0, _d_hp0 - e.health)
	_d_live.erase(e)

func _d_damage_now() -> float:
	var tot := _d_dead_damage
	for e in _d_live:
		if is_instance_valid(e):
			tot += _d_hp0 - e.health
	return tot

func _section_d() -> void:
	p("")
	p("--- D. WALKING-STREAM EFFECTIVENESS ------------------------------------")
	p("Section A is RAW OUTPUT: a dummy parked next to the muzzle. That flatters")
	p("short-range and splash towers and ignores route coverage entirely. This")
	p("section is EFFECTIVE OUTPUT and is the one to trust for cost decisions.")
	p("Each tower stands on the buildable cell whose range disk covers the most of")
	p("the real route (per-tower, since ranges differ — the cell is printed).")
	p("A stream of one fixed target type walks the real path past it: HP %.0f," % D_STREAM_HP)
	p("speed %.0f, radius %d, no decay chain, no ecc, not encrypted, released" % [
		D_STREAM_SPEED, int(STD_RADIUS)])
	p("every %.1f s. %.0f s of lead-in reaches steady state, then a %.0f s measured" % [
		D_GAP, D_WARMUP, D_WINDOW])
	p("window. dmg/s is HP removed per second inside that window (partial damage on")
	p("survivors counted); kills and leaks are window-only too. coverage = route")
	p("sample points inside the stand's range disk (%d samples on the whole route)." % _path.size())
	p("dmg/100c divides dmg/s by `spent` (base cost plus any upgrades bought for")
	p("that row). A leak is a stream target")
	p("that walked past unfinished — with %.0f HP arriving every %.1f s no single" % [D_STREAM_HP, D_GAP])
	p("tower is expected to hold, so leaks are context for the kill count, not a")
	p("failure. The second table repeats every trial with the target priority")
	p("switched from `first` to `last`, which is the difference between shooting")
	p("the enemy about to leave the range and the one that just entered it.")
	p("")
	p("The third table buys each tower's RANGE PATH out to tier 5 and re-stands it")
	p("on the best cell for the enlarged range. Base range is what tables 1-2")
	p("measure, so only this one can price a range upgrade in effective output.")
	p("Whole-slot, not range-only: the tier grants that ride along (directions,")
	p("targets, cipher, ignore_walls) come with it — which is how it is bought.")
	p("")
	p("target priority: first (the shipping default), no upgrades")
	await _d_table("first", false)
	p("")
	p("target priority: last, no upgrades")
	await _d_table("last", false)
	p("")
	p("target priority: first, range path bought to tier 5")
	await _d_table("first", true)

func _d_table(priority: String, max_range_path: bool) -> void:
	p("%-14s %6s %6s %10s %9s %8s %7s %7s %11s" % [
		"tower", "spent", "range", "stand", "coverage", "dmg/s", "kills", "leaks", "dmg/100c"])
	for raw in main.content.tower_ids():
		var tid := str(raw)
		var td: TowerData = main.content.tower(tid)
		var slot := -1
		var tiers := 0
		if max_range_path:
			slot = _range_slot(td)
			tiers = 5 if slot >= 0 else 0
		var res: Dictionary = await _d_trial(tid, td, priority, slot, tiers)
		var spent: float = maxf(1.0, float(res["spent"]))
		p("%-14s %6d %6d %10s %9d %8.1f %7d %7d %11.2f" % [
			td.display_name, int(res["spent"]), int(res["range"]), str(res["cell"]),
			int(res["cov"]), res["dps"], int(res["kills"]), int(res["leaks"]),
			res["dps"] / spent * 100.0])

## The upgrade slot carrying the most `range` deltas (-1 when the tower has none).
func _range_slot(td: TowerData) -> int:
	var best := -1
	var best_n := 0
	for s in range(mini(3, td.upgrades.size())):
		var n := 0
		for tier in td.upgrades[s].get("tiers", []):
			if tier.has("range"):
				n += 1
		if n > best_n:
			best_n = n
			best = s
	return best

## Range this tower ends at with `tiers` levels of slot `s` bought. Derived from
## the data rather than from a placed tower, because the stand has to be chosen
## for the FINAL range before the tower can be put down.
func _slot_range_total(td: TowerData, s: int, tiers: int) -> int:
	var r := td.range_tiles
	if s < 0:
		return r
	var list: Array = td.upgrades[s].get("tiers", [])
	for i in range(mini(tiers, list.size())):
		var tier: Dictionary = list[i]
		r += int(round(float(tier.get("range", 0.0))))
	return r

func _d_trial(tid: String, td: TowerData, priority := "first", slot := -1, tiers := 0) -> Dictionary:
	await _reset_board()
	_verify_clean("stream-d %s" % tid)
	var eff_range := _slot_range_total(td, slot, tiers)
	var cell := _best_cell(eff_range)
	var cov := _coverage_of(eff_range, cell)
	var t = _place(tid, cell)
	if t == null:
		return {"cell": cell, "cov": cov, "dps": -1.0, "kills": 0, "leaks": 0,
			"spent": td.cost, "range": eff_range}
	for _i in range(tiers):
		if not t.can_upgrade(slot):
			break
		t.upgrade(slot)
	# Through the tower's own control, not by writing _priority_id behind its back.
	for _i in range(4):
		if t.target_priority == priority:
			break
		t.cycle_target_priority()
	var pd := _synth("dstream", STD_RADIUS, false, false, D_STREAM_HP, D_STREAM_SPEED)
	_d_hp0 = D_STREAM_HP
	var clock := 0.0
	var next_spawn := 0.0
	var dt := 1.0 / 60.0
	var mark_damage := 0.0
	var mark_kills := 0
	var mark_leaks := 0
	var marked := false
	var total: float = D_WARMUP + D_WINDOW
	var frames: int = int(round(total * 60.0))
	for _i in range(frames):
		if clock >= next_spawn:
			var e := Enemy3D.new()
			e.setup(pd, _path)
			e.bounty.connect(_d_on_kill.bind(e))
			e.reached_goal.connect(_d_on_leak.bind(e))
			main.board.add_enemy(e)
			_d_live.append(e)
			next_spawn += D_GAP
		if not marked and clock >= D_WARMUP:
			marked = true
			mark_damage = _d_damage_now()
			mark_kills = _d_kills
			mark_leaks = _d_leaks
		await get_tree().process_frame
		clock += dt
	var window_damage: float = _d_damage_now() - mark_damage
	if OS.get_environment("BAL_DEBUG") != "":
		p("   dbg %s: mark_dmg=%.1f end_dmg=%.1f kills=%d/%d leaks=%d/%d live=%d" % [
			tid, mark_damage, _d_damage_now(), mark_kills, _d_kills, mark_leaks, _d_leaks,
			_d_live.size()])
	return {
		"cell": cell, "cov": cov,
		"dps": window_damage / D_WINDOW,
		"kills": _d_kills - mark_kills,
		"leaks": _d_leaks - mark_leaks,
		"spent": t.invested, "range": t.data.range_tiles,
	}

# ================================================================ E — wave viability
func _section_e() -> void:
	p("")
	p("--- E. WAVE VIABILITY --------------------------------------------------")
	p("Every authored wave in data/waves.json is run against ONE fixed reference")
	p("loadout, in order, on a board that keeps its towers between waves. Waves are")
	p("built with WaveLoader.build_timeline() and spawned by Main3D's own wave")
	p("runner, so spawn timing, decay chains, bounty and the wave-clear bonus are")
	p("the shipping behaviour.")
	p("REFERENCE LOADOUT: one of every tower type, each on its best-coverage cell,")
	p("with slot 0 bought to tier 3 and slot 1 to tier 2 (a legal crosspath).")
	p("Money starts at 0 after the loadout is paid for, so 'earned' is what this")
	p("wave grants (bounties + the %d wave-clear bonus). Lives are the sandbox" % main.WAVE_CLEAR_BONUS)
	p("99999, so a wave is never cut short by a loss — leaks are just counted.")
	p("clear = simulated seconds from wave start until the board is empty (killed")
	p("or leaked); TIMEOUT = still not clear after %.0f s; OVERFLOW = more than %d" % [E_TIMEOUT, E_ENEMY_CAP])
	p("live entities at once (a decay chain the loadout cannot chew).")
	p("READ TIMEOUT CAREFULLY: the slowest authored enemy needs %.0f s to walk this" % _slowest_walk())
	p("route unimpeded, so `left` (entities still on the board when the cap hit) is")
	p("what separates 'the loadout is overwhelmed' from 'the survivors are simply")
	p("still walking'. peak = the largest live entity count during the wave, which")
	p("counts decay children, unlike `spawned` (timeline entries only).")
	p("Compare cum-earned against the loadout cost to see when wave N is affordable.")
	p("")
	await _reset_board()
	var loadout_cost := 0
	var built: Array = []
	for raw in main.content.tower_ids():
		var tid := str(raw)
		var td: TowerData = main.content.tower(tid)
		var cell := _best_cell(td.range_tiles)
		var t = _place(tid, cell)
		if t == null:
			p("!! loadout: could not place %s" % td.display_name)
			continue
		loadout_cost += td.cost
		for pair in [[0, 3], [1, 2]]:
			var slot: int = pair[0]
			var want: int = pair[1]
			for _k in range(want):
				if not t.can_upgrade(slot):
					break
				loadout_cost += t.next_cost(slot)
				t.upgrade(slot)
		built.append("%s@%s" % [td.display_name, str(cell)])
	p("loadout: %s" % ", ".join(built))
	p("loadout total cost: %d" % loadout_cost)
	p("")
	main.money = 0
	main.lives = 99999
	p("%-4s %-28s %7s %6s %6s %5s %9s %8s %11s" % [
		"#", "wave", "spawned", "peak", "leaked", "left", "clear s", "earned", "cum earned"])
	var cum := 0
	# The budget bounds a full-harness run to a sane wall clock. How far it gets
	# depends on how long the waves themselves take, so it is NOT a fixed wave
	# count: slower data means more SKIPPED rows. Raise it (or set 0) to force
	# full coverage when the wave list is what you actually care about.
	var budget_ms: int = E_BUDGET_MS
	if OS.get_environment("BAL_E_BUDGET_MS") != "":
		budget_ms = int(OS.get_environment("BAL_E_BUDGET_MS"))
	var deadline: int = Time.get_ticks_msec() + budget_ms
	var limit: int = main.waves.size()
	if OS.get_environment("BAL_E_LIMIT") != "":
		limit = mini(limit, int(OS.get_environment("BAL_E_LIMIT")))
	for wi in range(limit):
		var wave: Dictionary = main.waves[wi]
		var wname: String = WaveLoader.wave_name(wave, wi)
		if budget_ms > 0 and Time.get_ticks_msec() > deadline:
			p("%-4d %-28s %7s %6s %6s %5s %9s %8s %11s" % [
				wi + 1, wname.substr(0, 28), "-", "-", "-", "-", "SKIPPED", "-", "-"])
			continue
		var res: Dictionary = await _run_wave(wave)
		cum += int(res["earned"])
		p("%-4d %-28s %7d %6d %6d %5d %9s %8d %11d" % [
			wi + 1, wname.substr(0, 28), int(res["spawned"]), int(res["peak"]),
			int(res["leaked"]), int(res["left"]), res["clear"], int(res["earned"]), cum])

func _run_wave(wave: Dictionary) -> Dictionary:
	var timeline: Array = WaveLoader.build_timeline(wave, main.default_gap)
	var money0: int = main.money
	var lives0: int = main.lives
	main._spawn_timeline = timeline.duplicate(true)
	main._wave_clock = 0.0
	main._wave_running = true
	main._wave_awaiting_clear = false
	var frames: int = int(round(E_TIMEOUT * 60.0))
	var peak := 0
	var status := ""
	var elapsed := 0.0
	var dt := 1.0 / 60.0
	for _i in range(frames):
		await get_tree().process_frame
		elapsed += dt
		var n: int = main.board.enemies.size()
		peak = maxi(peak, n)
		if n > E_ENEMY_CAP:
			status = "OVERFLOW"
			break
		if not main._wave_running and main._spawn_timeline.is_empty() \
				and not main._wave_awaiting_clear and n == 0:
			status = "%.1f" % elapsed
			break
	if status == "":
		status = "TIMEOUT"
	var leaked: int = lives0 - main.lives
	var left: int = main.board.enemies.size()
	# The board must be empty before the next wave, however this one ended.
	if status == "TIMEOUT" or status == "OVERFLOW":
		for e in main.board.enemies.duplicate():
			if is_instance_valid(e):
				e.queue_free()
		main.board.enemies.clear()
		main._wave_running = false
		main._wave_awaiting_clear = false
		main._spawn_timeline = []
		await get_tree().process_frame
		await get_tree().process_frame
	return {
		"spawned": timeline.size(),
		"peak": peak,
		"leaked": leaked,
		"left": left,
		"clear": status,
		"earned": main.money - money0,
	}

## Unimpeded walk time for the slowest authored enemy, in simulated seconds.
func _slowest_walk() -> float:
	var slowest := 1.0e9
	for raw in main.content.enemy_ids():
		var ed: EnemyData = main.content.enemy(str(raw))
		if ed != null and ed.speed > 0.0:
			slowest = minf(slowest, ed.speed)
	return _prefix[_prefix.size() - 1] / maxf(1.0, slowest * Enemy3D.SPEED_MULT)
