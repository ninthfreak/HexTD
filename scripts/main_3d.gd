class_name Main3D
extends Node3D
## 3D sandbox scene. Same game loop as the 2D Main — sandbox controls,
## drag-to-place towers, wave/spawn helpers — but with a 3D camera, directional
## light, sky environment and a raycast-to-ground click model. A selected tower's
## ability badges are real world-space children of the tower (built in Tower3D),
## so they ride the camera natively; Main3D just toggles them on selection.

# --- tunable game state ---
var money := 200
var lives := 100
var waves: Array = []
var default_gap := 0.7
var cheat_amount := 500

# Money-cheat hold-to-repeat: a tap grants one award; holding waits, then fires
# repeatedly with the interval ramping from slow to fast the longer it's held.
const CHEAT_REPEAT_DELAY := 0.45    # hold this long before auto-repeat kicks in
const CHEAT_INTERVAL_START := 0.32  # first repeat gap (slow)
const CHEAT_INTERVAL_MIN := 0.04    # fastest repeat gap (held a while)
const CHEAT_RAMP_TIME := 2.5        # seconds of repeating to reach top speed
var _cheat_held := false
var _cheat_hold_time := 0.0
var _cheat_next := 0.0

# --- nodes ---
var board: GameBoard3D
var content: GameContent
var map: HexMapData
var overlay: BoardOverlay3D
var cam_pivot: Node3D
var camera: Camera3D
var directional_light: DirectionalLight3D
var world_env: WorldEnvironment

# --- placement / selection ---
var placing_id := ""
var dragging := false
var has_selected := false
var selected_cell := Vector2i.ZERO

# --- camera control ---
var pane_width := 300
var panning := false
var cam_pitch := deg_to_rad(58.0)        # angle above horizon; 90° = straight down
var cam_yaw := 0.0                       # rotation around world Y
var cam_distance := 400.0
var min_distance := 120.0
var max_distance := 1600.0
var pan_speed := 600.0
var _target_distance := 400.0            # wheel writes here; _process eases toward it
var _zoom_anchor := Vector2.ZERO         # plane point to keep under the cursor while zooming
var _zoom_anchor_screen := Vector2.ZERO
var _zoom_anchor_active := false
var _zoom_last_ms := 0                   # wall-clock easing (survives time_scale 0)

# --- mode ---
# "game" plays the waves in order with a manual break between each (no cheats,
# no free spawning, no camera readout); "sandbox" exposes the full toolbox.
var is_game := false
var is_tutorial := false
var game_over := false
var game_wave_index := 0          # next wave to start in game mode (0-based)

# --- speed / pause ---
const BAR_ICON_PX := 100         # pause / speed hex button size
const WAVE_ICON_PX := 150        # wave hex button — 50% larger than the others
const TOWER_HEX_PX := 96         # hex build-button size
const ICON_BTN_PX := 64          # height of the graphic-only sound/spawn/cheat hex buttons
const TOOLTIP_BG := Color(0.02, 0.03, 0.05, 0.97)   # dark tooltip background (readability)
const STAT_ICON_PX := 60         # money / lives glyph size in the top-left overlay
# Wave-number tints, matched to the SVG art strokes.
const WAVE_START_COL := Color(0.647, 0.455, 1.0)   # #a574ff  (wave_start)
const WAVE_RUN_COL := Color(0.604, 0.643, 0.706)   # #9aa4b4  (wave_inprogress)
const WAVE_DONE_COL := Color(0.5, 0.85, 0.55)
# One economy color rule everywhere ¤ appears: gold = affordable/positive,
# red = can't afford, green = refund/done.
const GOLD_COL := Color(1.0, 0.82, 0.25)
const COST_RED_COL := Color(1.0, 0.42, 0.42)
const LOCKED_COL := Color(0.75, 0.5, 0.5, 0.8)
var speed_steps := [1.0, 2.0, 3.0]
var speed_index := 0
var paused := false

# --- wave runtime (absolute-timeline) ---
var _spawn_timeline: Array = []   # sorted {time, type} from WaveLoader.build_timeline
var _wave_clock := 0.0
var _wave_running := false
var _wave_awaiting_clear := false

const WAVE_CLEAR_BONUS := 100

# --- wave-name banner (pops up + fades out when a wave starts) ---
var banner_label: Label
var _banner_time := 0.0            # real-time seconds remaining (in + hold + fade)
const BANNER_IN := 0.25           # pop-in seconds (scale settle + fade-in)
const BANNER_HOLD := 1.4          # fully-opaque seconds
const BANNER_FADE := 1.2          # fade-out seconds
var defeat_dim: ColorRect          # dark wash behind the defeat banner
var defeat_sub_label: Label
var _defeat_ms := 0                # wall-clock stamp of the defeat (time_scale is 0 then)

# --- UI ---
var money_label: Label
var lives_label: Label
var cam_label: Label                 # camera readout, right of the lives line
var wave_select: OptionButton
var enemy_select: OptionButton
var spawn_count: SpinBox
var spawn_button: TextureButton      # icon flips singular/plural with the count
var _enemy_ids: Array = []
var speed_button: TextureButton      # the graphic itself is the button (no chrome)
var pause_button: TextureButton
var wave_button: TextureButton       # honeycomb centre: starts the next wave
var wave_num_label: Label            # next/current wave number drawn in the hex middle
var sound_button: TextureButton
var sound_on := true
var target_button: TextureButton
var facing_button: TextureButton
var _tower_control_row: HBoxContainer
var upgrade_buttons: Array = []
var _tower_buttons: Array = []       # HexTowerButton list (cost-affordability refresh)
var sell_button: Button
var crosspath_hint: Label            # one-line reason shown while a path is crosspath-locked
var info_label: Label

# --- ability badges ---
# A selected tower's ability icons are real world-space children of the tower
# (built in Tower3D); Main3D only toggles them as the selection changes, and shows
# a hover tooltip (screen-space) for whichever badge the cursor is over.
var _badged_tower = null
var badge_tip_layer: CanvasLayer
var badge_tip_panel: PanelContainer
var badge_tip_label: Label
var badge_tip_glyph: TextureRect      # full-glyph preview (right of the text)
var _tip_file := ""                   # icon currently shown in the preview (skip redundant reloads)
var _art_cache := {}                  # art file base -> Texture2D

# --- per-frame UI dirty state ---
# Mass kills/leaks arrive dozens per frame; the bounty/leak handlers only
# accumulate here and _flush_hud folds them into one label update + one pulse.
var _hud_dirty := false
var _money_pulse_pending := false
var _lives_pulse_pending := false
# Label pulses decay manually off the wall clock: Tweens run on scaled time (so
# pulses froze at time_scale 0) and per-kill Tween kill/create churned.
var _label_pulses := {}               # Label -> {"color": Color, "t": float 1→0}
var _pulse_last_ms := 0
# The remaining UI refreshers run every frame but their outputs rarely change;
# each caches the state key its widgets currently show and skips a re-apply
# (add_theme_color_override & co. dirty + repaint even for identical values).
var _ui_was_idle := false             # last frame had no placement and no selection
var _upgrade_rev := 0                 # bumped on upgrade/sell/selection change
var _btn_key: Array = []              # (tower id, money, rev) the upgrade/sell buttons show
var _wave_btn_key: Array = []
var _pause_btn_key: Array = []
var _cam_readout_key: Array = []
var _tip_probe_key: Array = []        # (mouse, cam, tower id, rev) of the last badge probe

func _ready() -> void:
	Engine.time_scale = 1.0
	is_game = GameState.mode == "game" or GameState.mode == "tutorial"
	is_tutorial = GameState.mode == "tutorial"
	lives = 100 if is_game else 99999
	content = GameContent.new()
	map = Levels.get_by_path(GameState.selected_path)

	var wc := WaveLoader.load_waves()
	waves = wc.get("waves", [])
	default_gap = float(wc.get("spawn_interval_default", 0.7))

	board = GameBoard3D.new()
	add_child(board)
	board.setup(map)

	overlay = BoardOverlay3D.new()
	overlay.board = board
	board.add_child(overlay)

	_build_environment()
	_build_camera()
	_frame_camera()
	_build_ui()
	_build_map_title()
	_build_stats_overlay()
	_build_wave_banner()
	_build_badge_tooltip()
	_update_labels()
	if is_game:
		_set_info("Build towers, then start each wave when you're ready.")

