class_name Tower3D
extends Node3D
## 3D tower. Targeting, upgrades, fire modes and the audible laser hum are
## ported unchanged from the 2D Tower; all logic still operates on plane
## (Vector2) coordinates via the entity's `pp` field and `cell`. The body is a
## shared hex plinth + one low-poly silhouette per fire mode, split into a dark
## shell and hot emissive accents (see _rebuild_body); the laser beam is a
## colored sheath + white-hot core reoriented each frame to the locked target.

var data: TowerData
var base_data: TowerData
var slot_levels: Array = []
var invested := 0
var board                            # GameBoard3D (untyped)
var cell: Vector2i
var pp := Vector2.ZERO               # plane position (the tower's center)
var target_priority := "first"
var range_rotated := false            # false = standard (wider) hex range; true = 30° rotated (taller)
var _range_cells := {}               # broad-phase cell set of the current range (shared board ref in standard mode — READ-ONLY)
var _visible_cells := {}             # LOS-visible subset of the range (shared board ref — READ-ONLY)
var _scan_cells := {}                # the set the targeting scans walk: _visible_cells, or _range_cells when the tower shoots through walls
var _reach := 0                      # cached board.tower_reach(data.range_tiles); refreshed with _range_cells

# target_priority resolved to an int once (setup / cycle) so the hot scans
# switch on an int instead of matching a String per candidate.
const PRI_FIRST := 0
const PRI_LAST := 1
const PRI_STRONGEST := 2
const PRI_WEAKEST := 3
var _priority_id := PRI_FIRST

# data.fire_mode resolved to an int once (_apply_levels) for the per-frame match.
const MODE_SINGLE := 0
const MODE_RADIAL := 1
const MODE_LASER := 2
const MODE_ARC := 3
var _fire_mode_id := MODE_SINGLE

func toggle_range_rotation() -> bool:
	range_rotated = not range_rotated
	_refresh_range_cache()
	return range_rotated

# Cache reach + the range's cell set whenever range or rotation changes (setup,
# upgrade, rotation toggle). Standard mode holds the board's memoized disk by
# shared reference and only ever reads it; rotated mode rebuilds its own set.
# The LOS-visible subset is cached the same way, so targeting resolves visibility
# per CELL instead of walking a point-to-point ray per candidate per frame.
# DELIBERATE trade-off: visibility now flips at cell boundaries rather than at the
# enemy's exact point — which is exactly where the range overlay already draws the
# visible / wall-shadowed split for the player, so the two now agree by
# construction. Tunneling towers ignore the split and scan the whole disk.
func _refresh_range_cache() -> void:
	if board == null:
		return
	_reach = board.tower_reach(data.range_tiles)
	if range_rotated:
		_range_cells = board.rotated_range_set(cell, _reach)
	else:
		_range_cells = board.range_cell_set(cell, _reach)
	_visible_cells = board.visible_range_set(cell, _reach, range_rotated)
	_scan_cells = _range_cells if data.ignore_walls else _visible_cells
	_idle_cd = 0.0   # the scan set just changed — look again on the next frame

static func _priority_to_id(p: String) -> int:
	match p:
		"last":
			return PRI_LAST
		"strongest":
			return PRI_STRONGEST
		"weakest":
			return PRI_WEAKEST
		_:
			return PRI_FIRST

static func _mode_to_id(mode: String) -> int:
	match mode:
		"radial":
			return MODE_RADIAL
		"laser":
			return MODE_LASER
		"arc":
			return MODE_ARC
		_:
			return MODE_SINGLE

# Idle-scan gating. A tower whose acquisition scan finds nothing waits this long
# before scanning again instead of re-scanning every frame. The instant a scan
# DOES find a target the normal cooldown-driven path resumes with no added delay,
# so only the FIRST engagement of an enemy entering an empty tower's range can be
# late, by at most IDLE_RESCAN.
const IDLE_RESCAN := 0.1
# Per-tower stagger: the largest fraction of IDLE_RESCAN a tower's wait may be
# shortened by. Derived from the tower's cell, so it is stable for the tower's
# lifetime and towers that go idle on the same frame run at different periods and
# de-phase within a cycle. Shortening (never lengthening) keeps every wait
# <= IDLE_RESCAN, which is what bounds the worst-case engagement delay.
const IDLE_RESCAN_STAGGER := 0.5

var _cooldown := 0.0
var _laser_target = null
var _charge := 0.0
var _focus_cd := 0.0                 # post-kill blind/idle timer (focus_time)
var _idle_cd := 0.0                  # time left before the next acquisition scan (0 = scan now)
var _idle_wait := IDLE_RESCAN        # this tower's staggered idle interval (set in setup)
var _hum: AudioStreamPlayer = null
var _hum_pb: AudioStreamGeneratorPlayback = null
var _hum_phase := 0.0
var _hum_freq := 40.0

# 3D scene
var _body: Node3D                    # container for the composite tower parts (scaled by upgrades)
var _turret: Node3D                  # child of _body carrying the mode silhouette; yaws toward the aim
var _shell_mat: StandardMaterial3D   # dark body material — fire-flash / selection target
var _accent_mat: StandardMaterial3D  # hot emissive material — crosses the bloom threshold
var _base_scale := Vector3.ONE       # upgrade-derived body scale; pulses return to it
var _aims := false                   # single/arc carry a directional feature on _turret
var _aim_yaw := 0.0
var _aim_timer := 0.0
var _selected := false
var _flash_tween: Tween              # upgrade pop only (rare); fire flashes use the manual envelope below
var _flash_t := -1.0                 # elapsed fire-flash envelope time; < 0 = idle
var _breathe_tween: Tween
var _hum_buf := PackedVector2Array() # scratch buffer for batched hum pushes
var _beam_last_frac := -1.0          # last charge frac written to the beam materials
# Selection scratch (multi-target volleys): parallel sort keys + picks reused
# across calls so acquisition allocates nothing per shot.
var _sel_keys := PackedInt32Array()
var _sel_ties := PackedInt32Array()
var _sel_picks: Array = []
var _beam: MeshInstance3D            # laser beam sheath (null until first needed)
var _beam_cyl: CylinderMesh
var _beam_mat: StandardMaterial3D
var _beam_core: MeshInstance3D       # white-hot core inside the sheath
var _beam_core_cyl: CylinderMesh
var _beam_impact: MeshInstance3D     # bright dot at the target end
var _impact_mat: StandardMaterial3D
var _beam_origin_y := 0.0            # laser cone apex height (plinth + cone, upgrade-scaled)
static var _plinth_mat_res: StandardMaterial3D = null
static var _audio_mgr: Node = null   # cached /root/AudioManager (one lookup, not one per volley)

