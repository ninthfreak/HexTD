class_name Main
extends Node2D
## Sandbox game scene. Builds the right-hand pane, drives the camera, handles
## tower placement, and spawns waves on demand. There is no win/lose: you start
## whatever waves you like and leave via Exit. Includes a speed toggle and a
## money cheat for development.

# --- tunable game state ---
var money := 200
var lives := 20
var waves: Array = []         # loaded from data/waves.json
var default_gap := 0.7
var cheat_amount := 500

# --- nodes ---
var board: GameBoard
var content: GameContent
var map: HexMapData
var camera: Camera2D
var overlay: BoardOverlay
var badge_tooltip: PanelContainer        # floating tooltip for ability badges
var badge_tooltip_label: Label

# --- placement / selection ---
var placing_id := ""
var dragging := false
var has_selected := false
var selected_cell := Vector2i.ZERO

# --- camera control ---
var pane_width := 300
var panning := false
var min_zoom := 0.4
var max_zoom := 1.6
var pan_speed := 600.0

# --- speed ---
var speed_steps := [1.0, 2.0, 3.0]
var speed_index := 0

# --- wave runtime (absolute-timeline) ---
var _spawn_timeline: Array = []   # sorted {time, type} from WaveLoader.build_timeline
var _wave_clock := 0.0
var _wave_running := false

# --- UI ---
var money_label: Label
var lives_label: Label
var wave_select: OptionButton
var enemy_select: OptionButton          # sandbox: pick an enemy type to spawn
var spawn_count: SpinBox                # sandbox: how many to spawn
var _enemy_ids: Array = []              # parallel to enemy_select item order
var speed_button: Button
var sound_button: Button
var sound_on := true
var target_button: Button
var upgrade_buttons: Array = []   # one per upgrade slot (up to 3)
var sell_button: Button
var info_label: Label

func _ready() -> void:
	Engine.time_scale = 1.0
	content = GameContent.new()
	map = Levels.get_by_path(GameState.selected_path)

	var wc := WaveLoader.load_waves()
	waves = wc.get("waves", [])
	default_gap = float(wc.get("spawn_interval_default", 0.7))

	board = GameBoard.new()
	add_child(board)
	board.setup(map)

	camera = Camera2D.new()
	board.add_child(camera)
	camera.make_current()

	overlay = BoardOverlay.new()
	overlay.board = board
	board.add_child(overlay)

	var world_env := WorldEnvironment.new()
	world_env.environment = load("res://glow_env.tres")
	add_child(world_env)

	_frame_camera()
	_build_ui()
	_update_labels()
	_set_info("Sandbox: start any wave, build towers, leave with Exit.")

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
	_camera_keys(delta)
	_update_preview()

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
		# divide out time_scale so panning feels the same at 2x / 3x
		var dt := delta / maxf(Engine.time_scale, 0.0001)
		camera.position += dir.normalized() * pan_speed * dt / camera.zoom.x

func _update_preview() -> void:
	if placing_id == "" or _mouse_over_pane():
		overlay.preview_active = false
	else:
		var cell := board.world_cell(get_global_mouse_position())
		if board.has_cell(cell):
			var td := content.tower(placing_id)
			overlay.preview_active = true
			overlay.preview_cell = cell
			overlay.preview_range = board.tower_reach(td.range_tiles)
			overlay.preview_valid = board.is_buildable(cell) and money >= td.cost
			overlay.preview_color = td.color
			overlay.preview_mode = td.fire_mode
			overlay.preview_dirs = td.directions
		else:
			overlay.preview_active = false
	overlay.selected_active = has_selected
	overlay.selected_cell = selected_cell
	overlay.selected_range = (board.tower_reach(board.tower_at(selected_cell).data.range_tiles) if has_selected and board.tower_at(selected_cell) != null else 0)
	var sel_t = board.tower_at(selected_cell) if has_selected else null
	overlay.badge_icons = _tower_ability_icons(sel_t) if sel_t != null else []
	if sel_t != null:
		overlay.selected_color = sel_t.data.color
	overlay.queue_redraw()
	_update_target_button()
	_update_tower_buttons()
	_update_badge_tooltip()

# Which ability badges a tower should show, from its effective (upgraded) stats.
func _tower_ability_icons(t) -> Array:
	var out := []
	if t.data.cipher:
		out.append("cipher")
	if t.data.bit_corruption:
		out.append("bit_corruption")
	if t.data.ignore_walls:
		out.append("tunneling")
	return out

