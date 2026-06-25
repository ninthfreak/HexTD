class_name Main3D
extends Node3D
## 3D sandbox scene. Same game loop as the 2D Main — sandbox controls,
## drag-to-place towers, wave/spawn helpers — but with a 3D camera, directional
## light, sky environment and a raycast-to-ground click model. A selected tower's
## ability badges are real world-space children of the tower (built in Tower3D),
## so they ride the camera natively; Main3D just toggles them on selection.

# --- tunable game state ---
var money := 200
var lives := 20
var waves: Array = []
var default_gap := 0.7
var cheat_amount := 500

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

# --- mode ---
# "game" plays the waves in order with a manual break between each (no cheats,
# no free spawning, no camera readout); "sandbox" exposes the full toolbox.
var is_game := false
var game_wave_index := 0          # next wave to start in game mode (0-based)

# --- speed / pause ---
var speed_steps := [1.0, 2.0, 3.0]
var speed_index := 0
var paused := false

# --- wave runtime (absolute-timeline) ---
var _spawn_timeline: Array = []   # sorted {time, type} from WaveLoader.build_timeline
var _wave_clock := 0.0
var _wave_running := false

# --- wave-name banner (pops up + fades out when a wave starts) ---
var banner_label: Label
var _banner_time := 0.0            # real-time seconds remaining (hold + fade)
const BANNER_HOLD := 1.4          # fully-opaque seconds
const BANNER_FADE := 1.2          # fade-out seconds

# --- UI ---
var money_label: Label
var lives_label: Label
var cam_label: Label                 # camera readout, right of the lives line
var wave_select: OptionButton
var enemy_select: OptionButton
var spawn_count: SpinBox
var _enemy_ids: Array = []
var speed_button: Button
var pause_button: Button
var start_next_button: Button        # game mode: start the next wave
var sound_button: Button
var sound_on := true
var target_button: Button
var upgrade_buttons: Array = []
var sell_button: Button
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

func _ready() -> void:
	Engine.time_scale = 1.0
	is_game = GameState.mode == "game"
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
	_build_wave_banner()
	_build_badge_tooltip()
	_update_labels()
	if is_game:
		_set_info("Build towers, then start each wave when you're ready.")
	else:
		_set_info("Sandbox (3D): start any wave, build towers, leave with Exit.")

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
	# projectiles). Stronger here since the dark scene is built around the glow.
	env.glow_enabled = true
	env.glow_intensity = 1.0
	env.glow_bloom = 0.15
	env.glow_hdr_threshold = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
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
	add_child(directional_light)

func _build_camera() -> void:
	cam_pivot = Node3D.new()
	add_child(cam_pivot)
	camera = Camera3D.new()
	camera.fov = 38.0
	camera.near = 0.5
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
	if is_game:
		_update_start_next_button()
	_update_banner(delta)
	_camera_keys(delta)
	_update_preview()
	_update_cam_readout()

# Live camera readout: orbit distance (the zoom metric) plus the camera's world
# position, so it's clear where the camera sits at any zoom/pan.
func _update_cam_readout() -> void:
	if cam_label == null or camera == null:
		return
	var p: Vector3 = camera.global_position
	cam_label.text = "cam d:%d  (%d, %d, %d)" % [int(round(cam_distance)), int(round(p.x)), int(round(p.y)), int(round(p.z))]

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
	overlay.selected_range = (board.tower_reach(board.tower_at(selected_cell).data.range_tiles) if has_selected and board.tower_at(selected_cell) != null else 0)
	var sel_t = board.tower_at(selected_cell) if has_selected else null
	if sel_t != null:
		overlay.selected_color = sel_t.data.color
		overlay.selected_ignore_walls = sel_t.data.ignore_walls
	overlay.refresh()
	_set_badged_tower(sel_t)
	_update_badge_tooltip()
	_update_target_button()
	_update_tower_buttons()