# --- ability badges (real world-space children of the tower) ---
# A row of billboarded hex "windows" hung off the (unscaled) tower root at a
# fixed local offset, fixed world scale. Each badge is a quad with a parallax
# shader: the hex frame is fixed, and the glyph inside reveals more/less of itself
# with camera distance, scaled around a per-icon focal point. The frame scales
# with the tower (perspective handles size); only the reveal scalars (zoom_t for
# window width, focal_t for focal travel) are pushed to the shader per frame.
@export var badge_world_scale: float = 1.0
@export var cam_dist_near: float = 500.0    # camera distance at/below which the glyph is fully in view (zoom_t = 1)
@export var cam_dist_far: float = 1500.0    # camera distance at minimum reveal (zoom_t = 0); 1000 lands ~68%+ in view
@export var focal_center_dist: float = 1000.0  # at/below this distance the focal is fully centered (focal_in)
var _badge_anchor: Node3D = null
var _badge_mats: Array = []          # ShaderMaterial per live badge (zoom_t updated per frame)
var _badge_info: Array = []          # {mi: MeshInstance3D, tip: String} per live badge (hover tooltips)
var _badge_cam_tf := Transform3D()   # camera transform at the last reveal update (skip when unchanged)
var _badge_cam_seen := false
# Display order. `prop` is the TowerData flag; art is art/<file>_{glyph,backplate,rim}.png.
# focal/reveal_* drive the per-icon parallax window (see ABILITY_BADGE_PARALLAX_SPEC).
const ABILITY_BADGES := [
	{"prop": "bit_corruption", "file": "bit_corruption", "focal_out_x": 0.50, "focal_out_y": 0.50, "focal_in_x": 0.50, "focal_in_y": 0.50, "reveal_out": 0.55, "reveal_in": 1.25, "reveal_rate": 1.0, "tip": "Bit Corruption\nBypasses ECC damage resistance."},
	{"prop": "cipher", "file": "cipher", "focal_out_x": 0.48, "focal_out_y": 0.50, "focal_in_x": 0.48, "focal_in_y": 0.50, "reveal_out": 0.52, "reveal_in": 1.05, "reveal_rate": 1.0, "tip": "Cipher\nSees and targets Encrypted enemies."},
	{"prop": "buffer_overflow", "file": "buffer_overflow", "focal_out_x": 0.66, "focal_out_y": 0.34, "focal_in_x": 0.50, "focal_in_y": 0.50, "reveal_out": 0.50, "reveal_in": 1.40, "reveal_rate": 1.0, "tip": "Buffer Overflow\nSurplus damage spills into the target's decay children."},
	{"prop": "execute_no_decay", "file": "garbage_collection", "focal_out_x": 0.50, "focal_out_y": 0.34, "focal_in_x": 0.50, "focal_in_y": 0.50, "reveal_out": 0.55, "reveal_in": 1.25, "reveal_rate": 1.0, "tip": "Garbage Collection\nAn Execute kill takes the target's whole decay chain with it."},
	{"prop": "ignore_walls", "file": "tunneling", "focal_out_x": 0.84, "focal_out_y": 0.50, "focal_in_x": 0.60, "focal_in_y": 0.50, "reveal_out": 0.50, "reveal_in": 1.15, "reveal_rate": 1.0, "tip": "Tunneling\nAttacks through blocking tiles."},
	{"prop": "dos", "file": "dos", "focal_out_x": 0.72, "focal_out_y": 0.50, "focal_in_x": 0.50, "focal_in_y": 0.50, "reveal_out": 0.70, "reveal_in": 1.15, "reveal_rate": 1.0, "tip": "Denial of Service\nFreezes an enemy, then slows it."},
]
const BADGE_BASE_WORLD := 30.0       # frame edge length (world units) at scale 1.0; tune via badge_world_scale
static var _badge_tex := {}          # texture file base -> Texture2D (shared cache, caches misses)
static var _badge_shader_res: Shader = null
const _BADGE_SHADER := """
shader_type spatial;
// depth_test_disabled: badges are a HUD-like overlay — never occluded by the
// board, path, range highlight, towers or enemies. High render_priority (set on
// the material) keeps them sorted on top of other transparent geometry too.
render_mode unshaded, cull_disabled, depth_test_disabled;

uniform sampler2D glyph_tex : source_color;
uniform sampler2D backplate_tex : source_color;
uniform sampler2D rim_tex : source_color;
uniform vec2 focal_out = vec2(0.5, 0.5);
uniform vec2 focal_in = vec2(0.5, 0.5);
uniform float reveal_out = 0.5;
uniform float reveal_in = 1.0;
uniform float reveal_rate = 1.0;
uniform float zoom_t = 0.0;
uniform float focal_t = 0.0;

void vertex() {
	// Billboard the quad to face the camera while preserving its world scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0]),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1]),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2]),
		MODEL_MATRIX[3]);
}

void fragment() {
	float k = pow(clamp(zoom_t, 0.0, 1.0), reveal_rate);
	float kf = pow(clamp(focal_t, 0.0, 1.0), reveal_rate);
	float w = mix(reveal_out, reveal_in, k);          // window width fraction
	vec2 fcur = mix(focal_out, focal_in, kf);         // focal centers on its own (earlier) distance ramp
	vec2 guv = fcur + (UV - 0.5) * w;                 // sample window around the current focal
	vec4 glyph = texture(glyph_tex, guv);
	if (guv.x < 0.0 || guv.x > 1.0 || guv.y < 0.0 || guv.y > 1.0) {
		glyph.a = 0.0;
	}
	vec4 back = texture(backplate_tex, UV);
	vec4 rim = texture(rim_tex, UV);
	vec3 col = back.rgb;
	float gin = glyph.a * back.a;                     // clip glyph to hex interior
	col = mix(col, glyph.rgb, gin);
	col = mix(col, rim.rgb, rim.a);
	ALBEDO = col;
	ALPHA = max(max(back.a, gin), rim.a);
}
"""

const LASER_START_FRAC := 0.1
const BEAM_GLOW := 2.2
const HUM_BASE_HZ := 40.0
const HUM_PITCH_MAX := 25.0
const HUM_PITCH_CURVE := 0.6
const HUM_MIX_RATE := 44100.0
const HUM_TABLE := 2048
const HUM_VOL_DB := -3.0

const BODY_HEIGHT := 8.0             # nominal body height (world units)
const BEAM_TARGET_LIFT := 2.0        # mid-height of an enemy body (Enemy3D.BODY_HEIGHT * 0.5)
const BEAM_BASE_THICK := 0.6
const BEAM_FULL_THICK := 1.6

const LASER_CONE_H := 60.0           # laser cone height; the beam leaves its apex
const LASER_TIP_FRAC := 0.8          # upper cone fraction rendered as the hot accent
const PLINTH_H := 2.5                # shared hex plinth height under every body
const PLINTH_COLOR := Color(0.30, 0.32, 0.38)
const HORN_FLARE_POW := 2.4          # arc horn flare curve (radius vs height)
const ARC_THROAT_F := 0.85           # arc horn: throat dish / rim-lip split fraction
const SHELL_EMISSION := 0.35         # idle shell glow — below the bloom threshold
const ACCENT_EMISSION := 1.4         # hot accents — cross the bloom threshold
const FLASH_EMISSION := 1.8          # fire-flash shell spike (blooms for a blink)
const FLASH_GLOW_TIME := 0.18        # fire-flash emission ease-back duration
const FLASH_SCALE_TIME := 0.15       # fire-flash scale punch recovery duration
const FLASH_SCALE_FROM := Vector3(1.07, 0.94, 1.07)   # squash factor composed on _base_scale
const BACK_OVERSHOOT := 1.70158      # Tween TRANS_BACK constant (matched by the manual envelope)
const SELECT_BREATHE_HI := 0.9       # selection breathe peak — still below bloom
const AIM_RELAX_TIME := 1.0          # yaw back to rest after this long targetless
const TIER_RING_H := 1.4             # tier progression ring dimensions
const TIER_RING_STEP := 2.6

static var _hum_table: PackedFloat32Array

static func _hum_wavetable() -> PackedFloat32Array:
	if not _hum_table.is_empty():
		return _hum_table
	var tbl := PackedFloat32Array()
	tbl.resize(HUM_TABLE)
	var mx := 0.0
	for i in HUM_TABLE:
		var ph := TAU * float(i) / float(HUM_TABLE)
		var s := 0.0
		for k in range(1, 13):
			s += (1.0 / pow(float(k), 1.2)) * sin(ph * float(k))
		tbl[i] = s
		mx = maxf(mx, absf(s))
	if mx > 0.0:
		for i in HUM_TABLE:
			tbl[i] = tbl[i] / mx
	_hum_table = tbl
	return _hum_table

# `pos_plane` is the cell's plane center (Vector2); board.cell_center_world
# returns that on GameBoard3D as well, matching the 2D API.
func setup(d: TowerData, b, pos_plane: Vector2) -> void:
	base_data = d
	board = b
	pp = pos_plane
	cell = b.world_cell(pos_plane)
	# Stable per-tower idle-scan phase (see IDLE_RESCAN_STAGGER).
	_idle_wait = IDLE_RESCAN * (1.0 - IDLE_RESCAN_STAGGER * float(posmod(hash(cell), 64)) / 64.0)
	invested = d.cost
	slot_levels = []
	for _i in range(slot_count()):
		slot_levels.append(0)
	_priority_id = _priority_to_id(target_priority)
	_apply_levels()
	_sync_transform()
	_rebuild_body()

func _sync_transform() -> void:
	position = Vector3(pp.x, GameBoard3D.BUS_TOP, pp.y)

# ---------------------------------------------------------------- upgrades (ported)
const SELL_REFUND := 0.75

func slot_count() -> int:
	return mini(3, base_data.upgrades.size())

func slot_name(s: int) -> String:
	return str(base_data.upgrades[s].get("name", "Slot %d" % (s + 1)))

func slot_max(s: int) -> int:
	var tiers = base_data.upgrades[s].get("tiers", [])
	return mini(5, tiers.size())

func slot_level(s: int) -> int:
	return slot_levels[s]

# True if path s simply has a tier left to buy (ignores the crosspath rule).
func has_next_tier(s: int) -> bool:
	return s >= 0 and s < slot_count() and slot_levels[s] < slot_max(s)

# BTD6 crosspathing: at most two of the three paths may rise above tier 0, and
# only one of those may rise above tier 2 (the other is capped at tier 2).
func can_upgrade(s: int) -> bool:
	if not has_next_tier(s):
		return false
	var nonzero := 0
	var above2 := 0
	var s_above2 := false
	for i in range(slot_count()):
		var lv: int = slot_levels[i]
		if lv > 0:
			nonzero += 1
		if lv > 2:
			above2 += 1
			if i == s:
				s_above2 = true
	# rule 1: opening a third path is illegal
	if slot_levels[s] == 0 and nonzero >= 2:
		return false
	# rules 2 & 3: reaching tier 3 requires being the sole path above tier 2
	if slot_levels[s] + 1 >= 3 and above2 >= 1 and not s_above2:
		return false
	return true

func next_cost(s: int) -> int:
	if not has_next_tier(s):
		return -1
	return int(base_data.upgrades[s]["tiers"][slot_levels[s]].get("cost", 0))

func upgrade(s: int) -> void:
	if not can_upgrade(s):
		return
	invested += next_cost(s)
	slot_levels[s] += 1
	_apply_levels()
	_rebuild_body()
	_upgrade_pop()

func sell_value() -> int:
	return int(floor(invested * SELL_REFUND))

func refund_percent() -> int:
	return int(round(SELL_REFUND * 100.0))

