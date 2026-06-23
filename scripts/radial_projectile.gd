class_name RadialProjectile
extends Node2D
## Straight-line, non-homing shot used by radial towers. Flies in a fixed
## direction, passes through enemies (damaging each at most once), and dies
## when it reaches the edge of the tower's range.

var board                    # GameBoard (untyped to avoid a dependency cycle)
var dir := Vector2.RIGHT
var speed := 320.0
var damage := 10.0
var origin_cell := Vector2i.ZERO
var range_tiles := 3
var col := Color(1, 1, 1)
var ignore_walls := false     # when false, a block wall stops the shot

const GLOW := 1.7             # over-bright factor: >1.0 is what the HDR glow blooms
var pierces_ecc := false      # tower had Bit Corruption
var can_see_encrypted := false # tower had Cipher
var _safety := 0.0            # hard pixel cap so a stray shot can't live forever
var _hit := {}               # enemy -> true, so each enemy is hit once per shot

const HIT_PAD := 8.0         # projectile radius added to the enemy's radius

func setup(start: Vector2, direction: Vector2, dmg: float, spd: float, origin: Vector2i, tiles: int, c: Color, b) -> void:
	position = start
	dir = direction.normalized()
	damage = dmg
	speed = spd
	origin_cell = origin
	range_tiles = tiles
	col = c
	board = b
	_safety = float(tiles + 1) * 2.0 * b.HEX_SIZE
	queue_redraw()

func _process(delta: float) -> void:
	var step := speed * delta
	position += dir * step
	_safety -= step
	if board != null:
		var here: Vector2i = board.world_cell(position)
		# Die at the edge of the tower's view: out of hex range, off the board,
		# or (unless allowed) blocked by a wall.
		if HexUtils.axial_distance(origin_cell, here) > range_tiles \
				or not board.has_cell(here) \
				or (not ignore_walls and board.blocking_set.has(here)):
			queue_free()
			return
	_check_hits()
	if _safety <= 0.0:
		queue_free()
	else:
		queue_redraw()

func _check_hits() -> void:
	if board == null:
		return
	var am = get_node_or_null("/root/AudioManager")
	for e in board.enemies.duplicate():
		if not is_instance_valid(e) or _hit.has(e):
			continue
		if e.data.encrypted and not can_see_encrypted:
			continue   # invisible to this tower
		var r := HIT_PAD
		if e.has_method("_radius_estimate"):
			r += e._radius_estimate()
		if position.distance_to(e.position) <= r:
			_hit[e] = true
			e.take_damage(damage, pierces_ecc)
			if am:
				am.play_sfx("projectile_hit")

func _draw() -> void:
	# over-bright so the HDR 2D glow blooms the shot (values >1.0 bloom)
	var c: Color = col.lightened(0.3)
	draw_circle(Vector2.ZERO, 7.0, Color(c.r * GLOW, c.g * GLOW, c.b * GLOW, c.a))
	draw_circle(Vector2.ZERO, 3.6, Color(GLOW, GLOW, GLOW))