# ---------------------------------------------------------------- environment & camera
# A directional sun + a procedural sky. The shiny bus / clearcoat-mask
# materials need an environment to reflect; the sky gives them something rich
# to mirror without committing to a baked HDRI.
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var psm := ProceduralSkyMaterial.new()
	# A dark night sky: the neon emission and reflections are the show, not the
	# sky. Faint cool gradient so towers/walls still pick up a little form light.
	psm.sky_top_color = Color(0.015, 0.02, 0.04)
	psm.sky_horizon_color = Color(0.03, 0.05, 0.09)
	psm.ground_bottom_color = Color(0.01, 0.01, 0.02)
	psm.ground_horizon_color = Color(0.02, 0.03, 0.05)
	psm.sun_angle_max = 5.0
	psm.sun_curve = 0.08
	sky.sky_material = psm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# SSAO: subtle contact darkening for depth. Kept LOW — a strong/wide AO threw
	# a dark halo into the plateau around the path that muddied the neon border.
	env.ssao_enabled = true
	env.ssao_radius = 2.5
	env.ssao_intensity = 0.9
	env.ssao_power = 2.0
	# SSR: the dark glossy substrate mirrors the neon buses, enemies and towers
	# — the wet-floor-under-neon look. This is where the reflections finally read.
	env.ssr_enabled = true
	env.ssr_max_steps = 96
	env.ssr_fade_in = 0.1
	env.ssr_fade_out = 6.0
	# HDR glow blooms every emissive surface (buses, markers, enemies, lasers,
	# projectiles). Additive blend: softlight only tints, additive actually
	# spills light over the near-black floor — the neon-on-wet-asphalt look the
	# materials are tuned for. Wider levels for a broader halo.
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_intensity = 0.55
	env.glow_bloom = 0.1
	env.glow_hdr_threshold = 0.95
	env.set_glow_level(4, true)
	env.set_glow_level(6, true)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	# Raised white point keeps emissive cores saturated (default 1.0 hard-clips
	# energy 2-3 emitters to white, turning the cyan rim white-with-fringe).
	env.tonemap_white = 6.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	env.adjustment_contrast = 1.03
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	directional_light = DirectionalLight3D.new()
	directional_light.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(35.0), 0.0)
	# Dim, cool key light: just enough to give the dark floor, walls and towers
	# some form. The neon emission carries the scene; a bright sun would wash the
	# darkness out and kill the glow/reflection read.
	directional_light.light_energy = 0.55
	directional_light.light_color = Color(0.7, 0.8, 1.0)
	directional_light.shadow_enabled = true
	# The default shadow range (100, measured from the camera) ends far short of
	# the ~400+ orbit distance, which silently disabled every shadow. One
	# orthogonal split is ideal for a single board-sized scene.
	directional_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	directional_light.directional_shadow_max_distance = 2000.0
	directional_light.shadow_blur = 1.5
	directional_light.light_angular_distance = 1.0
	add_child(directional_light)

	# Shadowless purple fill from the opposite yaw: lifts the dead-black faces
	# away from the key light and color-separates lit vs shadowed sides (blue
	# key / purple fill), without brightening the floor.
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(35.0 + 180.0), 0.0)
	fill.light_energy = 0.18
	fill.light_color = Color(0.5, 0.42, 0.85)
	fill.shadow_enabled = false
	add_child(fill)

	# SSR misses wherever the reflected ray leaves the screen; a once-baked box
	# probe of the neon board becomes the fallback so the mirror floor never
	# snaps to reflecting the black sky.
	var b: Rect2 = board.get_bounds()
	var probe := ReflectionProbe.new()
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.size = Vector3(b.size.x + 200.0, 120.0, b.size.y + 200.0)
	probe.position = Vector3(b.position.x + b.size.x * 0.5, 30.0, b.position.y + b.size.y * 0.5)
	probe.box_projection = true
	add_child(probe)

	# A vast near-black semi-gloss ground plane under the slab: catches faint
	# reflections of the board so the perimeter doesn't read as a cardboard
	# cutout floating in the void.
	var ground := MeshInstance3D.new()
	var gm := PlaneMesh.new()
	gm.size = Vector2(8000.0, 8000.0)
	ground.mesh = gm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.008, 0.010, 0.014)
	gmat.metallic = 0.85
	gmat.roughness = 0.3
	ground.material_override = gmat
	ground.position = Vector3(b.position.x + b.size.x * 0.5, GameBoard3D.BUILD_BOTTOM - 2.0, b.position.y + b.size.y * 0.5)
	add_child(ground)

func _build_camera() -> void:
	cam_pivot = Node3D.new()
	add_child(cam_pivot)
	camera = Camera3D.new()
	camera.fov = 38.0
	# Nothing ever gets closer than min_distance minus the board height, so a
	# generous near plane reclaims depth precision for the thin coplanar layers
	# on the slab (inlay / markers / ribbon).
	camera.near = 4.0
	camera.far = 4000.0
	add_child(camera)
	_update_camera_transform()
	camera.current = true

# Place the camera at `cam_distance` from `cam_pivot` along a (pitch, yaw)
# spherical offset; orient it to look at the pivot. Used by pan/zoom/yaw.
func _update_camera_transform() -> void:
	var p := cam_pivot.position
	var cz := cos(cam_yaw) * cos(cam_pitch)
	var cx := sin(cam_yaw) * cos(cam_pitch)
	var cy := sin(cam_pitch)
	var offset := Vector3(cx, cy, cz) * cam_distance
	camera.position = p + offset
	camera.look_at(p, Vector3.UP)

# Frame the board: drop the focus on the center of the play area, and pick a
# distance that fits both axes (a coarse projection of the board's bounding
# rectangle into screen space). Pulled apart from the 2D zoom math: a 3D camera
# doesn't have a `zoom` Vector2; we move it further/closer instead.
func _frame_camera() -> void:
	var b: Rect2 = board.get_bounds()
	var center := b.position + b.size * 0.5
	cam_pivot.position = Vector3(center.x, 0, center.y)
	# Account for the right-side UI pane: the playable region is a fraction of
	# the viewport, so the camera needs more headroom to fit the board.
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var play_w: float = maxf(1.0, vp.x - float(pane_width))
	var play_h: float = maxf(1.0, vp.y)
	var play_aspect: float = play_w / play_h
	var fov_v: float = deg_to_rad(camera.fov)
	var board_half_w: float = b.size.x * 0.5 + 60.0
	var board_half_h: float = b.size.y * 0.5 + 60.0
	# Vertical fit: the board lies at the focus depth. tan(fov/2)*d = half-extent
	var d_v: float = (board_half_h * cos(cam_pitch) + 1.0) / tan(fov_v * 0.5)
	var fov_h: float = atan(tan(fov_v * 0.5) * play_aspect) * 2.0
	var d_h: float = board_half_w / tan(fov_h * 0.5)
	cam_distance = clampf(maxf(d_v, d_h), min_distance, max_distance)
	_target_distance = cam_distance
	# Nudge the focus toward screen-left so the board centers in the playable
	# region rather than under the right-side panel.
	var shift: float = (float(pane_width) * 0.5) / play_w * board_half_w
	cam_pivot.position.x = center.x - shift
	_update_camera_transform()

# ---------------------------------------------------------------- per-frame
func _process(delta: float) -> void:
	if _wave_running:
		_wave_clock += delta
		while not _spawn_timeline.is_empty():
			var entry: Dictionary = _spawn_timeline[0]
			if entry["time"] > _wave_clock:
				break
			_spawn_timeline.pop_front()
			_spawn_enemy(entry["type"])
		if _spawn_timeline.is_empty():
			_wave_running = false
			_wave_awaiting_clear = true
	if _wave_awaiting_clear and board.enemies.is_empty():
		_wave_awaiting_clear = false
		if not game_over:
			money += WAVE_CLEAR_BONUS
			_update_labels()
			_pulse_label(money_label, Color(1.5, 1.3, 0.6))
			if is_game and game_wave_index >= waves.size():
				# That was the last wave — the run is won.
				_play_sfx("victory")
				_show_wave_banner("SYSTEM CLEAR")
				_set_info("All waves cleared!", "success")
			else:
				_play_sfx("wave_clear")
				_set_info("Wave cleared — +%d bonus." % WAVE_CLEAR_BONUS, "success")
	_flush_hud()
	_decay_pulses()
	_update_pause_button()
	_update_wave_button()
	_update_banner(delta)
	_ease_zoom(delta)
	_camera_keys(delta)
	_update_preview()
	_update_cam_readout()
	_cheat_tick(delta)

# Apply the frame's accumulated bounty/leak changes in one pass: one label
# update, one affordability sweep, at most one pulse per label.
func _flush_hud() -> void:
	if not _hud_dirty:
		return
	_hud_dirty = false
	_update_labels()
	if _money_pulse_pending:
		_money_pulse_pending = false
		_pulse_label(money_label, Color(1.5, 1.3, 0.6))
	if _lives_pulse_pending:
		_lives_pulse_pending = false
		_pulse_label(lives_label, Color(1.6, 0.5, 0.5))

# Live camera readout: orbit distance (the zoom metric) plus the camera's world
# position, so it's clear where the camera sits at any zoom/pan.
func _update_cam_readout() -> void:
	if cam_label == null or camera == null:
		return
	var p: Vector3 = camera.global_position
	var key: Array = [int(round(cam_distance)), int(round(p.x)), int(round(p.y)), int(round(p.z))]
	if key == _cam_readout_key:
		return
	_cam_readout_key = key
	cam_label.text = "cam d:%d  (%d, %d, %d)" % key