func tier_summary(s: int) -> String:
	if not has_next_tier(s):
		return ""
	var tier: Dictionary = base_data.upgrades[s]["tiers"][slot_levels[s]]
	var lines := []
	var labels := {"damage": "Damage", "range": "Range", "fire_rate": "Fire rate", "directions": "Projectiles", "targets": "Targets", "arc_angle": "Arc", "ramp_time": "Ramp time", "focus_time": "Focus delay", "charge_retain": "Prefocus", "dos_freeze": "DoS freeze", "dos_slow_time": "DoS slow", "dos_slow_factor": "DoS factor", "ecc_pierce": "ECC pierce", "execute_threshold": "Execute", "height": "Height", "width": "Width"}
	for key in ["damage", "range", "fire_rate", "directions", "targets", "arc_angle", "ramp_time", "focus_time", "charge_retain", "dos_freeze", "dos_slow_time", "dos_slow_factor", "ecc_pierce", "execute_threshold", "height", "width"]:
		if tier.has(key) and float(tier[key]) != 0.0:
			lines.append("%s %s" % [labels[key], _delta_str(key, float(tier[key]))])
	if str(tier.get("color", "")) != "":
		lines.append("Color change")
	# These must read exactly as the ability badges name them (see ABILITY_BADGES):
	# a tier that grants Tunneling should not describe itself as "Ignore walls"
	# while the badge it lights up says Tunneling.
	var flag_labels := {"cipher": "Cipher", "bit_corruption": "Bit Corruption", "ignore_walls": "Tunneling", "buffer_overflow": "Buffer Overflow", "dos": "Denial of Service", "execute_no_decay": "Garbage Collection"}
	for key in ["cipher", "bit_corruption", "ignore_walls", "buffer_overflow", "dos", "execute_no_decay"]:
		var fv := str(tier.get(key, ""))
		if fv == "on":
			lines.append("%s: enabled" % flag_labels[key])
		elif fv == "off":
			lines.append("%s: removed" % flag_labels[key])
	if lines.is_empty():
		return "No stat change"
	return "\n".join(lines)

func _delta_str(key: String, v: float) -> String:
	var sgn := "+" if v > 0.0 else ""
	match key:
		"range", "directions", "targets":
			return "%s%d" % [sgn, int(round(v))]
		"fire_rate":
			return "%s%s/s" % [sgn, _trim(v)]
		"ramp_time", "focus_time", "dos_freeze", "dos_slow_time":
			return "%s%ss" % [sgn, _trim(v)]
		"arc_angle":
			return "%s%s°" % [sgn, _trim(v)]
		"dos_slow_factor":
			return "%s%s×" % [sgn, _trim(v)]
		"ecc_pierce", "execute_threshold", "charge_retain":
			return "%s%s%%" % [sgn, _trim(v * 100.0)]
		_:
			return "%s%s" % [sgn, _trim(v)]

func _trim(v: float) -> String:
	var s := "%.2f" % v
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s

func _apply_levels() -> void:
	data = base_data.duplicate() as TowerData
	for s in range(slot_count()):
		var tiers = base_data.upgrades[s].get("tiers", [])
		for i in range(slot_levels[s]):
			_apply_tier(tiers[i])
	_fire_mode_id = _mode_to_id(data.fire_mode)
	_refresh_range_cache()

func _apply_tier(tier: Dictionary) -> void:
	data.damage += float(tier.get("damage", 0.0))
	data.range_tiles += int(round(float(tier.get("range", 0.0))))
	data.fire_rate += float(tier.get("fire_rate", 0.0))
	data.directions += int(round(float(tier.get("directions", 0.0))))
	data.targets = maxi(1, data.targets + int(round(float(tier.get("targets", 0.0)))))
	data.arc_angle = clampf(data.arc_angle + float(tier.get("arc_angle", 0.0)), 1.0, 360.0)
	data.dos_freeze = maxf(0.0, data.dos_freeze + float(tier.get("dos_freeze", 0.0)))
	data.dos_slow_time = maxf(0.0, data.dos_slow_time + float(tier.get("dos_slow_time", 0.0)))
	data.dos_slow_factor = clampf(data.dos_slow_factor + float(tier.get("dos_slow_factor", 0.0)), 0.05, 1.0)
	data.ecc_pierce = clampf(data.ecc_pierce + float(tier.get("ecc_pierce", 0.0)), 0.0, 1.0)
	data.execute_threshold = clampf(data.execute_threshold + float(tier.get("execute_threshold", 0.0)), 0.0, 1.0)
	data.ramp_time = maxf(0.0, data.ramp_time + float(tier.get("ramp_time", 0.0)))
	if tier.has("focus_time"):
		data.focus_time = maxf(0.1, data.focus_time + float(tier["focus_time"]))
	data.charge_retain = clampf(data.charge_retain + float(tier.get("charge_retain", 0.0)), 0.0, 1.0)
	data.height_scale = maxf(0.05, data.height_scale + float(tier.get("height", 0.0)))
	data.width_scale = maxf(0.05, data.width_scale + float(tier.get("width", 0.0)))
	var col := str(tier.get("color", ""))
	if col != "":
		data.color = Color(col)
	_apply_flag("cipher", tier)
	_apply_flag("bit_corruption", tier)
	_apply_flag("ignore_walls", tier)
	_apply_flag("buffer_overflow", tier)
	_apply_flag("dos", tier)
	_apply_flag("execute_no_decay", tier)

func _apply_flag(key: String, tier: Dictionary) -> void:
	var v := str(tier.get(key, ""))
	if v == "on":
		data.set(key, true)
	elif v == "off":
		data.set(key, false)

# ---------------------------------------------------------------- per-frame
func _process(delta: float) -> void:
	if data == null:
		return
	match _fire_mode_id:
		MODE_RADIAL:
			_process_radial(delta)
		MODE_LASER:
			_process_laser(delta)
		MODE_ARC:
			_process_arc(delta)
		_:
			_process_targeted(delta)
	if _flash_t >= 0.0:
		_advance_flash(delta)
	if _aims and _turret != null and is_instance_valid(_turret):
		_update_aim(delta)
	if _badge_anchor != null and not _badge_mats.is_empty():
		_update_badge_zoom()

# Yaw the turret toward the last fired-at direction; relax to rest when no
# target has been engaged for AIM_RELAX_TIME. Radial/laser stay symmetric.
func _update_aim(delta: float) -> void:
	var tgt := 0.0
	if _aim_timer > 0.0:
		_aim_timer -= delta
		tgt = _aim_yaw
	elif absf(wrapf(_turret.rotation.y, -PI, PI)) < 0.001:
		return   # settled at rest — nothing left to lerp
	_turret.rotation.y = lerp_angle(_turret.rotation.y, tgt, minf(1.0, 10.0 * delta))

# Plane dir (dx, dy) maps to 3D (dx, 0, dy); the aim features are built along
# local +X, and rotation.y sends +X to (cos yaw, 0, -sin yaw).
func _note_aim(dir: Vector2) -> void:
	if dir.length_squared() < 0.000001:
		return
	_aim_yaw = atan2(-dir.y, dir.x)
	_aim_timer = AIM_RELAX_TIME

# Re-arm after a shot. ADDING the period to the (negative) overshoot rather than
# assigning it is what keeps the long-run cadence at exactly `fire_rate`. A plain
# assignment rounded every cooldown up to a whole frame, so the real rate was
# 60/ceil(60/fire_rate): anything above 30/s was quantised to 30/s at 60fps and
# bought nothing, and the effective rate changed with the player's framerate.
func _rearm() -> void:
	var period: float = 1.0 / data.fire_rate
	_cooldown += period
	if _cooldown < 0.0:
		# Debt bigger than one whole period — either fire_rate is above the frame
		# rate (a tower still fires at most once per frame) or the cooldown ran
		# negative through a long idle gate. Start a clean period either way.
		_cooldown = period

func _process_targeted(delta: float) -> void:
	# The cooldown keeps ticking through an idle gate, so a gated tower is never
	# behind on its cadence once something walks into range.
	_cooldown -= delta
	if _idle_cd > 0.0:
		_idle_cd -= delta
		return
	if _cooldown <= 0.0:
		# `targets` lets one fire cycle engage that many DISTINCT enemies (one shot
		# each, no overkill), furthest-along first; default 1 = the classic single
		# shot, which skips the multi-target bookkeeping entirely.
		if data.targets <= 1:
			var t = _acquire_target()
			if t != null:
				_shoot(t)
				_fire_flash()
				_play_sfx("tower_fire")
				_rearm()
			else:
				_idle_cd = _idle_wait
		else:
			var ts := _acquire_targets(data.targets)
			if not ts.is_empty():
				for tt in ts:
					_shoot(tt)
				_fire_flash()
				_play_sfx("tower_fire")   # once per volley, not per target
				_rearm()
			else:
				_idle_cd = _idle_wait

func _process_radial(delta: float) -> void:
	_cooldown -= delta
	if _idle_cd > 0.0:
		_idle_cd -= delta
		return
	if _cooldown <= 0.0:
		if _any_enemy_in_range():
			_fire_volley()
			_rearm()
		else:
			# Cooldown still parks at 0 so the volley leaves on the very frame the
			# gate reopens with an enemy present.
			_cooldown = 0.0
			_idle_cd = _idle_wait

