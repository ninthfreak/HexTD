class_name Enemy
extends Node2D
## Travels along pixel waypoints, rotating to face its direction of travel.
## When its health is depleted it either reduces to a smaller form (reduces_to)
## or dies. Drawn from basic shapes; the health bar stays upright.

signal bounty(amount: int)     # money for destroying the current form
signal reached_goal()
signal split(lesser, placements)   # decayed into >1 lesser enemy: spawn the extras

const TURN_RATE := 9.0         # how quickly the body swings to face travel
const SPEED_MULT := 2.0        # global travel-speed multiplier applied to data.speed (JSON values stay as authored)
const ECC_RESIST := 0.9        # ECC enemies block this fraction of damage (0.9 = 90%) unless the tower has Bit Corruption
const GLOW_HDR_BOOST := 0.9    # body brightness = 1 + glow * this; >1.0 is what the HDR glow blooms

var data: EnemyData
var path_points: PackedVector2Array
var health: float
var heading := 0.0             # radians; 0 = facing +X (forward)
var _index := 0
var _alive := true

func setup(d: EnemyData, points: PackedVector2Array) -> void:
	data = d
	path_points = points
	health = d.health
	position = points[0]
	if points.size() > 1:
		heading = (points[1] - points[0]).angle()
	queue_redraw()

# The bloom source draws this (heading-baked, enemy-local) silhouette as the
# glow shape, so the glow takes the enemy's form rather than a circle.
func silhouette() -> PackedVector2Array:
	return _shape_points()

func progress() -> int:
	return _index

func _process(delta: float) -> void:
	if not _alive:
		return
	if _index >= path_points.size() - 1:
		_reach_goal()
		return
	var target := path_points[_index + 1]
	var to_target := target - position
	var dist := to_target.length()
	if dist > 0.001:
		heading = lerp_angle(heading, to_target.angle(), clampf(TURN_RATE * delta, 0.0, 1.0))
	var step := data.speed * SPEED_MULT * delta
	if step >= dist:
		position = target
		_index += 1
	else:
		position += to_target / dist * step
	queue_redraw()

func take_damage(amount: float, pierces_ecc := false, buffer_overflow := false) -> bool:
	# Returns true if this hit depleted the current form (a "kill"), so the laser
	# can trigger its focus_time delay.
	if not _alive:
		return false
	if data.ecc and not pierces_ecc:
		amount *= (1.0 - ECC_RESIST)
	# Buffer Overflow: remember surplus past the target's remaining HP (post-resist).
	var carry := 0.0
	if buffer_overflow and amount > health:
		carry = amount - health
	health -= amount
	if health <= 0.0:
		_on_depleted(carry, pierces_ecc)
		return true
	queue_redraw()
	return false

func _on_depleted(carry := 0.0, pierces_ecc := false) -> void:
	var am = get_node_or_null("/root/AudioManager")
	if am:
		am.play_sfx(data.death_sound)   # blank -> shared default in the manager
	bounty.emit(data.reward)
	var lesser: EnemyData = data.reduces_to
	if lesser == null:
		_alive = false
		queue_free()
		return
	var count: int = maxi(1, data.reduce_count)
	# Buffer Overflow: split the carried surplus evenly across the decay children
	# (floor; remainder discarded). per_child == 0 when there is no overflow.
	var per_child := 0.0
	if carry > 0.0:
		per_child = floor(carry / float(count))
	# remember the dying enemy's spot on the path before morphing
	var parent_index := _index
	var parent_pos := position
	# the first lesser enemy reuses this node at the parent's exact position
	data = lesser
	health = data.health
	queue_redraw()
	# the rest spawn behind, along the path toward spawn, evenly spaced, each carrying overflow
	if count > 1:
		var spacing: float = _radius_estimate() * 2.0 + 6.0
		var placements := []
		for k in range(1, count):
			var res := _walk_back(parent_index, parent_pos, spacing * float(k))
			placements.append({"index": int(res.x), "pos": Vector2(res.y, res.z), "carry": per_child, "pierce": pierces_ecc})
		split.emit(lesser, placements)
	# Spill into this first child too. One-hop: the carried hit does not itself
	# overflow (buffer_overflow arg left false), but a child it kills decays normally.
	if per_child > 0.0:
		take_damage(per_child, pierces_ecc)

# Walk backward (toward spawn) from a point on the path by `back` pixels.
# Returns Vector3(index, pos.x, pos.y) — the segment index and world position.
func _walk_back(seg: int, p: Vector2, back: float) -> Vector3:
	while back > 0.0:
		var behind := path_points[seg]
		var v := behind - p
		var d := v.length()
		if d >= back:
			var np := p + v / maxf(d, 0.0001) * back
			return Vector3(float(seg), np.x, np.y)
		back -= d
		p = behind
		if seg == 0:
			return Vector3(0.0, path_points[0].x, path_points[0].y)
		seg -= 1
	return Vector3(float(seg), p.x, p.y)

# Drop this enemy onto the path at a given segment + world position (mid-path).
func place_on_path(seg: int, pos: Vector2) -> void:
	_index = seg
	position = pos
	if seg + 1 < path_points.size():
		heading = (path_points[seg + 1] - pos).angle()
	queue_redraw()

func _reach_goal() -> void:
	_alive = false
	reached_goal.emit()
	queue_free()

# ---------------------------------------------------------------- drawing
func _shape_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	match data.shape:
		"rect":
			var l := data.length * 0.5
			var w := data.width * 0.5
			pts = PackedVector2Array([Vector2(l, -w), Vector2(l, w), Vector2(-l, w), Vector2(-l, -w)])
		"octagon":
			for i in range(8):
				var a := deg_to_rad(22.5 + 45.0 * i)
				pts.append(Vector2(cos(a), sin(a)) * data.radius)
		"polygon":
			var n: int = maxi(3, data.sides)
			for i in range(n):
				var a := TAU * float(i) / float(n)
				pts.append(Vector2(cos(a), sin(a)) * data.radius)
		_:
			var h := data.side * 0.5
			pts = PackedVector2Array([Vector2(h, -h), Vector2(h, h), Vector2(-h, h), Vector2(-h, -h)])
	# bake the heading into the points so the body turns but the bar stays upright
	var out := PackedVector2Array()
	for p in pts:
		out.append(p.rotated(heading))
	return out

func _radius_estimate() -> float:
	match data.shape:
		"rect":
			return maxf(data.length, data.width) * 0.5
		"octagon", "polygon":
			return data.radius
		_:
			return data.side * 0.5

func _draw() -> void:
	if data == null:
		return
	var pts := _shape_points()
	var fill: Color = data.color
	if data.glow > 0.0:
		# Push the body over 1.0 so the WorldEnvironment's HDR 2D glow blooms it.
		# Brightness above glow_hdr_threshold (1.0) is what blooms; hue is kept.
		var k: float = 1.0 + data.glow * GLOW_HDR_BOOST
		fill = Color(fill.r * k, fill.g * k, fill.b * k, fill.a)
	draw_colored_polygon(pts, fill)
	var outline := pts.duplicate()
	outline.append(pts[0])
	draw_polyline(outline, Color(0, 0, 0, 0.5), 2.0)

	# health bar — axis-aligned, above the body
	var r := _radius_estimate()
	var w: float = maxf(20.0, r * 1.8)
	var frac: float = clampf(health / data.health, 0.0, 1.0)
	var top := Vector2(-w * 0.5, -r - 9.0)
	draw_rect(Rect2(top, Vector2(w, 4.0)), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(top, Vector2(w * frac, 4.0)), Color(0.2, 0.9, 0.3))