# Cast a ray from the cursor through the camera onto the y=0 plane and
# return the intersection as plane coords. This is the 3D counterpart of
# `get_global_mouse_position()` from the 2D scene.
func _mouse_to_plane() -> Vector2:
	var mp: Vector2 = get_viewport().get_mouse_position()
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

func _update_target_button() -> void:
	if not has_selected:
		target_button.visible = false
		return
	var t = board.tower_at(selected_cell)
	if t == null or t.data.fire_mode == "radial":
		target_button.visible = false
		return
	target_button.visible = true
	target_button.text = "Target: %s  (tap to change)" % _priority_label(t.target_priority)

func _priority_label(p: String) -> String:
	match p:
		"last":
			return "Last"
		"strongest":
			return "Strongest"
		_:
			return "First"

func _on_target_pressed() -> void:
	if not has_selected:
		return
	var t = board.tower_at(selected_cell)
	if t == null or t.data.fire_mode == "radial":
		return
	var p: String = t.cycle_target_priority()
	_update_target_button()
	_set_info("%s now targets: %s." % [t.data.display_name, _priority_label(p)])

func _update_tower_buttons() -> void:
	var t = (board.tower_at(selected_cell) if has_selected else null)
	for s in range(upgrade_buttons.size()):
		var b: Button = upgrade_buttons[s]
		if t == null or s >= t.slot_count():
			b.visible = false
			continue
		b.visible = true
		if t.can_upgrade(s):
			var c: int = t.next_cost(s)
			b.disabled = money < c
			b.text = "%s → Tier %d  ($%d)" % [t.slot_name(s), t.slot_level(s) + 1, c]
			b.tooltip_text = t.tier_summary(s)
		else:
			b.disabled = true
			b.text = "%s  (max %d)" % [t.slot_name(s), t.slot_level(s)]
			b.tooltip_text = "Fully upgraded"
	if t == null:
		sell_button.visible = false
	else:
		sell_button.visible = true
		sell_button.disabled = false
		sell_button.text = "Sell  (+$%d)" % t.sell_value()
		sell_button.tooltip_text = "Refund %d%% of everything spent on this tower." % t.refund_percent()

func _on_upgrade_pressed(s: int) -> void:
	if not has_selected:
		return
	var t = board.tower_at(selected_cell)
	if t == null or not t.can_upgrade(s):
		return
	var c: int = t.next_cost(s)
	if money < c:
		_set_info("Not enough money to upgrade (need %d)." % c)
		return
	money -= c
	t.upgrade(s)
	# A new tier can flip an ability flag, so rebuild the badge row.
	if t == _badged_tower:
		t.set_badges_visible(true)
	_update_labels()
	_update_tower_buttons()
	_set_info("%s: %s now at tier %d." % [t.data.display_name, t.slot_name(s), t.slot_level(s)])

func _on_sell_pressed() -> void:
	if not has_selected:
		return
	var t = board.tower_at(selected_cell)
	if t == null:
		return
	var refund: int = t.sell_value()
	var nm: String = t.data.display_name
	board.remove_tower(t.cell)
	money += refund
	has_selected = false
	_update_labels()
	_update_tower_buttons()
	_update_target_button()
	_set_info("Sold %s for %d." % [nm, refund])

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

func _zoom_by(factor: float) -> void:
	cam_distance = clampf(cam_distance * factor, min_distance, max_distance)
	_update_camera_transform()

# ---------------------------------------------------------------- placement
func _try_place(cell: Vector2i) -> bool:
	if not board.is_buildable(cell):
		_set_info("Can't build there.")
		return false
	var td := content.tower(placing_id)
	if money < td.cost:
		_set_info("Not enough money (need %d)." % td.cost)
		return false
	money -= td.cost
	var t := Tower3D.new()
	t.cell = cell
	t.setup(td, board, board.cell_center_world(cell))
	board.place_tower(cell, t)
	_update_labels()
	return true