# Arc: aim at the prioritised target and emit one expanding wave per shot.
func _process_arc(delta: float) -> void:
	_cooldown -= delta
	if _idle_cd > 0.0:
		_idle_cd -= delta
		return
	if _cooldown <= 0.0:
		var t = _find_target()
		if t != null:
			_fire_arc(t)
			_rearm()
		else:
			_idle_cd = _idle_wait

func _fire_arc(t) -> void:
	var w := ArcWave3D.new()
	w.setup(pp, t.pp - pp, data.damage, data.projectile_speed,
			cell, board.tower_reach(data.range_tiles), data.color, board)
	w.arc_angle = data.arc_angle
	w.pierces_ecc = data.bit_corruption
	w.ecc_pierce = data.ecc_pierce
	w.execute_threshold = data.execute_threshold
	w.execute_no_decay = data.execute_no_decay
	w.applies_dos = data.dos
	w.can_see_encrypted = data.cipher
	w.dos_freeze = data.dos_freeze
	w.dos_slow_time = data.dos_slow_time
	w.dos_slow_factor = data.dos_slow_factor
	board.add_projectile(w)
	_note_aim(t.pp - pp)
	_fire_flash()
	# A DoS wave sounds like a jam, a damage wave like a whoosh — matches the
	# frost-vs-color tint the wave itself renders with.
	_play_sfx("dos_wave" if data.dos else "arc_fire")

func _any_enemy_in_range() -> bool:
	# Radial ignores line of sight on purpose (the spokes themselves are what walls
	# stop), so this gate stays on the full range disk, not _scan_cells.
	# Broad phase: only enemies bucketed in the range's own cells are visited.
	var cands: Array = board.enemies_in_cell_set(_range_cells)
	for e in cands:
		if not is_instance_valid(e):
			continue
		if not _can_see(e):
			continue
		if _range_cells.has(e.cell):
			return true
	return false

func _fire_volley() -> void:
	var n: int = maxi(1, data.directions)
	for i in range(n):
		var ang := TAU * float(i) / float(n)
		# obtain() reuses a parked spoke (fully reset) instead of allocating one
		# per shot; a volley is `directions` nodes, so this is the hottest
		# allocation site in the game.
		var p := RadialProjectile3D.obtain(board)
		p.setup(pp, Vector2(cos(ang), sin(ang)), data.damage, data.projectile_speed,
				cell, board.tower_reach(data.range_tiles), data.color, board)
		p.ignore_walls = data.ignore_walls
		p.pierces_ecc = data.bit_corruption
		p.ecc_pierce = data.ecc_pierce
		p.execute_threshold = data.execute_threshold
		p.execute_no_decay = data.execute_no_decay
		p.can_see_encrypted = data.cipher
		p.applies_dos = data.dos
		p.dos_freeze = data.dos_freeze
		p.dos_slow_time = data.dos_slow_time
		p.dos_slow_factor = data.dos_slow_factor
		board.add_projectile(p)
	_fire_flash()
	_play_sfx("radial_fire")

func _process_laser(delta: float) -> void:
	if _idle_cd > 0.0:
		_idle_cd -= delta
	# focus_time: after a kill the beam is blind/idle for this long. This caps
	# kills/sec (swarm tax) while barely touching single-target DPS.
	# Prefocus (charge_retain) is applied ONCE per target-loss, at the two places a
	# target is actually lost: it goes invalid, or it dies. The "no target right
	# now" states below then leave _charge alone, so the retained ramp survives the
	# focus delay and the idle gate. At the default charge_retain = 0 those two
	# sites zero the charge outright and the hold-states are no-ops, so the beam
	# behaves exactly as it did before Prefocus existed.
	if _focus_cd > 0.0:
		_focus_cd -= delta
		_laser_target = null
		_set_hum(false, 0.0)
		_update_beam(0.0, false)
		return
	if not _target_still_valid(_laser_target):
		_laser_target = null
		_charge *= data.charge_retain   # ramp decays on target loss (fully, unless Prefocus)
	if _laser_target == null:
		# The idle gate only ever arms on a scan that found nothing, so a kill (which
		# arms _focus_cd instead, with _idle_cd at 0) never re-locks any later than it
		# does today: the frame focus_time expires is a scanning frame.
		if _idle_cd > 0.0:
			_set_hum(false, 0.0)
			_update_beam(0.0, false)
			return
		_laser_target = _acquire_target()
		if _laser_target != null:
			_fire_flash()      # lock-on blink — the laser's per-shot feedback
		else:
			_idle_cd = _idle_wait
	if _laser_target != null:
		_charge = minf(_charge + delta, data.ramp_time)
		var cr := 1.0 if data.ramp_time <= 0.0 else clampf(_charge / data.ramp_time, 0.0, 1.0)
		# Convex (quadratic ease-in) ramp: ~0 early, full at ramp_time.
		var factor := cr * cr
		var killed: bool = _laser_target.take_damage(data.damage * factor * delta, data.bit_corruption,
				false, data.ecc_pierce, data.execute_threshold, data.execute_no_decay)
		if killed:
			_laser_target = null
			_charge *= data.charge_retain   # a kill is the other target-loss point
			_focus_cd = data.focus_time
			_set_hum(false, 0.0)
			_update_beam(0.0, false)
			return
		_set_hum(true, cr)
		_update_beam(factor, true)
	else:
		_set_hum(false, 0.0)
		_update_beam(0.0, false)

func _play_sfx(sound_name: String) -> void:
	if _audio_mgr == null or not is_instance_valid(_audio_mgr):
		_audio_mgr = get_node_or_null("/root/AudioManager")
	if _audio_mgr != null:
		_audio_mgr.play_sfx(sound_name)

func _set_hum(active: bool, charge_ratio: float) -> void:
	if active:
		if _hum == null:
			var gen := AudioStreamGenerator.new()
			gen.mix_rate = HUM_MIX_RATE
			gen.buffer_length = 0.1
			_hum = AudioStreamPlayer.new()
			_hum.stream = gen
			var am = get_node_or_null("/root/AudioManager")
			_hum.bus = am.SFX_BUS if am else "Master"
			_hum.volume_db = HUM_VOL_DB
			add_child(_hum)
		if not _hum.playing:
			_hum.play()
			_hum_pb = _hum.get_stream_playback() as AudioStreamGeneratorPlayback
			_hum_phase = 0.0
		_hum_freq = HUM_BASE_HZ * lerpf(1.0, HUM_PITCH_MAX, pow(charge_ratio, HUM_PITCH_CURVE))
		_fill_hum()
	elif _hum != null and _hum.playing:
		_hum.stop()
		_hum_pb = null

func _fill_hum() -> void:
	if _hum_pb == null:
		return
	var tbl := _hum_wavetable()
	var n := tbl.size()
	var inc: float = _hum_freq / HUM_MIX_RATE * float(n)
	var avail := _hum_pb.get_frames_available()
	if avail <= 0:
		return
	# Batch: fill one PackedVector2Array and hand it over in a single
	# push_buffer() instead of one push_frame() call per sample.
	if _hum_buf.size() != avail:
		_hum_buf.resize(avail)
	for i in avail:
		var i0 := int(_hum_phase) % n
		var i1 := (i0 + 1) % n
		var frac: float = _hum_phase - floor(_hum_phase)
		var s: float = lerpf(tbl[i0], tbl[i1], frac)
		_hum_buf[i] = Vector2(s, s)
		_hum_phase += inc
		if _hum_phase >= float(n):
			_hum_phase -= float(n)
	_hum_pb.push_buffer(_hum_buf)

# Range AND line of sight in one cell-set probe, against the very set the
# acquisition scan uses — so a lock can never be dropped by a test the immediate
# re-lock would pass, or held by one it would fail.
func _target_still_valid(t) -> bool:
	if t == null or not is_instance_valid(t):
		return false
	return _scan_cells.has(t.cell)

func _find_target():
	return _acquire_target()

func _can_see(e) -> bool:
	return data.cipher or not e.data.encrypted

func _acquire_target():
	var best = null
	var best_key := 0
	var best_tie := 0
	var first := true
	# Broad phase: the bucketed query visits only enemies whose cached cell is
	# inside the scan set, and membership in that set IS the range + LOS test (see
	# _refresh_range_cache). Encryption (_can_see) is unchanged.
	var cands: Array = board.enemies_in_cell_set(_scan_cells)
	for e in cands:
		if not is_instance_valid(e):
			continue
		if not _can_see(e):
			continue
		if not _scan_cells.has(e.cell):
			continue
		var prog: int = e.progress()
		var key: int
		var tie := 0
		match _priority_id:
			PRI_LAST:
				key = -prog
			PRI_STRONGEST:
				key = e.data.rank
				tie = prog
			PRI_WEAKEST:
				key = -e.data.rank
				tie = prog
			_:
				key = prog
		if first or key > best_key or (key == best_key and tie > best_tie):
			first = false
			best_key = key
			best_tie = tie
			best = e
	return best