func _camera_keys(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir != Vector2.ZERO:
		var dt := delta / maxf(Engine.time_scale, 0.0001)
		var d2: Vector2 = dir.normalized() * pan_speed * dt
		_pan_plane(d2)

# Move the focus point in plane coords (XZ). Keeps yaw fixed so panning
# follows the cardinal directions the player sees.
func _pan_plane(d: Vector2) -> void:
	# yaw rotates the world; the screen-space (x, y) input maps through it.
	var c := cos(cam_yaw)
	var s := sin(cam_yaw)
	var dx: float = d.x * c - d.y * s
	var dz: float = d.x * s + d.y * c
	cam_pivot.position += Vector3(dx, 0, dz)
	_update_camera_transform()

func _update_preview() -> void:
	# Idle steady state (nothing being placed or selected): the transition frame
	# below already cleared the overlay, badges, control row and buttons, so
	# repeating the sweeps would be pure redundancy.
	var idle := placing_id == "" and not has_selected
	if idle and _ui_was_idle:
		return
	_ui_was_idle = idle
	if placing_id == "" or _mouse_over_pane():
		overlay.preview_active = false
	else:
		var cell := board.world_cell(_mouse_to_plane())
		if board.has_cell(cell):
			var td := content.tower(placing_id)
			overlay.preview_active = true
			overlay.preview_cell = cell
			overlay.preview_range = board.tower_reach(td.range_tiles)
			overlay.preview_valid = board.is_buildable(cell) and money >= td.cost
			overlay.preview_color = td.color
			overlay.preview_mode = td.fire_mode
			overlay.preview_dirs = td.directions
			overlay.preview_ignore_walls = td.ignore_walls
		else:
			overlay.preview_active = false
	overlay.selected_active = has_selected
	overlay.selected_cell = selected_cell
	var sel_t = board.tower_at(selected_cell) if has_selected else null
	overlay.selected_range = (board.tower_reach(sel_t.data.range_tiles) if sel_t != null else 0)
	if sel_t != null:
		overlay.selected_color = sel_t.data.color
		overlay.selected_ignore_walls = sel_t.data.ignore_walls
		overlay.selected_rotated = sel_t.range_rotated
	overlay.refresh()
	_set_badged_tower(sel_t)
	_update_badge_tooltip()
	_update_tower_control_row(sel_t)
	_update_target_button(sel_t)
	_update_tower_buttons(sel_t)

# Cast a ray from the cursor through the camera onto the y=0 plane and
# return the intersection as plane coords. This is the 3D counterpart of
# `get_global_mouse_position()` from the 2D scene.
func _mouse_to_plane() -> Vector2:
	return _plane_at_screen(get_viewport().get_mouse_position())

func _plane_at_screen(mp: Vector2) -> Vector2:
	if camera == null:
		return Vector2.ZERO
	var from := camera.project_ray_origin(mp)
	var dir := camera.project_ray_normal(mp)
	if absf(dir.y) < 0.00001:
		return Vector2.ZERO
	# Intersect with y = BUS_TOP (where towers sit / cells are addressed).
	var t: float = (GameBoard3D.BUS_TOP - from.y) / dir.y
	if t < 0.0:
		return Vector2.ZERO
	var w := from + dir * t
	return Vector2(w.x, w.z)

func _priority_art(p: String) -> String:
	match p:
		"last":
			return "focus_last"
		"strongest":
			return "focus_strong"
		"weakest":
			return "focus_weak"
		_:
			return "focus_first"

func _priority_label(p: String) -> String:
	match p:
		"last":
			return "Last"
		"strongest":
			return "Strongest"
		"weakest":
			return "Weakest"
		_:
			return "First"

# The selected tower can be passed in by _update_preview (which already looked
# it up); a null/omitted arg falls back to the lookup, matching the old behavior
# (a stale selection also resolves to null either way).
func _update_target_button(sel_t = null) -> void:
	var t = sel_t if sel_t != null else (board.tower_at(selected_cell) if has_selected else null)
	if t != null:
		target_button.texture_normal = _load_art(_priority_art(t.target_priority))
		target_button.tooltip_text = "Target: %s (tap to cycle)." % _priority_label(t.target_priority)

func _on_target_pressed() -> void:
	if not has_selected:
		return
	var t = board.tower_at(selected_cell)
	if t == null:
		return
	var p: String = t.cycle_target_priority()
	_update_target_button()
	_set_info("%s now targets: %s." % [t.data.display_name, _priority_label(p)])

func _update_tower_control_row(sel_t = null) -> void:
	var t = sel_t if sel_t != null else (board.tower_at(selected_cell) if has_selected else null)
	_tower_control_row.visible = t != null

func _on_facing_pressed() -> void:
	if not has_selected:
		return
	var t = board.tower_at(selected_cell)
	if t == null:
		return
	var rotated: bool = t.toggle_range_rotation()
	var shape: String = "rotated" if rotated else "standard"
	_set_info("%s range shape: %s." % [t.data.display_name, shape])

# Upgrade/sell buttons carry a CostLabel overlay so the small ¤ glyph can be drawn
# larger than the surrounding text and still sit aligned with the digits.
func _attach_cost_label(btn: Button) -> void:
	var cl := CostLabel.new()
	cl.set_anchors_preset(Control.PRESET_FULL_RECT)
	cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(cl)
	btn.set_meta("cl", cl)

func btn_cl(btn: Button) -> CostLabel:
	return btn.get_meta("cl") as CostLabel

func _update_tower_buttons(sel_t = null) -> void:
	var t = sel_t if sel_t != null else (board.tower_at(selected_cell) if has_selected else null)
	# Everything below is a pure function of (tower, its tiers, money); the tiers
	# only move through _upgrade_rev bumps, so an unchanged key means the buttons
	# already show exactly this state.
	var key: Array = [t.get_instance_id() if t != null else 0, money, _upgrade_rev]
	if key == _btn_key:
		return
	_btn_key = key
	var any_locked := false
	for s in range(upgrade_buttons.size()):
		var b: Button = upgrade_buttons[s]
		if t == null or s >= t.slot_count():
			b.visible = false
			continue
		b.visible = true
		# Every state leads with "Name lvl/max" so the purchased tiers stay
		# readable even on locked/maxed paths (a locked path at tier 2 must not
		# look like a locked path at tier 0).
		var lvl: int = t.slot_level(s)
		var cap: int = t.slot_max(s)
		if t.can_upgrade(s):
			var c: int = t.next_cost(s)
			b.disabled = money < c
			var afford := money >= c
			(btn_cl(b)).set_cost("%s %d/%d → %d  (" % [t.slot_name(s), lvl, cap, lvl + 1], c, ")", not afford, GOLD_COL if afford else COST_RED_COL)
			b.tooltip_text = t.tier_summary(s)
		elif t.has_next_tier(s):
			# Has a tier left, but the BTD6 crosspath rule forbids buying it now.
			b.disabled = true
			any_locked = true
			(btn_cl(b)).set_plain("%s %d/%d — locked" % [t.slot_name(s), lvl, cap], false, LOCKED_COL)
			b.tooltip_text = "Crosspath limit: at most two paths upgraded, and only one above tier 2."
		else:
			b.disabled = true
			(btn_cl(b)).set_plain("%s %d/%d — max" % [t.slot_name(s), lvl, cap], false, WAVE_DONE_COL)
			b.tooltip_text = "Fully upgraded"
	if crosspath_hint != null:
		crosspath_hint.visible = any_locked
	if t == null:
		sell_button.visible = false
	else:
		sell_button.visible = true
		sell_button.disabled = false
		(btn_cl(sell_button)).set_cost("Sell  (+", t.sell_value(), ")", false, WAVE_DONE_COL)
		sell_button.tooltip_text = "Refund %d%% of everything spent on this tower." % t.refund_percent()

func _on_upgrade_pressed(s: int) -> void:
	if not has_selected:
		return
	var t = board.tower_at(selected_cell)
	if t == null or not t.can_upgrade(s):
		return
	var c: int = t.next_cost(s)
	if money < c:
		_set_info("Not enough money to upgrade (need %d)." % c, "error")
		return
	money -= c
	t.upgrade(s)
	_upgrade_rev += 1
	# A new tier can flip an ability flag, so rebuild the badge row.
	if t == _badged_tower:
		t.set_badges_visible(true)
	_update_labels()
	_update_tower_buttons(t)
	_set_info("%s: %s now at tier %d." % [t.data.display_name, t.slot_name(s), t.slot_level(s)])
	_play_sfx("upgrade")

func _on_sell_pressed() -> void:
	if not has_selected:
		return
	var t = board.tower_at(selected_cell)
	if t == null:
		return
	var refund: int = t.sell_value()
	var nm: String = t.data.display_name
	board.remove_tower(t.cell)
	overlay.occupancy_rev += 1
	_upgrade_rev += 1
	money += refund
	has_selected = false
	_update_labels()
	_update_tower_buttons()
	_update_tower_control_row()
	_update_target_button()
	_set_info("Sold %s for %d." % [nm, refund], "success")
	_play_sfx("sell")

# ---------------------------------------------------------------- input
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			panning = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_by(1.0 / 1.1)   # wheel up -> closer
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_by(1.1)         # wheel down -> further
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and dragging:
			_finish_drag()
	elif event is InputEventMouseMotion and panning:
		# Translate pixel delta into world delta at the focus plane. The
		# vertical extent at distance D with FOV α is `2 D tan(α/2)`, so one
		# pixel ≈ that / viewport_height world units.
		var vp: Vector2 = get_viewport().get_visible_rect().size
		var world_per_pixel: float = (2.0 * cam_distance * tan(deg_to_rad(camera.fov) * 0.5)) / maxf(1.0, vp.y)
		var d: Vector2 = -event.relative * world_per_pixel
		# Account for the camera pitch when projecting screen-Y into plane-Z.
		_pan_plane(Vector2(d.x, d.y / maxf(sin(cam_pitch), 0.2)))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_cancel()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _mouse_over_pane():
			return
		_on_board_left_press()

func _on_board_left_press() -> void:
	var cell := board.world_cell(_mouse_to_plane())
	if not board.has_cell(cell):
		return
	if placing_id != "":
		_try_place(cell)
	else:
		var t = board.tower_at(cell)
		if t != null:
			_select_tower(cell, t)
		else:
			has_selected = false

func _finish_drag() -> void:
	dragging = false
	var cell := board.world_cell(_mouse_to_plane())
	if not _mouse_over_pane() and board.has_cell(cell) and board.is_buildable(cell):
		if _try_place(cell):
			placing_id = ""

# Wheel zoom only retargets; _ease_zoom in _process glides the camera there.
# The plane point under the cursor at wheel time is pinned so the zoom dives
# toward (or backs away from) what the player is pointing at.
func _zoom_by(factor: float) -> void:
	_target_distance = clampf(_target_distance * factor, min_distance, max_distance)
	if not _mouse_over_pane():
		_zoom_anchor_screen = get_viewport().get_mouse_position()
		_zoom_anchor = _plane_at_screen(_zoom_anchor_screen)
		_zoom_anchor_active = true

func _ease_zoom(_delta: float) -> void:
	# Wall-clock easing: _process delta is zeroed while paused (time_scale 0),
	# but the camera should still glide then.
	var now := Time.get_ticks_msec()
	var dt := clampf(float(now - _zoom_last_ms) / 1000.0, 0.0, 0.1)
	_zoom_last_ms = now
	if absf(cam_distance - _target_distance) < 0.05:
		_zoom_anchor_active = false
		return
	cam_distance = lerpf(cam_distance, _target_distance, 1.0 - exp(-12.0 * dt))
	if absf(cam_distance - _target_distance) < 0.05:
		cam_distance = _target_distance
	_update_camera_transform()
	if _zoom_anchor_active:
		# Re-project the stored screen point and shift focus so the anchored
		# plane point stays put under it.
		var hit := _plane_at_screen(_zoom_anchor_screen)
		var d := _zoom_anchor - hit
		cam_pivot.position += Vector3(d.x, 0, d.y)
		_update_camera_transform()

# ---------------------------------------------------------------- placement
func _try_place(cell: Vector2i) -> bool:
	if not board.is_buildable(cell):
		_set_info("Can't build there.", "error")
		return false
	var td := content.tower(placing_id)
	if money < td.cost:
		_set_info("Not enough money (need %d)." % td.cost, "error")
		return false
	money -= td.cost
	var t := Tower3D.new()
	t.cell = cell
	t.setup(td, board, board.cell_center_world(cell))
	board.place_tower(cell, t)
	overlay.occupancy_rev += 1
	_update_labels()
	_play_sfx("build_place")
	return true

func _select_tower(cell: Vector2i, t) -> void:
	has_selected = true
	selected_cell = t.cell
	_upgrade_rev += 1
	_set_info("%s selected — range shown." % t.data.display_name)

func _cancel() -> void:
	placing_id = ""
	dragging = false
	has_selected = false

# ---------------------------------------------------------------- waves
func _on_spawn_pressed() -> void:
	if _enemy_ids.is_empty():
		return
	var idx: int = clampi(enemy_select.selected, 0, _enemy_ids.size() - 1)
	var type_id := str(_enemy_ids[idx])
	var ed := content.enemy(type_id)
	if ed == null:
		return
	var points := board.get_path_points()
	if points.size() < 1:
		return
	var n: int = int(spawn_count.value)
	var spacing: float = _enemy_radius(ed) * 2.0 + 8.0
	for k in range(n):
		var place := _forward_along(points, spacing * float(k))
		var e := Enemy3D.new()
		e.bounty.connect(_on_enemy_bounty)
		e.reached_goal.connect(_on_enemy_reached_goal)
		e.split.connect(_on_enemy_split)
		e.setup(ed, points)
		e.place_on_path(int(place["index"]), place["pos"])
		board.add_enemy(e)
	_set_info("Spawned %d %s." % [n, ed.display_name])

func _forward_along(points: PackedVector2Array, dist: float) -> Dictionary:
	var seg := 0
	var pos: Vector2 = points[0]
	var remaining := dist
	while remaining > 0.0 and seg < points.size() - 1:
		var nxt: Vector2 = points[seg + 1]
		var v := nxt - pos
		var d := v.length()
		if d >= remaining:
			return {"index": seg, "pos": pos + v / maxf(d, 0.0001) * remaining}
		remaining -= d
		pos = nxt
		seg += 1
	return {"index": seg, "pos": pos}

func _enemy_radius(ed: EnemyData) -> float:
	match ed.shape:
		"rect":
			return maxf(ed.length, ed.width) * 0.5
		"octagon", "polygon", "tetrahedron", "cube", "octahedron", "dodecahedron", \
		"icosahedron", "stella_octangula", "cube_octahedron", "dodeca_icosahedron":
			return ed.radius
		_:
			return ed.side * 0.5

func _spawn_enemy(type_id: String) -> void:
	var ed = content.enemy(type_id)
	if ed == null:
		push_warning("Unknown enemy type in wave: " + type_id)
		return
	var e := Enemy3D.new()
	e.bounty.connect(_on_enemy_bounty)
	e.reached_goal.connect(_on_enemy_reached_goal)
	e.split.connect(_on_enemy_split)
	e.setup(ed, board.get_path_points())
	board.add_enemy(e)

func _on_enemy_split(lesser, placements: Array) -> void:
	for pl in placements:
		var e := Enemy3D.new()
		e.bounty.connect(_on_enemy_bounty)
		e.reached_goal.connect(_on_enemy_reached_goal)
		e.split.connect(_on_enemy_split)
		e.setup(lesser, board.get_path_points())
		e.place_on_path(int(pl["index"]), pl["pos"])
		board.add_enemy(e)
		# Buffer Overflow: a freshly spawned child takes its share of the surplus.
		var carry: float = float(pl.get("carry", 0.0))
		if carry > 0.0:
			e.take_damage(carry, bool(pl.get("pierce", false)))

func _on_start_pressed() -> void:
	if waves.is_empty():
		return
	var wi: int = clampi(wave_select.selected, 0, waves.size() - 1)
	var wave: Dictionary = waves[wi]
	var timeline: Array = WaveLoader.build_timeline(wave, default_gap)
	if timeline.is_empty():
		return
	if _wave_running:
		var offset := _wave_clock
		for ev in timeline:
			ev["time"] = ev["time"] + offset
		_spawn_timeline.append_array(timeline)
		_spawn_timeline.sort_custom(func(a, b): return a["time"] < b["time"])
	else:
		_spawn_timeline = timeline
		_wave_clock = 0.0
		_wave_running = true
	var wname: String = WaveLoader.wave_name(wave, wi)
	# Banner: show the custom wave name if there is one, else "Wave N".
	var nm = wave.get("name", "")
	var banner_text: String = wname if (nm is String and nm != "") else "Wave %d" % (wi + 1)
	wave_select.selected = (wi + 1) % waves.size()
	_show_wave_banner(banner_text)
	_play_sfx("wave_start")
	_set_info("Started wave %s." % wname)

# Game mode: waves run strictly in order with a manual break between each. The
# next wave can only be started once the current one has finished spawning and
# the board is clear of enemies.
func _can_start_next() -> bool:
	return not game_over and not _wave_running and _spawn_timeline.is_empty() \
		and board.enemies.is_empty() and game_wave_index < waves.size()

func _on_start_next_pressed() -> void:
	if not _can_start_next():
		return
	var wi: int = game_wave_index
	var wave: Dictionary = waves[wi]
	var timeline: Array = WaveLoader.build_timeline(wave, default_gap)
	game_wave_index += 1
	if timeline.is_empty():
		return
	_spawn_timeline = timeline
	_wave_clock = 0.0
	_wave_running = true
	var wname: String = WaveLoader.wave_name(wave, wi)
	var nm = wave.get("name", "")
	var banner_text: String = wname if (nm is String and nm != "") else "Wave %d" % (wi + 1)
	_show_wave_banner(banner_text)
	_play_sfx("wave_start")
	_set_info("Started wave %s." % wname)

# Combat is "in progress" while a wave is spawning or any enemy is still alive on
# the board — the only time pausing is meaningful.
func _combat_active() -> bool:
	return _wave_running or not board.enemies.is_empty()

# The hex centre button dispatches to the mode's start logic.
func _on_wave_button_pressed() -> void:
	if is_game:
		_on_start_next_pressed()
	else:
		_on_start_pressed()

# Reflect wave state on the centre hex: the "start" art with the next wave number
# when a wave can be started, the "in progress" art with the live wave number
# while one runs, and a cleared marker once every wave is done. Sandbox can always
# start, so it just shows the currently selected wave.
# Runs per frame; the target state is computed first and only applied on change
# (add_theme_color_override dirties + repaints the label even for equal values).
func _update_wave_button() -> void:
	if wave_button == null:
		return
	if is_game:
		var disabled := true
		var icon := ""
		var num := ""
		var num_col := WAVE_RUN_COL
		if game_wave_index >= waves.size():
			var cleared := not _combat_active() and _spawn_timeline.is_empty()
			icon = "wave_start" if cleared else "wave_inprogress"
			num = "✓" if cleared else str(game_wave_index)
			num_col = WAVE_DONE_COL if cleared else WAVE_RUN_COL
		elif _can_start_next():
			disabled = false
			icon = "wave_start"
			num = str(game_wave_index + 1)
			num_col = WAVE_START_COL
		else:
			icon = "wave_inprogress"
			num = str(game_wave_index)
			num_col = WAVE_RUN_COL
		var key: Array = [disabled, icon, num, num_col]
		if key == _wave_btn_key:
			return
		_wave_btn_key = key
		wave_button.disabled = disabled
		wave_button.texture_normal = _load_icon(icon)
		wave_num_label.text = num
		wave_num_label.add_theme_color_override("font_color", num_col)
		# A button that disables under the cursor never gets mouse_exited — drop
		# any stuck hover brightness, and dim the art like pause does.
		if disabled:
			_clear_hover(wave_button)
		wave_button.self_modulate = Color(1, 1, 1) if not disabled else Color(0.6, 0.6, 0.6, 0.9)
	else:
		# Sandbox: a plain wave_start hex (no number overlay); the dropdown names the
		# wave. Can always start (stacks onto a running wave) unless there are none.
		var key: Array = [waves.is_empty()]
		if key == _wave_btn_key:
			return
		_wave_btn_key = key
		wave_button.disabled = waves.is_empty()
		wave_button.texture_normal = _load_icon("wave_start")

# The pause/play control only makes sense during combat — gray it out and lock it
# between waves. Its icon shows the action it performs (pause while running, play
# while paused).
func _update_pause_button() -> void:
	if pause_button == null:
		return
	var active := _combat_active()
	if not active and paused:
		# Combat ended while paused (shouldn't normally happen) — restore time flow.
		paused = false
		Engine.time_scale = speed_steps[speed_index]
	var key: Array = [active, paused]
	if key == _pause_btn_key:
		return
	_pause_btn_key = key
	pause_button.disabled = not active
	pause_button.texture_normal = _load_icon("play" if paused else "pause")
	pause_button.self_modulate = Color(1, 1, 1) if active else Color(0.42, 0.42, 0.42, 0.85)
	if pause_button.disabled:
		_clear_hover(pause_button)

# Bounty/leak can fire dozens of times per frame during a wipe — only the money
# math runs here; _flush_hud does the label/affordability/pulse work once.
func _on_enemy_bounty(amount: int) -> void:
	money += amount
	_hud_dirty = true
	_money_pulse_pending = true

func _on_enemy_reached_goal() -> void:
	lives = maxi(0, lives - 1)
	_hud_dirty = true
	_lives_pulse_pending = true
	_play_sfx("enemy_leak")
	if lives <= 0 and is_game and not game_over:
		_trigger_defeat()

func _trigger_defeat() -> void:
	game_over = true
	_wave_running = false
	_wave_awaiting_clear = false
	_spawn_timeline.clear()
	Engine.time_scale = 0.0
	paused = true
	_play_sfx("defeat")
	# Loss gets its own dressing (red banner + subtitle + dark wash) — it must
	# not read like just another wave name.
	banner_label.text = "SYSTEM FAILURE"
	banner_label.add_theme_color_override("font_color", Color(1.0, 0.28, 0.24))
	banner_label.add_theme_font_size_override("font_size", 72)
	banner_label.scale = Vector2.ONE
	banner_label.modulate.a = 1.0
	defeat_sub_label.text = "all lives lost — kernel panic"
	defeat_sub_label.visible = true
	_defeat_ms = Time.get_ticks_msec()
	_banner_time = 0.0

# ---------------------------------------------------------------- sandbox controls
func _on_speed_pressed() -> void:
	speed_index = (speed_index + 1) % speed_steps.size()
	# While paused, just remember the new speed; resuming applies it.
	if not paused:
		Engine.time_scale = speed_steps[speed_index]
	speed_button.texture_normal = _load_icon("speed_%dx" % int(speed_steps[speed_index]))

# Pause freezes everything by zeroing the engine time scale (all _process delta
# is scaled by it). Resuming restores the current speed multiplier. The icon
# swaps to the play glyph while paused so the button reads as "resume".
func _on_pause_pressed() -> void:
	if game_over:
		return
	if not _combat_active():
		return                       # nothing to pause between waves
	paused = not paused
	Engine.time_scale = 0.0 if paused else speed_steps[speed_index]
	_update_pause_button()

func _on_sound_pressed() -> void:
	sound_on = not sound_on
	var am = get_node_or_null("/root/AudioManager")
	if am:
		am.set_muted(not sound_on)
	sound_button.texture_normal = _load_art("sound_on" if sound_on else "sound_off")

func _on_cheat_pressed() -> void:
	money += cheat_amount
	_update_labels()
	_set_info("Cheat: +%d funds." % cheat_amount)
	# Tiny coin blip; the AudioManager's per-name rate floor keeps the
	# hold-to-repeat ramp from becoming a jackhammer.
	_play_sfx("cheat_money")

# Press grants one award immediately and arms the hold-to-repeat ramp.
func _on_cheat_down() -> void:
	_on_cheat_pressed()
	_cheat_held = true
	_cheat_hold_time = 0.0
	_cheat_next = 0.0

func _on_cheat_up() -> void:
	_cheat_held = false

# Called every frame: once the button has been held past the delay, fire repeat
# awards on an interval that ramps from CHEAT_INTERVAL_START down to _MIN.
func _cheat_tick(delta: float) -> void:
	if not _cheat_held:
		return
	# Safety net in case button_up was missed (focus loss, drag-off).
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_cheat_held = false
		return
	_cheat_hold_time += delta
	if _cheat_hold_time < CHEAT_REPEAT_DELAY:
		return
	_cheat_next -= delta
	if _cheat_next <= 0.0:
		_on_cheat_pressed()
		var t := _cheat_hold_time - CHEAT_REPEAT_DELAY
		var f := clampf(t / CHEAT_RAMP_TIME, 0.0, 1.0)
		_cheat_next = lerpf(CHEAT_INTERVAL_START, CHEAT_INTERVAL_MIN, f)

# Graphic-only hex button: the hex-face PNG *is* the button (TextureButton, no
# chrome — the same pattern as pause/speed/wave), aspect-centred at icon height.
func _style_icon_button(b: TextureButton, art: String) -> void:
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	b.custom_minimum_size = Vector2(0, ICON_BTN_PX)
	b.texture_normal = _load_art(art)
	_add_hover_glow(b)

# Brighten a hex button while the cursor is over it (unless it's disabled), with
# a short glide instead of a snap, plus a small press-in scale for tactility.
# Uses modulate, so it composes with any self_modulate state tint (e.g. pause's
# dim). Tweens ignore time_scale so buttons stay alive while paused.
func _add_hover_glow(b: BaseButton) -> void:
	b.pivot_offset = b.size * 0.5
	b.resized.connect(func() -> void:
		b.pivot_offset = b.size * 0.5)
	b.mouse_entered.connect(func() -> void:
		if not b.disabled:
			_tween_button(b, "modulate", Color(1.3, 1.3, 1.3), 0.08))
	b.mouse_exited.connect(func() -> void:
		_tween_button(b, "modulate", Color(1, 1, 1), 0.18))
	b.button_down.connect(func() -> void:
		if not b.disabled:
			_tween_button(b, "scale", Vector2(0.94, 0.94), 0.05)
			_play_sfx("ui_click"))
	b.button_up.connect(func() -> void:
		_tween_button(b, "scale", Vector2.ONE, 0.15, Tween.TRANS_BACK))

# One eased property tween per (button, property); refire kills the previous so
# rapid hover/press can't stack.
func _tween_button(b: Control, prop: String, to: Variant, dur: float, trans := Tween.TRANS_QUAD) -> void:
	var key := "tw_" + prop
	var prev: Tween = b.get_meta(key) if b.has_meta(key) else null
	if prev != null and prev.is_valid():
		prev.kill()
	# Tweens advance on scaled time and 4.3 has no ignore_time_scale, so while
	# the game is frozen (pause / defeat) apply the state instantly — buttons
	# must never feel dead under the cursor.
	if Engine.time_scale <= 0.05:
		b.set_indexed(prop, to)
		return
	var tw := b.create_tween()
	tw.tween_property(b, prop, to, dur).set_trans(trans).set_ease(Tween.EASE_OUT)
	b.set_meta(key, tw)

# Snap a button's hover brightness off (used when it disables under the cursor,
# where mouse_exited never fires).
func _clear_hover(b: Control) -> void:
	if b.modulate == Color(1, 1, 1):
		return
	var prev: Tween = b.get_meta("tw_modulate") if b.has_meta("tw_modulate") else null
	if prev != null and prev.is_valid():
		prev.kill()
	b.modulate = Color(1, 1, 1)

# Spawn icon reads singular at a count of 1, plural above it.
func _update_spawn_icon() -> void:
	if spawn_button == null or spawn_count == null:
		return
	spawn_button.texture_normal = _load_art("spawn_enemy" if int(spawn_count.value) == 1 else "spawn_enemies")

func _on_exit_pressed() -> void:
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file("res://scenes/menu.tscn")

func _mouse_over_pane() -> bool:
	var mx := get_viewport().get_mouse_position().x
	return mx > get_viewport().get_visible_rect().size.x - float(pane_width)

# ---------------------------------------------------------------- stats overlay
# Money and lives in the top-left corner: a glyph (money.png / lives.png) + the
# number, outlined so they read over the board.
func _build_stats_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_TOP_LEFT)
	box.position = Vector2(14, 10)
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(box)
	lives_label = _build_stat_row(box, "lives", Color(0.93, 0.24, 0.24))
	money_label = _build_stat_row(box, "money", Color(1.0, 0.82, 0.25))