func _select_tower(cell: Vector2i, t) -> void:
	has_selected = true
	selected_cell = t.cell
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
	_set_info("Started wave %s." % wname)

# Game mode: waves run strictly in order with a manual break between each. The
# next wave can only be started once the current one has finished spawning and
# the board is clear of enemies.
func _can_start_next() -> bool:
	return not _wave_running and _spawn_timeline.is_empty() \
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
	_set_info("Started wave %s." % wname)

# Reflect the current wave state in the button: ready between waves, locked while
# a wave is live, and a terminal message once every wave has been cleared.
func _update_start_next_button() -> void:
	if start_next_button == null:
		return
	if game_wave_index >= waves.size():
		start_next_button.disabled = true
		if not _wave_running and _spawn_timeline.is_empty() and board.enemies.is_empty():
			start_next_button.text = "All Waves Cleared!"
		else:
			start_next_button.text = "Final Wave…"
		return
	if _can_start_next():
		start_next_button.disabled = false
		start_next_button.text = "Start Wave %d" % (game_wave_index + 1)
	else:
		start_next_button.disabled = true
		start_next_button.text = "Wave %d in progress…" % game_wave_index

func _on_enemy_bounty(amount: int) -> void:
	money += amount
	_update_labels()

func _on_enemy_reached_goal() -> void:
	lives = maxi(0, lives - 1)
	_update_labels()

# ---------------------------------------------------------------- sandbox controls
func _on_speed_pressed() -> void:
	speed_index = (speed_index + 1) % speed_steps.size()
	# While paused, just remember the new speed; resuming applies it.
	if not paused:
		Engine.time_scale = speed_steps[speed_index]
	speed_button.icon = _load_icon("speed_%dx" % int(speed_steps[speed_index]))

# Pause freezes everything by zeroing the engine time scale (all _process delta
# is scaled by it). Resuming restores the current speed multiplier. The icon
# swaps to the play glyph while paused so the button reads as "resume".
func _on_pause_pressed() -> void:
	paused = not paused
	Engine.time_scale = 0.0 if paused else speed_steps[speed_index]
	pause_button.icon = _load_icon("play" if paused else "pause")

func _on_sound_pressed() -> void:
	sound_on = not sound_on
	var am = get_node_or_null("/root/AudioManager")
	if am:
		am.set_muted(not sound_on)
	sound_button.text = "Sound: On" if sound_on else "Sound: Off"

func _on_cheat_pressed() -> void:
	money += cheat_amount
	_update_labels()
	_set_info("Cheat: +%d funds." % cheat_amount)

func _on_exit_pressed() -> void:
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file("res://scenes/menu.tscn")

func _mouse_over_pane() -> bool:
	var mx := get_viewport().get_mouse_position().x
	return mx > get_viewport().get_visible_rect().size.x - float(pane_width)

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
	layer.add_child(banner_label)

# Restart the pop-up timer, showing the given wave's name.
func _show_wave_banner(wave_label: String) -> void:
	if banner_label == null:
		return
	banner_label.text = wave_label
	_banner_time = BANNER_HOLD + BANNER_FADE

# Drive the banner fade in real time so the speed multiplier doesn't change it.
func _update_banner(delta: float) -> void:
	if banner_label == null or _banner_time <= 0.0:
		return
	var dt := delta / maxf(Engine.time_scale, 0.0001)
	_banner_time = maxf(0.0, _banner_time - dt)
	banner_label.modulate.a = clampf(_banner_time / BANNER_FADE, 0.0, 1.0)