# Up to `n` distinct valid enemies, ordered by the current target priority
# (furthest-along / last / strongest first). Same range/LOS/Cipher gates as
# _acquire_target. Used by single mode's multi-target fire. Returns a scratch
# array reused across calls — consume it before the next acquisition.
func _acquire_targets(n: int) -> Array:
	_sel_keys.clear()
	_sel_ties.clear()
	_sel_picks.clear()
	var cands: Array = board.enemies_in_cell_set(_scan_cells)
	for e in cands:
		if not is_instance_valid(e):
			continue
		if not _can_see(e):
			continue
		if not _scan_cells.has(e.cell):
			continue
		var prog: int = e.progress()
		var key: int
		var tie := 0
		match _priority_id:
			PRI_LAST:
				key = -prog
			PRI_STRONGEST:
				key = e.data.rank
				tie = prog
			PRI_WEAKEST:
				key = -e.data.rank
				tie = prog
			_:
				key = prog
		# Bounded descending insertion — the same (key, tie) order the old
		# sort_custom produced, without per-candidate Dictionaries or a sort.
		var size: int = _sel_picks.size()
		if size >= n:
			var wk: int = _sel_keys[size - 1]
			var wt: int = _sel_ties[size - 1]
			if not (key > wk or (key == wk and tie > wt)):
				continue
		var idx: int = size
		while idx > 0:
			var pk: int = _sel_keys[idx - 1]
			var pt: int = _sel_ties[idx - 1]
			if key > pk or (key == pk and tie > pt):
				idx -= 1
			else:
				break
		_sel_keys.insert(idx, key)
		_sel_ties.insert(idx, tie)
		_sel_picks.insert(idx, e)
		if _sel_picks.size() > n:
			_sel_keys.remove_at(n)
			_sel_ties.remove_at(n)
			_sel_picks.remove_at(n)
	return _sel_picks

func cycle_target_priority() -> String:
	match target_priority:
		"first":
			target_priority = "last"
		"last":
			target_priority = "strongest"
		"strongest":
			target_priority = "weakest"
		_:
			target_priority = "first"
	_priority_id = _priority_to_id(target_priority)
	_laser_target = null
	_charge = 0.0
	return target_priority

func _shoot(t) -> void:
	_note_aim(t.pp - pp)
	var p := Projectile3D.obtain(board)
	p.setup(pp, t, data.damage, data.projectile_speed, data.color, data.bit_corruption, data.buffer_overflow, data.dos)
	p.ecc_pierce = data.ecc_pierce
	p.execute_threshold = data.execute_threshold
	p.execute_no_decay = data.execute_no_decay
	p.dos_freeze = data.dos_freeze
	p.dos_slow_time = data.dos_slow_time
	p.dos_slow_factor = data.dos_slow_factor
	board.add_projectile(p)

# ---------------------------------------------------------------- body (3D)
# Every body = a shared gunmetal hex plinth (the chip socket the component is
# seated in) + one colour-coded, FLAT-SHADED low-poly silhouette per fire mode:
#   single -> octagonal cylinder; radial -> polyhedral torus bristling with
#   spikes; laser -> cone; arc -> flared horn / bell (opens upward).
# Each silhouette splits into a dark shell and a hot emissive accent (single:
# cap plate; laser: cone tip; radial: spikes; arc: rim lip + throat dish) so
# the accent crosses the bloom threshold while the shell stays dark. Single and
# arc also carry a small directional feature (prong / rim fin) on the yawing
# _turret child; radial and laser stay symmetric. Built by hand with per-face
# normals so they read as faceted low-poly (Godot's CylinderMesh/TorusMesh use
# smooth normals, which looked round / "high poly").
func _rebuild_body() -> void:
	_kill_body_tweens()
	if _body != null and is_instance_valid(_body):
		_body.queue_free()
		_body = null
	_turret = null
	if data == null:
		return
	_body = Node3D.new()
	add_child(_body)
	_turret = Node3D.new()
	_body.add_child(_turret)
	_shell_mat = _make_shell_mat()
	_accent_mat = _make_accent_mat(data.fire_mode == "arc")
	_aims = data.fire_mode != "radial" and data.fire_mode != "laser"
	var r: float = GameBoard3D.TOWER_RADIUS
	# Plinth flats follow the hex cell's; inside _body (not _turret) so upgrade
	# scaling composes but aim yaw never twists it off the cell.
	_part(_low_poly_cylinder(r * 0.97, PLINTH_H, 6, -PI / 6.0), _plinth_mat(), 0.0)
	var ring_r := r * 0.98
	# Outer extent ~0.9 * TOWER_RADIUS: nearly fills the hex footprint with a
	# small margin so the body never reads as crossing into a neighbour cell.
	match data.fire_mode:
		"radial":
			# torus shell + a spike raised from every face, bristling outward in
			# all directions — echoing the all-directions burst. Sized so the
			# spike tips still sit inside the hex footprint.
			var inner := r * 0.30
			var outer := r * 0.72
			var tube := (outer - inner) * 0.5
			var spike := tube * 1.15
			var ty := PLINTH_H + tube + spike
			_part(_low_poly_torus(inner, outer, 8, 6), _shell_mat, ty, _turret)
			_part(_torus_spikes(inner, outer, 8, 6, spike), _accent_mat, ty, _turret)
			ring_r = r * 0.55
		"laser":
			# Cone lofted as shell frustum + hot tip segment; the beam leaves the
			# apex (_beam_origin_y below). Tip sunk/oversized a hair to seal the seam.
			var split := LASER_CONE_H * LASER_TIP_FRAC
			var tip_r := r * 0.9 * (1.0 - LASER_TIP_FRAC)
			_part(_low_poly_frustum(r * 0.9, tip_r, split, 6), _shell_mat, PLINTH_H, _turret)
			_part(_low_poly_cone(tip_r * 1.06, LASER_CONE_H - split + 0.3, 6), _accent_mat, PLINTH_H + split - 0.3, _turret)
		"arc":
			# Flared emitter: narrow base, concave flare to a wide mouth. Shell up
			# to the throat, accent rim lip above it, and an emissive dish closing
			# the throat so the horn reads as charged from within. A rim fin at +X
			# is the aim cue.
			var b_r := r * 0.26
			var rim := r * 0.95
			var h := 52.0
			_part(_low_poly_horn(b_r, rim, h, 8, 5, 0.0, ARC_THROAT_F, true), _shell_mat, PLINTH_H, _turret)
			_part(_low_poly_horn(b_r, rim, h, 8, 2, ARC_THROAT_F, 1.0, false), _accent_mat, PLINTH_H, _turret)
			var dish_r: float = b_r + (rim - b_r) * pow(ARC_THROAT_F, HORN_FLARE_POW)
			_part(_disc(dish_r, 8), _accent_mat, PLINTH_H + h * ARC_THROAT_F, _turret)
			_part(_tri_prism(
					Vector3(rim * 0.70, h * 0.96, 0.9), Vector3(rim, h * 0.96, 0.9), Vector3(rim * 0.90, h * 1.12, 0.9),
					Vector3(rim * 0.70, h * 0.96, -0.9), Vector3(rim, h * 0.96, -0.9), Vector3(rim * 0.90, h * 1.12, -0.9)),
					_accent_mat, PLINTH_H, _turret)
			ring_r = r * 0.45
		_:
			# Cylinder + hot cap plate; a flat prong wedge past the cap rim at +X
			# is the aim cue. Overlapping parts embed slightly to avoid coplanar caps.
			var body_h := 40.0
			var cap_y := PLINTH_H + body_h - 0.5
			_part(_low_poly_cylinder(r * 0.9, body_h, 8), _shell_mat, PLINTH_H, _turret)
			_part(_low_poly_cylinder(r * 0.92, 2.2, 8), _accent_mat, cap_y, _turret)
			_part(_tri_prism(
					Vector3(r * 0.55, 2.4, -4.0), Vector3(r * 0.55, 2.4, 4.0), Vector3(r * 0.98, 2.4, 0.0),
					Vector3(r * 0.55, 0.0, -4.0), Vector3(r * 0.55, 0.0, 4.0), Vector3(r * 0.98, 0.0, 0.0)),
					_accent_mat, cap_y + 1.6, _turret)
	# Tier progression marks: one thin accent ring per purchased tier, racked up
	# the base like a chip's pin rows — visible even when a tier authors no
	# size/colour delta.
	var total_tiers := 0
	for lv in slot_levels:
		total_tiers += int(lv)
	for i in range(total_tiers):
		_part(_low_poly_cylinder(ring_r, TIER_RING_H, 8), _accent_mat, PLINTH_H + 0.8 + TIER_RING_STEP * float(i))
	# Upgrades can reshape the body: scale width in the plane (X/Z) and height in Y.
	# Scaling the whole container keeps every fire mode (and its part offsets)
	# correct; _base_scale is what fire-flash / upgrade pulses return to.
	_base_scale = Vector3(maxf(0.05, data.width_scale), maxf(0.05, data.height_scale), maxf(0.05, data.width_scale))
	_body.scale = _base_scale
	# Laser beam origin: the cone apex (plinth + cone height, upgrade-scaled),
	# backed off a touch so the beam visibly leaves the very tip.
	_beam_origin_y = (PLINTH_H + LASER_CONE_H * 0.985) * _base_scale.y
	# An upgrade may recolour the tower; drop the beam-material memo so the next
	# _update_beam rewrites the charge-driven values with the new colour.
	_beam_last_frac = -1.0
	if _selected:
		_apply_selection_mat()