func _ability_text(icon: String) -> String:
	match icon:
		"cipher":
			return "Cipher\nSees and targets encrypted enemies."
		"bit_corruption":
			return "Bit corruption\nBypasses ECC damage resistance."
		"tunneling":
			return "Tunneling\nShots pass through walls."
		_:
			return ""

# Show a tooltip when the cursor is over one of the selected tower's badges.
func _update_badge_tooltip() -> void:
	if badge_tooltip == null:
		return
	if not has_selected or _mouse_over_pane():
		badge_tooltip.visible = false
		return
	var mw := get_global_mouse_position()
	var hit := ""
	for b in overlay.badge_layout():
		if mw.distance_to(b["center"]) <= overlay.BADGE_R:
			hit = str(b["icon"])
			break
	if hit == "":
		badge_tooltip.visible = false
		return
	badge_tooltip_label.text = _ability_text(hit)
	badge_tooltip.visible = true
	badge_tooltip.position = get_viewport().get_mouse_position() + Vector2(16, 16)

func _update_target_button() -> void:
	if not has_selected:
		target_button.visible = false
		return
	var t = board.tower_at(selected_cell)
	if t == null or t.data.fire_mode == "radial":
		target_button.visible = false   # radial fires every direction; no single target
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
			b.text = "%s \u2192 Tier %d  ($%d)" % [t.slot_name(s), t.slot_level(s) + 1, c]
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
			_zoom_by(1.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_by(1.0 / 1.1)
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and dragging:
			_finish_drag()
	elif event is InputEventMouseMotion and panning:
		camera.position -= event.relative / camera.zoom.x

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
	var cell := board.world_cell(get_global_mouse_position())
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
	var cell := board.world_cell(get_global_mouse_position())
	if not _mouse_over_pane() and board.has_cell(cell) and board.is_buildable(cell):
		if _try_place(cell):
			placing_id = ""

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
	var t := Tower.new()
	t.cell = cell
	t.setup(td, board, board.cell_center_world(cell))
	board.place_tower(cell, t)
	_update_labels()
	return true

func _select_tower(cell: Vector2i, t) -> void:
	has_selected = true
	selected_cell = t.cell        # the tower's center, so range centers correctly
	_set_info("%s selected — range shown." % t.data.display_name)

func _cancel() -> void:
	placing_id = ""
	dragging = false
	has_selected = false

# ---------------------------------------------------------------- waves
# Sandbox: instantly drop N of the chosen enemy onto the path, spaced out.
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
		var e := Enemy.new()
		e.bounty.connect(_on_enemy_bounty)
		e.reached_goal.connect(_on_enemy_reached_goal)
		e.split.connect(_on_enemy_split)
		e.setup(ed, points)
		e.place_on_path(int(place["index"]), place["pos"])
		board.add_enemy(e)
	_set_info("Spawned %d %s." % [n, ed.display_name])

# Position a given distance forward along the path from the start.
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
		"octagon", "polygon":
			return ed.radius
		_:
			return ed.side * 0.5

func _spawn_enemy(type_id: String) -> void:
	var ed = content.enemy(type_id)
	if ed == null:
		push_warning("Unknown enemy type in wave: " + type_id)
		return
	var e := Enemy.new()
	e.bounty.connect(_on_enemy_bounty)
	e.reached_goal.connect(_on_enemy_reached_goal)
	e.split.connect(_on_enemy_split)
	e.setup(ed, board.get_path_points())
	board.add_enemy(e)

# A decaying enemy asked for extra lesser copies placed behind it on the path.
func _on_enemy_split(lesser, placements: Array) -> void:
	for pl in placements:
		var e := Enemy.new()
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
	wave_select.selected = (wi + 1) % waves.size()
	_set_info("Started wave %s." % wname)

func _on_enemy_bounty(amount: int) -> void:
	money += amount
	_update_labels()

func _on_enemy_reached_goal() -> void:
	lives = maxi(0, lives - 1)
	_update_labels()

# ---------------------------------------------------------------- sandbox controls
func _on_speed_pressed() -> void:
	speed_index = (speed_index + 1) % speed_steps.size()
	Engine.time_scale = speed_steps[speed_index]
	speed_button.text = "Speed: %dx" % int(speed_steps[speed_index])

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

# ---------------------------------------------------------------- camera setup
func _frame_camera() -> void:
	var b := board.get_bounds()
	var view: Vector2 = get_viewport().get_visible_rect().size
	var play_w: float = view.x - pane_width
	var play_h: float = view.y
	var zx := play_w / maxf(b.size.x + 120.0, 1.0)
	var zy := play_h / maxf(b.size.y + 120.0, 1.0)
	var z := clampf(minf(zx, zy), min_zoom, max_zoom)
	camera.zoom = Vector2(z, z)
	var center := b.position + b.size * 0.5
	camera.position = Vector2(center.x + (pane_width * 0.5) / z, center.y)

func _zoom_by(factor: float) -> void:
	var z := clampf(camera.zoom.x * factor, min_zoom, max_zoom)
	camera.zoom = Vector2(z, z)

func _mouse_over_pane() -> bool:
	var mx := get_viewport().get_mouse_position().x
	return mx > get_viewport().get_visible_rect().size.x - pane_width

# ---------------------------------------------------------------- UI
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 2          # above the bloom layer (1) so the pane isn't bloomed
	add_child(layer)

	var tip_layer := CanvasLayer.new()
	tip_layer.layer = 50     # tooltips float above everything
	add_child(tip_layer)
	badge_tooltip = PanelContainer.new()
	badge_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_tooltip.visible = false
	var tip_sb := StyleBoxFlat.new()
	tip_sb.bg_color = Color(0.06, 0.08, 0.11, 0.96)
	tip_sb.set_corner_radius_all(4)
	tip_sb.set_content_margin_all(8)
	tip_sb.border_color = Color(1, 1, 1, 0.25)
	tip_sb.set_border_width_all(1)
	badge_tooltip.add_theme_stylebox_override("panel", tip_sb)
	badge_tooltip_label = Label.new()
	badge_tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_tooltip_label.add_theme_color_override("font_color", Color(1, 1, 1))
	badge_tooltip.add_child(badge_tooltip_label)
	tip_layer.add_child(badge_tooltip)

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
	title.text = "HEX TD — SANDBOX"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var map_label := Label.new()
	map_label.text = map.display_name
	map_label.modulate = Color(1, 1, 1, 0.6)
	vbox.add_child(map_label)

	money_label = Label.new()
	lives_label = Label.new()
	vbox.add_child(money_label)
	vbox.add_child(lives_label)

	vbox.add_child(HSeparator.new())

	var wave_header := Label.new()
	wave_header.text = "Start wave"
	vbox.add_child(wave_header)

	wave_select = OptionButton.new()
	wave_select.clip_text = true
	for i in range(waves.size()):
		var w: Dictionary = waves[i]
		var wname: String = WaveLoader.wave_name(w, i)
		wave_select.add_item(wname)
	if waves.size() > 0:
		wave_select.selected = 0
	vbox.add_child(wave_select)

	var start_button := Button.new()
	start_button.text = "Start Wave"
	start_button.disabled = waves.is_empty()
	start_button.pressed.connect(_on_start_pressed)
	vbox.add_child(start_button)

	var spawn_header := Label.new()
	spawn_header.text = "Spawn enemies"
	vbox.add_child(spawn_header)

	enemy_select = OptionButton.new()
	_enemy_ids = content.enemy_ids()
	for id in _enemy_ids:
		enemy_select.add_item(content.enemy(str(id)).display_name)
	if _enemy_ids.size() > 0:
		enemy_select.selected = 0
	vbox.add_child(enemy_select)

	var count_row := HBoxContainer.new()
	var count_label := Label.new()
	count_label.text = "Count"
	count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	count_row.add_child(count_label)
	spawn_count = SpinBox.new()
	spawn_count.min_value = 1
	spawn_count.max_value = 100
	spawn_count.step = 1
	spawn_count.value = 5
	count_row.add_child(spawn_count)
	vbox.add_child(count_row)

	var spawn_button := Button.new()
	spawn_button.text = "Spawn"
	spawn_button.disabled = _enemy_ids.is_empty()
	spawn_button.pressed.connect(_on_spawn_pressed)
	vbox.add_child(spawn_button)

	speed_button = Button.new()
	speed_button.text = "Speed: 1x"
	speed_button.pressed.connect(_on_speed_pressed)
	vbox.add_child(speed_button)

	sound_button = Button.new()
	sound_button.text = "Sound: On"
	sound_button.pressed.connect(_on_sound_pressed)
	vbox.add_child(sound_button)

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