# ---------------------------------------------------------------- ability badges
# Toggle the world-space badge row as the selection changes. The badges live on
# the tower itself (Tower3D.set_badges_visible), so they track the camera natively
# — Main3D only flips them on/off here.
func _set_badged_tower(t) -> void:
	if t == _badged_tower:
		return
	if _badged_tower != null and is_instance_valid(_badged_tower):
		_badged_tower.set_badges_visible(false)
	_badged_tower = t
	if t != null:
		t.set_badges_visible(true)
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
	sb.bg_color = Color(0.06, 0.08, 0.12, 0.95)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	badge_tip_panel.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_tip_panel.add_child(row)
	badge_tip_label = Label.new()
	badge_tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_tip_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge_tip_label.add_theme_color_override("font_color", Color(1, 1, 1))
	row.add_child(badge_tip_label)
	badge_tip_glyph = TextureRect.new()
	badge_tip_glyph.custom_minimum_size = Vector2(TIP_ICON_PX, TIP_ICON_PX)
	badge_tip_glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	badge_tip_glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	badge_tip_glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(badge_tip_glyph)
	badge_tip_layer.add_child(badge_tip_panel)

# Load a UI icon from art/<file>.svg (pause / speed_Nx). Returns null if the
# asset hasn't been imported, so headless/parse runs don't choke on missing art.
func _load_icon(file: String) -> Texture2D:
	if _art_cache.has(file):
		return _art_cache[file]
	var tex: Texture2D = null
	var path := "res://art/%s.svg" % file
	if ResourceLoader.exists(path):
		tex = load(path)
	_art_cache[file] = tex
	return tex

func _load_art(file: String) -> Texture2D:
	if _art_cache.has(file):
		return _art_cache[file]
	var tex: Texture2D = null
	var path := "res://art/%s.png" % file
	if ResourceLoader.exists(path):
		tex = load(path)
	_art_cache[file] = tex
	return tex

# Ask the selected tower whether a badge is under the cursor; show its tip + the
# full composite glyph if so.
func _update_badge_tooltip() -> void:
	if badge_tip_panel == null:
		return
	var hit := {}
	if _badged_tower != null and is_instance_valid(_badged_tower) and camera != null and not _mouse_over_pane():
		hit = _badged_tower.badge_tip_at(camera, get_viewport().get_mouse_position())
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
	badge_tip_panel.position = get_viewport().get_mouse_position() + Vector2(16, 16)