func _build_stat_row(parent: Control, glyph: String, text_col: Color) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)
	var icon := TextureRect.new()
	icon.texture = _load_art(glyph)
	icon.custom_minimum_size = Vector2(STAT_ICON_PX, STAT_ICON_PX)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var lbl := Label.new()
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 44)
	lbl.add_theme_color_override("font_color", text_col)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("outline_size", 6)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lbl)
	return lbl

# ---------------------------------------------------------------- map title
# The map name, bold and centred along the top of the play area (not the side bar).
func _build_map_title() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 3                       # above the board, below the wave banner (4)
	add_child(layer)
	var lbl := Label.new()
	lbl.text = map.display_name
	# Give the label a real rect (a zero-height anchor band collapses to the top-left
	# and breaks horizontal centring) spanning the play area, and centre within it.
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.offset_right = -float(pane_width)
	lbl.anchor_bottom = 0.0
	lbl.offset_bottom = 50
	lbl.offset_top = 10
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 26)
	# Synthesised bold + a soft outline so it reads over the bright board.
	lbl.add_theme_font_override("font", _bold_font())
	lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("outline_size", 6)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(lbl)

# Synthesised bold (no bold font asset needed) — shared by the map title, the
# wave-number hex overlay and the pane section headers.
func _bold_font(embolden := 0.6) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	fv.variation_embolden = embolden
	return fv