func _part(mesh: Mesh, mat: Material, y: float, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position.y = y
	if parent == null:
		parent = _body
	parent.add_child(mi)
	return mi

# Add a flat triangle with an outward normal (away from `ctr`). Winding follows
# the normal (matches _add_prism's convention in GameBoard3D) so the closed
# bodies survive back-face culling.
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ctr: Vector3) -> void:
	var nrm := (b - a).cross(c - a)
	if nrm.length() < 0.000001:
		return
	nrm = nrm.normalized()
	if nrm.dot((a + b + c) / 3.0 - ctr) < 0.0:
		nrm = -nrm
		var t := b
		b = c
		c = t
	for v in [a, b, c]:
		st.set_normal(nrm); st.add_vertex(v)

# Flat-shaded N-gon prism (base at y=0, up to y=height). `phase` rotates the
# corners (the hex plinth uses it to align with the cell's corners).
func _low_poly_cylinder(rad: float, height: float, sides: int, phase := 0.0) -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ctr := Vector3(0, height * 0.5, 0)
	var topc := Vector3(0, height, 0)
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides) + phase
		var a1 := TAU * float(i + 1) / float(sides) + phase
		var b0 := Vector3(cos(a0) * rad, 0, sin(a0) * rad)
		var b1 := Vector3(cos(a1) * rad, 0, sin(a1) * rad)
		var t0 := b0 + Vector3(0, height, 0)
		var t1 := b1 + Vector3(0, height, 0)
		_tri(st, b0, b1, t1, ctr); _tri(st, b0, t1, t0, ctr)   # side quad
		_tri(st, topc, t0, t1, ctr)                            # top cap
		_tri(st, Vector3.ZERO, b1, b0, ctr)                    # bottom cap
	return st.commit()