# Same controls and layout as the 2D Main.
# CanvasLayer floats the panel above the 3D viewport.
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

	var title := Label.new()
	title.text = "HEX TD (3D)" if is_game else "HEX TD — SANDBOX (3D)"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var map_label := Label.new()
	map_label.text = map.display_name
	map_label.modulate = Color(1, 1, 1, 0.6)
	vbox.add_child(map_label)

	money_label = Label.new()
	vbox.add_child(money_label)

	# Lives on the left, a camera-position readout right-justified on the same line
	# (handy for dialing in how things look at different zoom distances). The camera
	# readout is a sandbox-only diagnostic — game mode shows just the lives.
	var stat_row := HBoxContainer.new()
	lives_label = Label.new()
	lives_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stat_row.add_child(lives_label)
	if not is_game:
		cam_label = Label.new()
		cam_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		cam_label.modulate = Color(1, 1, 1, 0.55)
		cam_label.add_theme_font_size_override("font_size", 12)
		stat_row.add_child(cam_label)
	vbox.add_child(stat_row)

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

		var spawn_button := Button.new()
		spawn_button.text = "Spawn"
		spawn_button.disabled = _enemy_ids.is_empty()
		spawn_button.pressed.connect(_on_spawn_pressed)
		spawn_tab.add_child(spawn_button)

	sound_button = Button.new()
	sound_button.text = "Sound: On"
	sound_button.pressed.connect(_on_sound_pressed)
	vbox.add_child(sound_button)

	if not is_game:
		var cheat_button := Button.new()
		cheat_button.text = "Cheat: +%d funds" % cheat_amount
		cheat_button.pressed.connect(_on_cheat_pressed)
		vbox.add_child(cheat_button)

	var exit_button := Button.new()
	exit_button.text = "Exit to map select"
	exit_button.pressed.connect(_on_exit_pressed)
	vbox.add_child(exit_button)

	vbox.add_child(HSeparator.new())

	var towers_header := Label.new()
	towers_header.text = "Towers"
	vbox.add_child(towers_header)

	for id in content.tower_ids():
		var td := content.tower(id)
		var b := Button.new()
		b.text = "%s    $%d" % [td.display_name, td.cost]
		b.custom_minimum_size = Vector2(0, 40)
		b.gui_input.connect(_on_tower_button_input.bind(id))
		vbox.add_child(b)

	vbox.add_child(HSeparator.new())

	target_button = Button.new()
	target_button.visible = false
	target_button.custom_minimum_size = Vector2(0, 36)
	target_button.pressed.connect(_on_target_pressed)
	vbox.add_child(target_button)

	upgrade_buttons = []
	for s in range(3):
		var ub := Button.new()
		ub.visible = false
		ub.custom_minimum_size = Vector2(0, 36)
		ub.pressed.connect(_on_upgrade_pressed.bind(s))
		vbox.add_child(ub)
		upgrade_buttons.append(ub)

	sell_button = Button.new()
	sell_button.visible = false
	sell_button.custom_minimum_size = Vector2(0, 36)
	sell_button.pressed.connect(_on_sell_pressed)
	vbox.add_child(sell_button)

	info_label = Label.new()
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(info_label)

	var help := Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD
	help.modulate = Color(1, 1, 1, 0.7)
	help.text = "Pan: middle-drag or WASD / arrows.\nZoom: scroll wheel.\nCancel: right-click or Esc.\nClick a placed tower to see its range."
	vbox.add_child(help)

	# --- bottom transport bar ---
	# An expanding spacer sinks the transport to the bottom of the pane. Pause and
	# the speed toggle sit side-by-side (icon buttons), with the Start-wave button
	# pinned beneath them at the very bottom — same layout in both modes.
	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(bottom_spacer)

	var transport := HBoxContainer.new()
	transport.add_theme_constant_override("separation", 8)
	vbox.add_child(transport)

	pause_button = Button.new()
	# Icon shows the action the button performs: pause while running, play while
	# paused. Momentary (not toggle) so it doesn't sit visually depressed.
	pause_button.icon = _load_icon("pause")
	pause_button.expand_icon = true
	pause_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pause_button.custom_minimum_size = Vector2(0, 48)
	pause_button.tooltip_text = "Pause / Resume"
	pause_button.pressed.connect(_on_pause_pressed)
	transport.add_child(pause_button)

	speed_button = Button.new()
	speed_button.icon = _load_icon("speed_%dx" % int(speed_steps[speed_index]))
	speed_button.expand_icon = true
	speed_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_button.custom_minimum_size = Vector2(0, 48)
	speed_button.tooltip_text = "Game speed"
	speed_button.pressed.connect(_on_speed_pressed)
	transport.add_child(speed_button)

	if is_game:
		# A single sequential control: waves run in order with a manual break between.
		start_next_button = Button.new()
		start_next_button.disabled = waves.is_empty()
		start_next_button.text = "Start Wave 1" if not waves.is_empty() else "No waves"
		start_next_button.custom_minimum_size = Vector2(0, 44)
		start_next_button.pressed.connect(_on_start_next_pressed)
		vbox.add_child(start_next_button)
	else:
		var start_button := Button.new()
		start_button.text = "Start Wave"
		start_button.disabled = waves.is_empty()
		start_button.custom_minimum_size = Vector2(0, 44)
		start_button.pressed.connect(_on_start_pressed)
		vbox.add_child(start_button)

func _on_tower_button_input(event: InputEvent, id: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		placing_id = id
		dragging = true
		has_selected = false
		_set_info("Placing %s — drop on a hex, or click a hex." % content.tower(id).display_name)

func _update_labels() -> void:
	money_label.text = "Money: %d" % money
	lives_label.text = "Lives: %d" % lives

func _set_info(text: String) -> void:
	if info_label != null:
		info_label.text = text