# ---------------------------------------------------------------- wave banner
# A large title that pops up and fades out when a wave starts, naming the wave.
func _build_wave_banner() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 4                       # above the pane (2) and badges (1)
	add_child(layer)
	banner_label = Label.new()
	banner_label.text = ""
	# Span the play area (left of the pane), upper third, and let alignment center
	# the text — robust against text width / window resizes.
	banner_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner_label.offset_right = -float(pane_width)
	banner_label.anchor_bottom = 0.34
	banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	banner_label.add_theme_font_size_override("font_size", 56)
	banner_label.add_theme_color_override("font_color", Color(1, 1, 1))
	banner_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	banner_label.add_theme_constant_override("outline_size", 10)
	banner_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_label.modulate = Color(1, 1, 1, 0.0)   # hidden until a wave starts
	# Defeat dressing, hidden until _trigger_defeat: a dark red-black wash over
	# the play area behind the banner, plus a smaller subtitle under it.
	defeat_dim = ColorRect.new()
	defeat_dim.color = Color(0.06, 0.0, 0.02, 0.0)
	defeat_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	defeat_dim.offset_right = -float(pane_width)
	defeat_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(defeat_dim)
	layer.move_child(defeat_dim, 0)                # behind the banner label
	defeat_sub_label = Label.new()
	defeat_sub_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	defeat_sub_label.offset_right = -float(pane_width)
	defeat_sub_label.anchor_top = 0.30
	defeat_sub_label.anchor_bottom = 0.40
	defeat_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	defeat_sub_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	defeat_sub_label.add_theme_font_size_override("font_size", 20)
	defeat_sub_label.add_theme_color_override("font_color", Color(1, 0.55, 0.5, 0.8))
	defeat_sub_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	defeat_sub_label.add_theme_constant_override("outline_size", 6)
	defeat_sub_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	defeat_sub_label.visible = false
	layer.add_child(defeat_sub_label)
	layer.add_child(banner_label)