# Flat-shaded N-gon cone / pyramid (base at y=0, apex at y=height).
func _low_poly_cone(base_r: float, height: float, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var apex := Vector3(0, height, 0)
	var ctr := Vector3(0, height * 0.33, 0)
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := Vector3(cos(a0) * base_r, 0, sin(a0) * base_r)
		var b1 := Vector3(cos(a1) * base_r, 0, sin(a1) * base_r)
		_tri(st, apex, b0, b1, ctr)              # side face
		_tri(st, Vector3.ZERO, b1, b0, ctr)      # base cap
	return st.commit()

# Flat-shaded N-gon frustum (radius r0 at y=0 tapering to r1 at `height`),
# closed by both caps — the laser cone's shell segment.
func _low_poly_frustum(r0: float, r1: float, height: float, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ctr := Vector3(0, height * 0.5, 0)
	var topc := Vector3(0, height, 0)
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := Vector3(cos(a0) * r0, 0, sin(a0) * r0)
		var b1 := Vector3(cos(a1) * r0, 0, sin(a1) * r0)
		var t0 := Vector3(cos(a0) * r1, height, sin(a0) * r1)
		var t1 := Vector3(cos(a1) * r1, height, sin(a1) * r1)
		_tri(st, b0, b1, t1, ctr); _tri(st, b0, t1, t0, ctr)   # side quad
		_tri(st, topc, t0, t1, ctr)                            # top cap
		_tri(st, Vector3.ZERO, b1, b0, ctr)                    # bottom cap
	return st.commit()

# Flat N-gon disc facing up (at local y=0) — the arc horn's throat dish.
func _disc(rad: float, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ctr := Vector3(0, -1.0, 0)
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		_tri(st, Vector3.ZERO, Vector3(cos(a0) * rad, 0, sin(a0) * rad), Vector3(cos(a1) * rad, 0, sin(a1) * rad), ctr)
	return st.commit()

# Closed triangular prism between cross-sections (a0,a1,a2) and (b0,b1,b2) —
# the aim prong (single) and rim fin (arc).
func _tri_prism(a0: Vector3, a1: Vector3, a2: Vector3, b0: Vector3, b1: Vector3, b2: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ctr := (a0 + a1 + a2 + b0 + b1 + b2) / 6.0
	_tri(st, a0, a1, a2, ctr)
	_tri(st, b0, b1, b2, ctr)
	_tri(st, a0, a1, b1, ctr); _tri(st, a0, b1, b0, ctr)
	_tri(st, a1, a2, b2, ctr); _tri(st, a1, b2, b1, ctr)
	_tri(st, a2, a0, b0, ctr); _tri(st, a2, b0, b2, ctr)
	return st.commit()

# Flat-shaded flared horn / bell — a body of revolution opening upward. Rings of
# an N-gon are lofted from `base_r` at the bottom to `rim_r` at the top, with the
# radius following a concave curve (radius grows faster near the top,
# HORN_FLARE_POW), so the wall bows outward like a trumpet bell. `f0`..`f1`
# select the lofted band (0 = base, 1 = mouth) so the dark shell and the hot rim
# lip can be built as separate parts; `bottom_cap` closes the base where it
# meets the plinth. The mouth is always left open (no top cap).
func _low_poly_horn(base_r: float, rim_r: float, height: float, sides: int, segs: int, f0 := 0.0, f1 := 1.0, bottom_cap := true) -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ctr := Vector3(0, height * 0.5, 0)
	for s in range(segs):
		var fa: float = lerpf(f0, f1, float(s) / float(segs))
		var fb: float = lerpf(f0, f1, float(s + 1) / float(segs))
		var y0 := height * fa
		var y1 := height * fb
		var r0: float = base_r + (rim_r - base_r) * pow(fa, HORN_FLARE_POW)
		var r1: float = base_r + (rim_r - base_r) * pow(fb, HORN_FLARE_POW)
		for i in range(sides):
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var p00 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
			var p10 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
			var p01 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
			var p11 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
			_tri(st, p00, p10, p11, ctr); _tri(st, p00, p11, p01, ctr)   # flared side quad
	if bottom_cap:
		# Bottom cap (small octagon) so the base reads solid where it mounts.
		for i in range(sides):
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var b0 := Vector3(cos(a0) * base_r, 0, sin(a0) * base_r)
			var b1 := Vector3(cos(a1) * base_r, 0, sin(a1) * base_r)
			_tri(st, Vector3.ZERO, b1, b0, ctr)
	return st.commit()

# Flat-shaded polyhedral torus lying flat (major ring in XZ), centred at y=0.
# `rings` faces around the main ring, `tube_sides` quads around the tube.
# Wound to face outward so it survives back-face culling.
func _low_poly_torus(inner_r: float, outer_r: float, rings: int, tube_sides: int) -> ArrayMesh:
	var rr := (inner_r + outer_r) * 0.5
	var tt := (outer_r - inner_r) * 0.5
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(rings):
		var u0 := TAU * float(i) / float(rings)
		var u1 := TAU * float(i + 1) / float(rings)
		for j in range(tube_sides):
			var v0 := TAU * float(j) / float(tube_sides)
			var v1 := TAU * float(j + 1) / float(tube_sides)
			var a := _torus_pt(rr, tt, u0, v0)
			var b := _torus_pt(rr, tt, u1, v0)
			var c := _torus_pt(rr, tt, u1, v1)
			var d := _torus_pt(rr, tt, u0, v1)
			var nrm := _torus_nrm((u0 + u1) * 0.5, (v0 + v1) * 0.5)
			for v in [a, d, c, a, c, b]:
				st.set_normal(nrm); st.add_vertex(v)
	return st.commit()

func _torus_pt(rr: float, tt: float, u: float, v: float) -> Vector3:
	return Vector3(cos(u), 0, sin(u)) * (rr + tt * cos(v)) + Vector3(0, tt * sin(v), 0)

func _torus_nrm(u: float, v: float) -> Vector3:
	return Vector3(cos(u) * cos(v), sin(v), sin(u) * cos(v)).normalized()

# Spike pyramids only — the stellation of _low_poly_torus, raised from every
# quad face along its normal by `spike`. Rendered with the hot accent material
# over the plain torus shell so the radial tower's points are what bloom. Each
# pyramid side is oriented outward from that spike's own axis (not the global
# centre), so spikes on the inner rim point inward correctly.
func _torus_spikes(inner_r: float, outer_r: float, rings: int, tube_sides: int, spike: float) -> ArrayMesh:
	var rr := (inner_r + outer_r) * 0.5
	var tt := (outer_r - inner_r) * 0.5
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(rings):
		var u0 := TAU * float(i) / float(rings)
		var u1 := TAU * float(i + 1) / float(rings)
		for j in range(tube_sides):
			var v0 := TAU * float(j) / float(tube_sides)
			var v1 := TAU * float(j + 1) / float(tube_sides)
			var a := _torus_pt(rr, tt, u0, v0)
			var b := _torus_pt(rr, tt, u1, v0)
			var c := _torus_pt(rr, tt, u1, v1)
			var d := _torus_pt(rr, tt, u0, v1)
			var um := (u0 + u1) * 0.5
			var vm := (v0 + v1) * 0.5
			var base_c := _torus_pt(rr, tt, um, vm)
			var apex := base_c + _torus_nrm(um, vm) * spike
			var mid := (base_c + apex) * 0.5    # orient each side face away from the spike axis
			_tri(st, a, b, apex, mid)
			_tri(st, b, c, apex, mid)
			_tri(st, c, d, apex, mid)
			_tri(st, d, a, apex, mid)
	return st.commit()

# ---------------------------------------------------------------- materials & juice
# Dark shell: reads as the tower's colour but idles below the bloom threshold —
# fire flashes and the selection breathe animate its emission energy.
func _make_shell_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = data.color.darkened(0.55)
	m.metallic = 0.15
	m.roughness = 0.55
	m.emission_enabled = true
	m.emission = data.color
	m.emission_energy_multiplier = SHELL_EMISSION
	return m

# Hot accent: crosses the bloom threshold so every tower glows like the buses
# do. Two-sided only for the arc horn, whose rim lip and throat dish are open
# geometry; every other body is closed and culls back faces.
func _make_accent_mat(two_sided: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = data.color.darkened(0.4)
	m.metallic = 0.0
	m.roughness = 0.6
	m.emission_enabled = true
	m.emission = data.color
	m.emission_energy_multiplier = ACCENT_EMISSION
	if two_sided:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

# Shared gunmetal plinth material — never tinted or tweened, so one resource
# serves every tower.
static func _plinth_mat() -> StandardMaterial3D:
	if _plinth_mat_res == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = PLINTH_COLOR
		m.metallic = 0.4
		m.roughness = 0.4
		_plinth_mat_res = m
	return _plinth_mat_res

func _kill_body_tweens() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = null
	_flash_t = -1.0
	_stop_breathe()

func _stop_breathe() -> void:
	if _breathe_tween != null and _breathe_tween.is_valid():
		_breathe_tween.kill()
	_breathe_tween = null

# Muzzle pulse: the shell emission spikes over the bloom threshold and the body
# gets a quick squash-and-recover composed on the upgrade-derived base scale.
# Driven as a manual envelope in _process (no Tween allocation per shot);
# refiring restarts the envelope, matching the old kill-and-restart semantics.
func _fire_flash() -> void:
	if _body == null or not is_instance_valid(_body) or _shell_mat == null:
		return
	_kill_body_tweens()
	_flash_t = 0.0

# Advance the fire-flash envelope: the same curves the old Tween ran — emission
# TRANS_QUAD EASE_OUT from FLASH_EMISSION back to idle over FLASH_GLOW_TIME,
# scale TRANS_BACK EASE_OUT from the squash back to _base_scale over
# FLASH_SCALE_TIME — then the usual idle-glow restore.
func _advance_flash(delta: float) -> void:
	_flash_t += delta
	if _shell_mat != null:
		if _flash_t < FLASH_GLOW_TIME:
			var u: float = _flash_t / FLASH_GLOW_TIME
			_shell_mat.emission_energy_multiplier = FLASH_EMISSION + (SHELL_EMISSION - FLASH_EMISSION) * (u * (2.0 - u))
		else:
			_shell_mat.emission_energy_multiplier = SHELL_EMISSION
	if _body != null and is_instance_valid(_body):
		if _flash_t < FLASH_SCALE_TIME:
			var v: float = _flash_t / FLASH_SCALE_TIME - 1.0
			var k: float = 1.0 + (BACK_OVERSHOOT + 1.0) * v * v * v + BACK_OVERSHOOT * v * v
			var from_scale := _base_scale * FLASH_SCALE_FROM
			_body.scale = from_scale + (_base_scale - from_scale) * k
		else:
			_body.scale = _base_scale
	if _flash_t >= FLASH_GLOW_TIME and _flash_t >= FLASH_SCALE_TIME:
		_flash_t = -1.0
		_restore_idle_glow()

# Upgrade juice: a bigger pop from below final size after the rebuild. Rare
# event, so it keeps the Tween path (_body_pulse).
func _upgrade_pop() -> void:
	_body_pulse(2.5, 0.3, _base_scale * 0.8, 0.25)

func _body_pulse(peak: float, glow_time: float, from_scale: Vector3, scale_time: float) -> void:
	if _body == null or not is_instance_valid(_body) or _shell_mat == null:
		return
	_kill_body_tweens()
	_flash_tween = create_tween()
	_flash_tween.tween_property(_shell_mat, "emission_energy_multiplier", SHELL_EMISSION, glow_time).from(peak).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	_flash_tween.parallel().tween_property(_body, "scale", _base_scale, scale_time).from(from_scale).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_flash_tween.tween_callback(_restore_idle_glow)

func _restore_idle_glow() -> void:
	if _selected:
		_start_breathe()

# Selection highlight on the body itself: rim light + a slow emission breathe
# on the shell, kept below the bloom threshold so it reads "lit", not "firing".
# Called by Main3D alongside set_badges_visible; safe to call repeatedly.
func set_selected(on: bool) -> void:
	_selected = on
	_apply_selection_mat()

func _apply_selection_mat() -> void:
	if _shell_mat == null:
		return
	_shell_mat.rim_enabled = _selected
	if _selected:
		_shell_mat.rim = 0.5
		_shell_mat.rim_tint = 0.2
		# A running pulse (upgrade-pop tween or fire-flash envelope) owns the
		# emission; its finish restarts the breathe.
		if (_flash_tween == null or not _flash_tween.is_running()) and _flash_t < 0.0:
			_start_breathe()
	else:
		_stop_breathe()
		_shell_mat.emission_energy_multiplier = SHELL_EMISSION

func _start_breathe() -> void:
	_stop_breathe()
	_breathe_tween = create_tween().set_loops()
	_breathe_tween.tween_property(_shell_mat, "emission_energy_multiplier", SELECT_BREATHE_HI, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_breathe_tween.tween_property(_shell_mat, "emission_energy_multiplier", SHELL_EMISSION, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

# ---------------------------------------------------------------- laser beam
# Built lazily so non-laser towers stay cheap. Each frame the sheath cylinder
# (and the white-hot core inside it) is stretched and oriented from the cone
# apex to the locked target; glow, thickness and the impact dot ramp with charge.
func _ensure_beam() -> void:
	if _beam != null and is_instance_valid(_beam):
		return
	# UNIT cylinder (radius/height 1): _update_beam drives real thickness and
	# length through the instance basis scale — writing the primitive's
	# radius/height would regenerate the mesh every frame.
	_beam_cyl = CylinderMesh.new()
	_beam_cyl.top_radius = 1.0
	_beam_cyl.bottom_radius = 1.0
	_beam_cyl.height = 1.0
	_beam_cyl.radial_segments = 10
	_beam_cyl.rings = 1
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.albedo_color = data.color
	_beam_mat.emission_enabled = true
	_beam_mat.emission = data.color
	_beam_mat.emission_energy_multiplier = 1.1
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam = MeshInstance3D.new()
	_beam.mesh = _beam_cyl
	_beam.material_override = _beam_mat
	# Beam lives at world scope on the board entities root so its global
	# transform isn't twisted by future tower-local transforms.
	board._entities.add_child(_beam)
	# White-hot core: another unit cylinder, scaled to 35% of the sheath width.
	_beam_core_cyl = CylinderMesh.new()
	_beam_core_cyl.top_radius = 1.0
	_beam_core_cyl.bottom_radius = 1.0
	_beam_core_cyl.height = 1.0
	_beam_core_cyl.radial_segments = 8
	_beam_core_cyl.rings = 1
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(1, 1, 1, 0.95)
	cm.emission_enabled = true
	cm.emission = Color(1, 1, 1)
	cm.emission_energy_multiplier = 3.5
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.render_priority = 1
	_beam_core = MeshInstance3D.new()
	_beam_core.mesh = _beam_core_cyl
	_beam_core.material_override = cm
	board._entities.add_child(_beam_core)
	_beam_impact = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = BEAM_FULL_THICK * 1.8
	sm.height = sm.radius * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	_beam_impact.mesh = sm
	_impact_mat = StandardMaterial3D.new()
	_impact_mat.albedo_color = Color(1, 1, 1, 1)
	_impact_mat.emission_enabled = true
	_impact_mat.emission = data.color
	_impact_mat.emission_energy_multiplier = BEAM_GLOW
	_impact_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_impact.material_override = _impact_mat
	board._entities.add_child(_beam_impact)

func _update_beam(frac: float, on: bool) -> void:
	if not on:
		if _beam != null and is_instance_valid(_beam):
			_beam.visible = false
			_beam_core.visible = false
			_beam_impact.visible = false
		_beam_last_frac = -1.0
		return
	_ensure_beam()
	_beam.visible = true
	_beam_core.visible = true
	_beam_impact.visible = true
	var thick := lerpf(BEAM_BASE_THICK, BEAM_FULL_THICK, frac)
	if frac > 0.8:
		# sizzle: a maxed beam vibrates instead of freezing at full width
		thick *= 1.0 + 0.06 * sin(float(Time.get_ticks_msec()) * 0.04)
	# Material writes only when the charge frac actually changed — they stop
	# once the ramp saturates (the sizzle above is transform-only).
	if frac != _beam_last_frac:
		_beam_last_frac = frac
		var alpha := lerpf(0.35, 0.9, frac)
		_beam_mat.albedo_color = Color(data.color.r, data.color.g, data.color.b, alpha)
		# Glow ramps with the quadratic damage ramp so charge is visible.
		_beam_mat.emission_energy_multiplier = lerpf(1.1, 3.2, frac)
		# The impact tint whitens as the beam charges so full ramp reads white-hot.
		_impact_mat.emission = data.color.lerp(Color(1, 1, 1), frac)
	# Endpoints in world coords. Pull the target's plane pos through an
	# explicit Vector2 first so the Vector3 constructor sees typed floats
	# rather than Variant member accesses on an untyped reference.
	var tpp: Vector2 = _laser_target.pp
	var from := Vector3(pp.x, GameBoard3D.BUS_TOP + _beam_origin_y, pp.y)
	# enemies hover at ENEMY_Y, so aim there (+ a little for body mid-height)
	var to := Vector3(tpp.x, GameBoard3D.ENEMY_Y + BEAM_TARGET_LIFT, tpp.y)
	var dir := to - from
	var dlen := dir.length()
	if dlen < 0.001:
		_beam.visible = false
		_beam_core.visible = false
		_beam_impact.visible = false
		return
	# Orient the unit cylinder's Y axis along `dir` and compose thickness and
	# length into the basis columns (the meshes themselves never change). Build
	# an explicit basis to avoid look_at edge-cases (target directly above the
	# source).
	var y_axis := dir / dlen
	var ref := Vector3.RIGHT if absf(y_axis.y) > 0.99 else Vector3.UP
	var x_axis := y_axis.cross(ref).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	var mid := from + dir * 0.5
	_beam.global_transform = Transform3D(Basis(x_axis * thick, y_axis * dlen, z_axis * thick), mid)
	var core_t := thick * 0.35
	_beam_core.global_transform = Transform3D(Basis(x_axis * core_t, y_axis * dlen, z_axis * core_t), mid)
	_beam_impact.global_transform = Transform3D(Basis(), to)
	# Impact dot: per-frame jitter sells contact sparking.
	var impact_scale: float = lerpf(0.6, 1.4, frac) * randf_range(0.88, 1.14)
	_beam_impact.scale = Vector3(impact_scale, impact_scale, impact_scale)

# Clean up the externally-parented beam nodes when the tower is removed.
func _exit_tree() -> void:
	_set_hum(false, 0.0)
	if _beam != null and is_instance_valid(_beam):
		_beam.queue_free()
	if _beam_core != null and is_instance_valid(_beam_core):
		_beam_core.queue_free()
	if _beam_impact != null and is_instance_valid(_beam_impact):
		_beam_impact.queue_free()

# ---------------------------------------------------------------- ability badges
# Show/hide the tower's ability badge row. Built as real world-space children so
# the camera moves and zooms them natively — no screen-space follow, no per-frame
# repositioning. Called by Main3D on (de)selection; safe to call repeatedly (it
# rebuilds, so it also refreshes after an upgrade changes the tower's flags).
func set_badges_visible(on: bool) -> void:
	_clear_badges()
	if on:
		_build_badges()

func _clear_badges() -> void:
	if _badge_anchor != null and is_instance_valid(_badge_anchor):
		_badge_anchor.queue_free()
	_badge_anchor = null
	_badge_mats.clear()
	_badge_info.clear()
	_badge_cam_seen = false   # fresh badges must get one reveal update even from a still camera

func _build_badges() -> void:
	if data == null:
		return
	# One badge per ability flag that is true; skip any whose textures are missing
	# so the row stays gapless. Display order follows ABILITY_BADGES.
	var built: Array = []
	for entry in ABILITY_BADGES:
		var prop: String = entry["prop"]
		if not bool(data.get(prop)):
			continue
		var mat := _make_badge_material(entry)
		if mat != null:
			built.append({"mat": mat, "tip": str(entry.get("tip", "")), "file": str(entry["file"])})
	if built.is_empty():
		return
	# The anchor hangs off the tower ROOT (never scaled — only `_body` is), so it
	# never inherits the tower's height/width scale. Its world scale is fixed once;
	# the parallax shader only reads zoom_t each frame, so the badges never swim.
	_badge_anchor = Node3D.new()
	_badge_anchor.position = Vector3(0.0, 4.0, GameBoard3D.TOWER_RADIUS * 1.4)
	_badge_anchor.scale = Vector3.ONE * badge_world_scale
	add_child(_badge_anchor)
	var n := built.size()
	var spacing := BADGE_BASE_WORLD * 1.15
	var start_x := -spacing * float(n - 1) * 0.5
	for i in range(n):
		var b: Dictionary = built[i]
		var mat: ShaderMaterial = b["mat"]
		var mesh := QuadMesh.new()
		mesh.size = Vector2(BADGE_BASE_WORLD, BADGE_BASE_WORLD)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.position = Vector3(start_x + spacing * float(i), 0.0, 0.0)
		_badge_anchor.add_child(mi)
		_badge_mats.append(mat)
		_badge_info.append({"mi": mi, "tip": str(b["tip"]), "file": str(b["file"])})

# Build the parallax material for one icon (null if any of its 3 layers is absent).
func _make_badge_material(entry: Dictionary) -> ShaderMaterial:
	var base: String = entry["file"]
	var glyph := _badge_texture(base + "_glyph")
	var backplate := _badge_texture(base + "_backplate")
	var rim := _badge_texture(base + "_rim")
	if glyph == null or backplate == null or rim == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = _badge_shader()
	mat.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX   # draw on top of all other transparent geometry
	mat.set_shader_parameter("glyph_tex", glyph)
	mat.set_shader_parameter("backplate_tex", backplate)
	mat.set_shader_parameter("rim_tex", rim)
	mat.set_shader_parameter("focal_out", Vector2(float(entry["focal_out_x"]), float(entry["focal_out_y"])))
	mat.set_shader_parameter("focal_in", Vector2(float(entry["focal_in_x"]), float(entry["focal_in_y"])))
	mat.set_shader_parameter("reveal_out", float(entry["reveal_out"]))
	mat.set_shader_parameter("reveal_in", float(entry["reveal_in"]))
	mat.set_shader_parameter("reveal_rate", float(entry["reveal_rate"]))
	mat.set_shader_parameter("zoom_t", 0.0)
	mat.set_shader_parameter("focal_t", 0.0)
	return mat

# Drive the parallax: set zoom_t (0 far .. 1 near) on every live badge material.
# This is the only per-frame badge work and touches no transform, so nothing swims.
func _update_badge_zoom() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# The reveal scalars only depend on the camera, and the badges never move —
	# skip the shader writes while the camera transform is unchanged.
	var cam_tf := cam.global_transform
	if _badge_cam_seen and cam_tf == _badge_cam_tf:
		return
	_badge_cam_tf = cam_tf
	_badge_cam_seen = true
	var d: float = cam.global_position.distance_to(_badge_anchor.global_position)
	var span: float = maxf(0.001, cam_dist_far - cam_dist_near)
	var t: float = clampf((cam_dist_far - d) / span, 0.0, 1.0)
	# Focal centers on a closer ramp (done by focal_center_dist) so it is settled
	# before the width finishes opening, per the reveal-distance targets.
	var fspan: float = maxf(0.001, cam_dist_far - focal_center_dist)
	var ft: float = clampf((cam_dist_far - d) / fspan, 0.0, 1.0)
	for m in _badge_mats:
		m.set_shader_parameter("zoom_t", t)
		m.set_shader_parameter("focal_t", ft)

# Which badge is under `screen_pos` (camera-projected): returns {tip, file} for the
# hovered badge, or {} if none. The badges are billboarded quads, so the world
# half-width along the camera's right axis projects to the on-screen hit radius.
func badge_tip_at(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	if _badge_anchor == null or camera == null:
		return {}
	var half: float = BADGE_BASE_WORLD * 0.5 * badge_world_scale
	var right: Vector3 = camera.global_transform.basis.x
	for info in _badge_info:
		var mi: MeshInstance3D = info["mi"]
		if not is_instance_valid(mi):
			continue
		var c: Vector3 = mi.global_position
		if camera.is_position_behind(c):
			continue
		var center: Vector2 = camera.unproject_position(c)
		var edge: Vector2 = camera.unproject_position(c + right * half)
		var r: float = maxf(8.0, center.distance_to(edge))
		if screen_pos.distance_to(center) <= r:
			return {"tip": str(info["tip"]), "file": str(info["file"])}
	return {}

# Shared parallax shader, compiled once.
static func _badge_shader() -> Shader:
	if _badge_shader_res != null:
		return _badge_shader_res
	var sh := Shader.new()
	sh.code = _BADGE_SHADER
	_badge_shader_res = sh
	return _badge_shader_res

# Cached texture lookup: art/<file>.png (then .webp). Misses (null) are cached too
# so a not-yet-added layer isn't re-probed.
static func _badge_texture(file: String) -> Texture2D:
	if _badge_tex.has(file):
		return _badge_tex[file]
	var tex: Texture2D = null
	for ext in [".png", ".webp"]:
		var path := "res://art/%s%s%s" % [ArtPaths.dir(file), file, ext]
		if ResourceLoader.exists(path):
			tex = load(path)
			break
	_badge_tex[file] = tex
	return tex