# Restart the pop-up timer, showing the given wave's name. Also clears any
# defeat styling so a later banner (e.g. after a scene reload) reads normal.
func _show_wave_banner(wave_label: String) -> void:
	if banner_label == null:
		return
	banner_label.text = wave_label
	banner_label.add_theme_color_override("font_color", Color(1, 1, 1))
	banner_label.add_theme_font_size_override("font_size", 56)
	_banner_time = BANNER_IN + BANNER_HOLD + BANNER_FADE

# Drive the banner in real time so the speed multiplier doesn't change it:
# quick pop-in (fade + scale settle), hold, eased fade-out. Defeat holds forever
# and pulls the dark wash in underneath.
func _update_banner(delta: float) -> void:
	if banner_label == null:
		return
	if game_over:
		# time_scale is 0 here, which zeroes _process delta — animate the wash
		# off the wall clock instead.
		var el: float = float(Time.get_ticks_msec() - _defeat_ms) / 1000.0
		defeat_dim.color.a = minf(0.55, el / 0.6 * 0.55)
		banner_label.modulate.a = 1.0
		return
	if _banner_time <= 0.0:
		return
	var dt := delta / maxf(Engine.time_scale, 0.0001)
	_banner_time = maxf(0.0, _banner_time - dt)
	banner_label.pivot_offset = banner_label.size * 0.5
	var tail := BANNER_HOLD + BANNER_FADE
	if _banner_time > tail:
		var t_in := 1.0 - (_banner_time - tail) / BANNER_IN
		banner_label.modulate.a = t_in
		banner_label.scale = Vector2.ONE * lerpf(1.18, 1.0, 1.0 - pow(1.0 - t_in, 3.0))
	else:
		banner_label.scale = Vector2.ONE
		var t_out := clampf(_banner_time / BANNER_FADE, 0.0, 1.0)
		banner_label.modulate.a = t_out * t_out * (3.0 - 2.0 * t_out)   # smoothstep ease

# ---------------------------------------------------------------- ability badges
# Toggle the world-space badge row as the selection changes. The badges live on
# the tower itself (Tower3D.set_badges_visible), so they track the camera natively
# — Main3D only flips them on/off here.
func _set_badged_tower(t) -> void:
	if t == _badged_tower:
		return
	if _badged_tower != null and is_instance_valid(_badged_tower):
		_badged_tower.set_badges_visible(false)
		_badged_tower.set_selected(false)
	_badged_tower = t
	if t != null:
		t.set_badges_visible(true)
		t.set_selected(true)
	else:
		_update_badge_tooltip()   # selection cleared -> drop any visible tip

# A small screen-space tooltip panel: ability text on the left, the full glyph on
# the right. Shown when the cursor is over one of the selected tower's badges.
# Kept deliberately flat — Label + one TextureRect as direct HBox children — so it
# matches the layout that already worked and avoids anchored children inside a
# container (which laid out inconsistently).
const TIP_ICON_PX := 52.0             # tooltip glyph preview size
func _build_badge_tooltip() -> void:
	badge_tip_layer = CanvasLayer.new()
	badge_tip_layer.layer = 5             # above the pane (2) and the wave banner (4)
	add_child(badge_tip_layer)
	badge_tip_panel = PanelContainer.new()
	badge_tip_panel.visible = false
	badge_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = TOOLTIP_BG
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_border_width_all(1)
	badge_tip_panel.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_tip_panel.add_child(row)
	# Glyph on the LEFT, text on the right.
	badge_tip_glyph = TextureRect.new()
	badge_tip_glyph.custom_minimum_size = Vector2(TIP_ICON_PX, TIP_ICON_PX)
	badge_tip_glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	badge_tip_glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	badge_tip_glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(badge_tip_glyph)
	badge_tip_label = Label.new()
	badge_tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_tip_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge_tip_label.add_theme_color_override("font_color", Color(1, 1, 1))
	# Wrap long ability text instead of producing a screen-wide panel.
	badge_tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	badge_tip_label.custom_minimum_size = Vector2(240, 0)
	row.add_child(badge_tip_label)
	badge_tip_layer.add_child(badge_tip_panel)

# Load a UI icon from art/<file>.svg (pause / speed_Nx). Returns null if the
# asset hasn't been imported, so headless/parse runs don't choke on missing art.
func _load_icon(file: String) -> Texture2D:
	if _art_cache.has(file):
		return _art_cache[file]
	var tex: Texture2D = null
	var path := "res://art/%s%s.svg" % [ArtPaths.dir(file), file]
	if ResourceLoader.exists(path):
		tex = load(path)
	_art_cache[file] = tex
	return tex

func _load_art(file: String) -> Texture2D:
	if _art_cache.has(file):
		return _art_cache[file]
	var tex: Texture2D = null
	var path := "res://art/%s%s.png" % [ArtPaths.dir(file), file]
	if ResourceLoader.exists(path):
		tex = load(path)
	_art_cache[file] = tex
	return tex

# Ask the selected tower whether a badge is under the cursor; show its tip + the
# full composite glyph if so.
func _update_badge_tooltip() -> void:
	if badge_tip_panel == null:
		return
	# The probe result only moves with the cursor, the camera (badges billboard),
	# the badged tower, or a badge-row rebuild (upgrade) — skip re-probing until
	# one of those changes.
	var mp: Vector2 = get_viewport().get_mouse_position()
	var key: Array = [
		mp,
		camera.global_transform if camera != null else Transform3D(),
		_badged_tower.get_instance_id() if (_badged_tower != null and is_instance_valid(_badged_tower)) else 0,
		_upgrade_rev,
	]
	if key == _tip_probe_key:
		return
	_tip_probe_key = key
	var hit := {}
	if _badged_tower != null and is_instance_valid(_badged_tower) and camera != null and not _mouse_over_pane():
		hit = _badged_tower.badge_tip_at(camera, mp)
	if hit.is_empty():
		badge_tip_panel.visible = false
		_tip_file = ""
		return
	badge_tip_label.text = str(hit["tip"])
	var file: String = str(hit["file"])
	if file != _tip_file:
		_tip_file = file
		badge_tip_glyph.texture = _load_art(file + "_glyph")
	badge_tip_panel.visible = true
	# Keep the tip on screen: flip to the other side of the cursor at the
	# right/bottom edges instead of clipping off.
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var sz: Vector2 = badge_tip_panel.get_combined_minimum_size()
	var pos: Vector2 = mp + Vector2(16, 16)
	if pos.x + sz.x > vp.x - 6.0:
		pos.x = maxf(6.0, mp.x - sz.x - 8.0)
	if pos.y + sz.y > vp.y - 6.0:
		pos.y = maxf(6.0, mp.y - sz.y - 8.0)
	badge_tip_panel.position = pos

# Same controls and layout as the 2D Main.
# CanvasLayer floats the panel above the 3D viewport.
# The pane's dark theme: panel background, button family (Button / OptionButton
# and its PopupMenu / TabContainer / SpinBox LineEdit), separators and the dark
# tooltips. Stock Godot grey belonged to a different game than the neon board.
const PANE_BG := Color(0.035, 0.045, 0.075, 0.97)
const BTN_BG := Color(0.09, 0.11, 0.17)
const BTN_BG_HOVER := Color(0.13, 0.16, 0.24)
const BTN_BG_PRESSED := Color(0.06, 0.075, 0.12)
const BTN_BG_DISABLED := Color(0.05, 0.06, 0.09)
const ACCENT := Color(0.647, 0.455, 1.0)          # WAVE_START_COL purple

func _btn_box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(5)
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb

func _make_pane_theme() -> Theme:
	var th := Theme.new()
	# Tooltips (shared by every control in the pane).
	var tip := StyleBoxFlat.new()
	tip.bg_color = TOOLTIP_BG
	tip.set_corner_radius_all(5)
	tip.set_content_margin_all(7)
	tip.border_color = Color(1, 1, 1, 0.12)
	tip.set_border_width_all(1)
	th.set_stylebox("panel", "TooltipPanel", tip)
	th.set_color("font_color", "TooltipLabel", Color(0.92, 0.94, 0.98))
	# Pane background: near-black with a thin neon seam on the board-facing edge.
	var pane := StyleBoxFlat.new()
	pane.bg_color = PANE_BG
	pane.border_width_left = 2
	pane.border_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.30)
	th.set_stylebox("panel", "Panel", pane)
	# Button family.
	var normal := _btn_box(BTN_BG, Color(1, 1, 1, 0.10))
	var hover := _btn_box(BTN_BG_HOVER, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.35))
	var pressed := _btn_box(BTN_BG_PRESSED, Color(1, 1, 1, 0.10))
	var disabled := _btn_box(BTN_BG_DISABLED, Color(1, 1, 1, 0.05))
	for cls in ["Button", "OptionButton"]:
		th.set_stylebox("normal", cls, normal)
		th.set_stylebox("hover", cls, hover)
		th.set_stylebox("pressed", cls, pressed)
		th.set_stylebox("disabled", cls, disabled)
		th.set_stylebox("focus", cls, hover)
		th.set_color("font_color", cls, Color(0.86, 0.90, 0.98))
		th.set_color("font_hover_color", cls, Color(1, 1, 1))
		th.set_color("font_pressed_color", cls, Color(0.86, 0.90, 0.98))
		th.set_color("font_disabled_color", cls, Color(0.86, 0.90, 0.98, 0.4))
	# OptionButton dropdown list.
	var pop := StyleBoxFlat.new()
	pop.bg_color = Color(0.05, 0.06, 0.10, 0.98)
	pop.set_corner_radius_all(5)
	pop.border_color = Color(1, 1, 1, 0.12)
	pop.set_border_width_all(1)
	pop.set_content_margin_all(4)
	th.set_stylebox("panel", "PopupMenu", pop)
	th.set_stylebox("hover", "PopupMenu", _btn_box(BTN_BG_HOVER, Color(0, 0, 0, 0)))
	th.set_color("font_color", "PopupMenu", Color(0.86, 0.90, 0.98))
	th.set_color("font_hover_color", "PopupMenu", Color(1, 1, 1))
	# Tabs (sandbox Waves/Spawn).
	var tab_sel := _btn_box(BTN_BG, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.45))
	tab_sel.corner_radius_bottom_left = 0
	tab_sel.corner_radius_bottom_right = 0
	var tab_un := _btn_box(Color(0.05, 0.06, 0.10), Color(1, 1, 1, 0.06))
	tab_un.corner_radius_bottom_left = 0
	tab_un.corner_radius_bottom_right = 0
	th.set_stylebox("tab_selected", "TabContainer", tab_sel)
	th.set_stylebox("tab_unselected", "TabContainer", tab_un)
	var tab_panel := StyleBoxFlat.new()
	tab_panel.bg_color = Color(0.05, 0.06, 0.10, 0.6)
	tab_panel.set_corner_radius_all(5)
	tab_panel.corner_radius_top_left = 0
	tab_panel.set_content_margin_all(8)
	th.set_stylebox("panel", "TabContainer", tab_panel)
	th.set_color("font_selected_color", "TabContainer", Color(1, 1, 1))
	th.set_color("font_unselected_color", "TabContainer", Color(0.7, 0.74, 0.85, 0.7))
	# SpinBox's text field.
	var le := _btn_box(Color(0.05, 0.06, 0.10), Color(1, 1, 1, 0.10))
	th.set_stylebox("normal", "LineEdit", le)
	th.set_color("font_color", "LineEdit", Color(0.86, 0.90, 0.98))
	# Separators: a dim accent-tinted line instead of the stock grey groove.
	var sep := StyleBoxLine.new()
	sep.color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.18)
	sep.thickness = 1
	th.set_stylebox("separator", "HSeparator", sep)
	return th

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)

	var panel := Panel.new()
	panel.anchor_left = 1.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -pane_width
	panel.offset_right = 0.0
	panel.offset_top = 0.0
	panel.offset_bottom = 0.0
	# Dark pane theme inherited by every control in the pane (buttons, tabs,
	# dropdowns, tooltips), so the UI belongs to the same night scene as the board.
	panel.theme = _make_pane_theme()
	layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Money and lives now live in the top-left overlay (see _build_stats_overlay).
	# The camera-position readout (a sandbox-only diagnostic) stays in the pane.
	if not is_game:
		cam_label = Label.new()
		cam_label.modulate = Color(1, 1, 1, 0.55)
		cam_label.add_theme_font_size_override("font_size", 12)
		vbox.add_child(cam_label)

	vbox.add_child(HSeparator.new())

	# Sandbox keeps its wave-picker / spawn tabs here. The actual Start button and
	# the pause/speed transport live in a bottom bar built at the end of this
	# method (identical placement in both modes); game mode shows no tabs at all.
	if not is_game:
		# "Start wave" and "Spawn enemies" used to stack on top of each other; they
		# now live in two tabs so only one set of controls shows at a time.
		var sandbox_tabs := TabContainer.new()
		# Fixed height (taller than either tab's content) so switching tabs doesn't
		# resize the container and shove the controls below it up or down. Fill the
		# pane width so the active tab's content can never widen the whole pane.
		sandbox_tabs.custom_minimum_size = Vector2(0, 170)
		sandbox_tabs.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		sandbox_tabs.size_flags_horizontal = Control.SIZE_FILL
		sandbox_tabs.clip_contents = true
		vbox.add_child(sandbox_tabs)

		var waves_tab := VBoxContainer.new()
		waves_tab.name = "Waves"
		waves_tab.add_theme_constant_override("separation", 8)
		sandbox_tabs.add_child(waves_tab)

		wave_select = OptionButton.new()
		# Fill the tab width and clip long names rather than letting the longest item
		# stretch the control (which previously widened the whole pane).
		wave_select.size_flags_horizontal = Control.SIZE_FILL
		wave_select.clip_text = true
		wave_select.custom_minimum_size = Vector2(0, 0)
		for i in range(waves.size()):
			var w: Dictionary = waves[i]
			var wname: String = WaveLoader.wave_name(w, i)
			wave_select.add_item(wname)
		if waves.size() > 0:
			wave_select.selected = 0
		waves_tab.add_child(wave_select)

		# Sandbox start-wave button: same hex-icon styling/size as the spawn button on
		# the other tab. (Game mode keeps its wave hex in the bottom transport instead.)
		wave_button = TextureButton.new()
		wave_button.ignore_texture_size = true
		wave_button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		wave_button.custom_minimum_size = Vector2(0, ICON_BTN_PX)
		wave_button.texture_normal = _load_icon("wave_start")
		wave_button.tooltip_text = "Start the selected wave"
		wave_button.disabled = waves.is_empty()
		wave_button.pressed.connect(_on_wave_button_pressed)
		_add_hover_glow(wave_button)
		waves_tab.add_child(wave_button)

		var spawn_tab := VBoxContainer.new()
		spawn_tab.name = "Spawn"
		spawn_tab.add_theme_constant_override("separation", 8)
		sandbox_tabs.add_child(spawn_tab)

		enemy_select = OptionButton.new()
		enemy_select.size_flags_horizontal = Control.SIZE_FILL
		enemy_select.clip_text = true
		enemy_select.custom_minimum_size = Vector2(0, 0)
		_enemy_ids = content.enemy_ids()
		for id in _enemy_ids:
			enemy_select.add_item(content.enemy(str(id)).display_name)
		if _enemy_ids.size() > 0:
			enemy_select.selected = 0
		spawn_tab.add_child(enemy_select)

		var count_row := HBoxContainer.new()
		count_row.size_flags_horizontal = Control.SIZE_FILL
		var count_label := Label.new()
		count_label.text = "Count"
		count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		count_row.add_child(count_label)
		spawn_count = SpinBox.new()
		spawn_count.min_value = 1
		spawn_count.max_value = 100
		spawn_count.step = 1
		spawn_count.value = 5
		spawn_count.custom_minimum_size = Vector2(0, 0)
		count_row.add_child(spawn_count)
		spawn_tab.add_child(count_row)

		spawn_button = TextureButton.new()
		_style_icon_button(spawn_button, "spawn_enemies")
		spawn_button.tooltip_text = "Spawn enemies"
		spawn_button.disabled = _enemy_ids.is_empty()
		spawn_button.pressed.connect(_on_spawn_pressed)
		spawn_tab.add_child(spawn_button)
		spawn_count.value_changed.connect(func(_v): _update_spawn_icon())
		_update_spawn_icon()

	# Sound and (in sandbox) the money cheat sit side-by-side on one row.
	var util_row := HBoxContainer.new()
	util_row.add_theme_constant_override("separation", 8)
	vbox.add_child(util_row)

	sound_button = TextureButton.new()
	_style_icon_button(sound_button, "sound_on")
	sound_button.tooltip_text = "Toggle sound"
	sound_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sound_button.pressed.connect(_on_sound_pressed)
	util_row.add_child(sound_button)

	if not is_game:
		var cheat_button := TextureButton.new()
		_style_icon_button(cheat_button, "cheat_money")
		cheat_button.tooltip_text = "Add ¤%d (hold to repeat, faster the longer you hold)." % cheat_amount
		cheat_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cheat_button.button_down.connect(_on_cheat_down)
		cheat_button.button_up.connect(_on_cheat_up)
		util_row.add_child(cheat_button)

	var exit_button := Button.new()
	exit_button.text = "Exit to map select"
	exit_button.pressed.connect(func() -> void:
		_play_sfx("ui_click")
		_on_exit_pressed())
	vbox.add_child(exit_button)

	vbox.add_child(HSeparator.new())

	# Quiet all-caps section label — gives the pane a typographic hierarchy the
	# uniform 16px default lacked.
	var towers_header := Label.new()
	towers_header.text = "TOWERS"
	towers_header.add_theme_font_size_override("font_size", 13)
	towers_header.add_theme_font_override("font", _bold_font(0.4))
	towers_header.add_theme_color_override("font_color", Color(0.62, 0.67, 0.80))
	vbox.add_child(towers_header)
	_build_tower_honeycomb(vbox)

	vbox.add_child(HSeparator.new())

	_tower_control_row = HBoxContainer.new()
	_tower_control_row.visible = false
	_tower_control_row.add_theme_constant_override("separation", 4)
	vbox.add_child(_tower_control_row)

	target_button = TextureButton.new()
	_style_icon_button(target_button, "focus_first")
	target_button.tooltip_text = "Target: First (tap to cycle)."
	target_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target_button.pressed.connect(_on_target_pressed)
	_tower_control_row.add_child(target_button)

	facing_button = TextureButton.new()
	_style_icon_button(facing_button, "rotate_footprint")
	facing_button.tooltip_text = "Toggle range shape between standard (wider) and rotated (taller)."
	facing_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	facing_button.pressed.connect(_on_facing_pressed)
	_tower_control_row.add_child(facing_button)

	upgrade_buttons = []
	for s in range(3):
		var ub := Button.new()
		ub.visible = false
		ub.custom_minimum_size = Vector2(0, 36)
		ub.pressed.connect(_on_upgrade_pressed.bind(s))
		vbox.add_child(ub)
		_attach_cost_label(ub)
		upgrade_buttons.append(ub)

	# Why a path is greyed, without hunting for the hover tooltip.
	crosspath_hint = Label.new()
	crosspath_hint.text = "Crosspath: max two paths, one above tier 2."
	crosspath_hint.add_theme_font_size_override("font_size", 12)
	crosspath_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	crosspath_hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	crosspath_hint.visible = false
	vbox.add_child(crosspath_hint)

	sell_button = Button.new()
	sell_button.visible = false
	sell_button.custom_minimum_size = Vector2(0, 36)
	sell_button.pressed.connect(_on_sell_pressed)
	vbox.add_child(sell_button)
	_attach_cost_label(sell_button)

	info_label = Label.new()
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	# Reserve three lines so one↔three-line messages don't shove the transport
	# honeycomb below around.
	info_label.custom_minimum_size = Vector2(0, 48)
	vbox.add_child(info_label)

	var help := Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD
	help.modulate = Color(1, 1, 1, 0.7)
	help.text = "Pan: middle-drag or WASD / arrows.\nZoom: scroll wheel.\nCancel: right-click or Esc."
	vbox.add_child(help)

	# --- bottom transport honeycomb ---
	# An expanding spacer sinks the cluster to the bottom of the pane.
	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(bottom_spacer)
	_build_transport(vbox)

# Pause, the wave button and speed as graphic-only hex buttons nested into a
# honeycomb: the (larger) wave hex sits on top, with pause tucked under its
# lower-left edge and speed under its lower-right edge. The SVG hex art is drawn
# in a 240-unit viewBox; a smaller hex sits flush against a larger one's slanted
# edge when its right/left point meets the big hex's bottom corner, so the offsets
# below are derived straight from those vertex coordinates and hold at any size.
func _build_transport(parent: Control) -> void:
	if not is_game:
		# Sandbox: only pause + speed here, side by side — the start-wave button lives
		# under the Waves tab. (Game mode builds the full wave/pause/speed honeycomb.)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		parent.add_child(row)
		pause_button = _make_row_hex(row, "pause")
		pause_button.tooltip_text = "Pause / Resume"
		pause_button.pressed.connect(_on_pause_pressed)
		speed_button = _make_row_hex(row, "speed_%dx" % int(speed_steps[speed_index]))
		speed_button.tooltip_text = "Game speed"
		speed_button.pressed.connect(_on_speed_pressed)
		_update_pause_button()
		return
	var d := float(BAR_ICON_PX)
	var dw := float(WAVE_ICON_PX)
	var fs := d / 240.0
	var fw := dw / 240.0
	var row_y := 217.0 * fw - 120.0 * fs          # pause/speed drop so their side point meets the wave's bottom corner
	var pause_pos := Vector2(0.0, row_y)
	var wave_pos := Vector2(232.0 * fs - 64.0 * fw, 0.0)
	var speed_pos := Vector2(112.0 * fw + 224.0 * fs, row_y)
	var honeycomb := Control.new()
	honeycomb.custom_minimum_size = Vector2(speed_pos.x + d, row_y + d)
	honeycomb.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(honeycomb)

	# Pause/speed first, wave last so the big hex draws on top at the shared edges.
	pause_button = _make_hex_button(honeycomb, pause_pos, d)
	pause_button.texture_normal = _load_icon("pause")
	_apply_hex_click_mask(pause_button)
	pause_button.tooltip_text = "Pause / Resume"
	pause_button.pressed.connect(_on_pause_pressed)

	speed_button = _make_hex_button(honeycomb, speed_pos, d)
	speed_button.texture_normal = _load_icon("speed_%dx" % int(speed_steps[speed_index]))
	_apply_hex_click_mask(speed_button)
	speed_button.tooltip_text = "Game speed"
	speed_button.pressed.connect(_on_speed_pressed)

	wave_button = _make_hex_button(honeycomb, wave_pos, dw)
	wave_button.texture_normal = _load_icon("wave_start")
	_apply_hex_click_mask(wave_button)
	wave_button.tooltip_text = "Start the next wave"
	wave_button.pressed.connect(_on_wave_button_pressed)
	wave_num_label = Label.new()
	wave_num_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	wave_num_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wave_num_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	wave_num_label.add_theme_font_size_override("font_size", int(dw * 0.30))
	# House style: embolden + black outline so the number doesn't shimmer
	# against the hex art's strokes.
	wave_num_label.add_theme_font_override("font", _bold_font())
	wave_num_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	wave_num_label.add_theme_constant_override("outline_size", int(dw * 0.045))
	wave_num_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wave_button.add_child(wave_num_label)

	_update_pause_button()
	_update_wave_button()

# A graphic-only hex button sized for an HBox row (expands to fill its share,
# aspect-centred at the transport icon height). Used for the sandbox pause/speed row.
func _make_row_hex(parent: Control, icon: String) -> TextureButton:
	var b := TextureButton.new()
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, BAR_ICON_PX)
	b.texture_normal = _load_icon(icon)
	_add_hover_glow(b)
	parent.add_child(b)
	return b

# A square TextureButton whose SVG art is the whole button (no chrome), placed at
# an explicit position inside a non-container parent.
func _make_hex_button(parent: Control, pos: Vector2, d: float) -> TextureButton:
	var b := TextureButton.new()
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	b.position = pos
	b.size = Vector2(d, d)
	b.custom_minimum_size = Vector2(d, d)
	_add_hover_glow(b)
	parent.add_child(b)
	return b

# Restrict a hex button's clickable area to the opaque hex art, so the overlapping
# (transparent) corners of neighbouring hex buttons don't steal each other's clicks.
func _apply_hex_click_mask(b: TextureButton) -> void:
	var tex: Texture2D = b.texture_normal
	if tex == null:
		return
	var img := tex.get_image()
	if img == null:
		return
	var bm := BitMap.new()
	bm.create_from_image_alpha(img, 0.25)
	b.texture_click_mask = bm

# Hex build buttons in a honeycomb: pointy-left/right hexes laid out in up to 3
# columns, each odd column dropped half a hex so they interlock. Offsets come from
# the 240-unit hex art (diagonal neighbour +168/+97, vertical stack +194), scaled
# to the button size, so the hexes pack flush.
func _build_tower_honeycomb(parent: Control) -> void:
	_tower_buttons.clear()
	var ids: Array = content.tower_ids()
	var n := ids.size()
	if n == 0:
		return
	var d := float(TOWER_HEX_PX)
	var f := d / 240.0
	var xoff := 168.0 * f
	var yoff := 194.0 * f
	var drop := 97.0 * f
	var cols := mini(3, n)
	var hc := Control.new()
	hc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(hc)
	var maxw := 0.0
	var maxh := 0.0
	for i in range(n):
		var col := i % cols
		var row := i / cols
		var x := float(col) * xoff
		var y := float(row) * yoff + float(col % 2) * drop
		var id := str(ids[i])
		var td := content.tower(id)
		var b := HexTowerButton.new()
		b.setup(id, td, _load_tower_pic(id), d)
		b.position = Vector2(x, y)
		b.tower_pressed.connect(_on_tower_pressed)
		hc.add_child(b)
		_tower_buttons.append(b)
		maxw = maxf(maxw, x + d)
		maxh = maxf(maxh, y + d)
	hc.custom_minimum_size = Vector2(maxw, maxh)

func _load_tower_pic(id: String) -> Texture2D:
	var path := "res://art/towers/tower_%s.png" % id
	if _art_cache.has(path):
		return _art_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	_art_cache[path] = tex
	return tex

func _on_tower_pressed(id: String) -> void:
	_play_sfx("ui_click")
	placing_id = id
	dragging = true
	has_selected = false
	_set_info("Placing %s — drop on a hex, or click a hex." % content.tower(id).display_name)

func _update_labels() -> void:
	money_label.text = str(money)
	lives_label.text = str(lives)
	for b in _tower_buttons:
		b.set_affordable(money >= b.cost)

# Brief tint flash so a label's change registers at the edge of vision (income,
# life loss, new info text). Re-arming overwrites the previous pulse so spam
# can't stack. Not a Tween: _decay_pulses drives the fade off the wall clock,
# so pulses keep fading while frozen (time_scale 0) and spammy callers don't
# churn Tween objects.
func _pulse_label(l: Label, c: Color) -> void:
	if l == null:
		return
	l.modulate = c
	_label_pulses[l] = {"color": c, "t": 1.0}

# Fade each armed pulse back to white over 0.35s with the same quad ease-out
# shape the old Tween used (eased = 1 - t², t running 1 → 0).
func _decay_pulses() -> void:
	var now := Time.get_ticks_msec()
	var dt := clampf(float(now - _pulse_last_ms) / 1000.0, 0.0, 0.1)
	_pulse_last_ms = now
	if _label_pulses.is_empty():
		return
	var done: Array = []
	for l in _label_pulses:
		if not is_instance_valid(l):
			done.append(l)
			continue
		var st: Dictionary = _label_pulses[l]
		var t: float = float(st["t"]) - dt / 0.35
		if t <= 0.0:
			l.modulate = Color(1, 1, 1)
			done.append(l)
		else:
			st["t"] = t
			var c: Color = st["color"]
			l.modulate = c.lerp(Color(1, 1, 1), 1.0 - t * t)
	for l in done:
		_label_pulses.erase(l)

# kind: "info" (neutral), "error" (rejections), "success" (confirmations) — the
# same slot used to render all three identically.
func _play_sfx(sound_name: String) -> void:
	var am = get_node_or_null("/root/AudioManager")
	if am:
		am.play_sfx(sound_name)

func _set_info(text: String, kind := "info") -> void:
	if info_label == null:
		return
	info_label.text = text
	var col := Color(0.85, 0.89, 0.98)
	match kind:
		"error":
			col = Color(1.0, 0.5, 0.45)
		"success":
			col = Color(0.55, 0.85, 0.6)
	info_label.add_theme_color_override("font_color", col)
	_pulse_label(info_label, Color(1.35, 1.35, 1.35))
