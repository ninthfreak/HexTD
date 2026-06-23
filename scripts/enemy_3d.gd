class_name Enemy3D
extends Node3D
## 3D enemy. All path / damage / split logic is ported verbatim from the 2D
## Enemy, operating on `pp` (plane position, Vector2). The 3D transform is
## synced from `pp` for display only. Body is an extruded prism rotated to face
## travel; the health bar above it is a billboarded Sprite3D so it always
## reads upright regardless of body yaw or camera tilt.

signal bounty(amount: int)
signal reached_goal()
signal split(lesser, placements)

const TURN_RATE := 9.0
const ECC_RESIST := 0.9
const GLOW_HDR_BOOST := 0.9
const BODY_HEIGHT := 4.0
const BAR_PIX_W := 40
const BAR_PIX_H := 6
const BAR_PIXEL_SIZE := 0.18    # world units per bar texel
const BAR_HEIGHT_PAD := 3.0     # bar sits above the body's top by this many units

var data: EnemyData
var path_points: PackedVector2Array
var health: float
var heading := 0.0             # radians; 0 = facing +X in plane space
var pp := Vector2.ZERO
var _index := 0
var _alive := true
var _body_root: Node3D         # rotates with heading (body only — bar stays upright)
var _body: MeshInstance3D
var _bar: Sprite3D
var _bar_tex: ImageTexture

func setup(d: EnemyData, points: PackedVector2Array) -> void:
	data = d
	path_points = points
	health = d.health
	pp = points[0]
	if points.size() > 1:
		heading = (points[1] - points[0]).angle()
	_build_visuals()
	_sync_transform()
	_refresh_bar_texture(1.0)

func silhouette() -> PackedVector2Array:
	return _shape_points()

func progress() -> int:
	return _index

# --------------------------------------------------------------- mesh
func _build_visuals() -> void:
	_body_root = Node3D.new()
	add_child(_body_root)
	_body = MeshInstance3D.new()
	_body.mesh = _build_body_mesh()
	_body.material_override = _body_material()
	_body_root.add_child(_body)
	_bar = Sprite3D.new()
	_bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_bar.shaded = false
	_bar.pixel_size = BAR_PIXEL_SIZE / float(BAR_PIX_H)
	_bar.position = Vector3(0, BODY_HEIGHT + BAR_HEIGHT_PAD, 0)
	add_child(_bar)

func _body_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var fill: Color = data.color
	mat.albedo_color = fill
	mat.metallic = 0.0
	mat.roughness = 0.55
	if data.glow > 0.0:
		# >1 emission energy is what the WorldEnvironment bloom blooms.
		mat.emission_enabled = true
		mat.emission = fill
		mat.emission_energy_multiplier = 1.0 + data.glow * GLOW_HDR_BOOST
	return mat

# Extrude the 2D silhouette into a prism. Winding mirrors GameBoard3D._add_prism
# (top cap + outward side walls). SurfaceTool.generate_normals fills the rest.
func _build_body_mesh() -> ArrayMesh:
	var pts := _local_shape_points()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_emit_prism(st, pts, BODY_HEIGHT, 0.0)
	st.generate_normals()
	return st.commit()

func _emit_prism(st: SurfaceTool, poly: PackedVector2Array, top: float, bottom: float) -> void:
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= float(poly.size())
	var n := poly.size()
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		# top cap (fan from center). (center, b, a) so the cap faces +Y up under
		# the (x,y)->(x,0,y) handedness flip; see GameBoard3D._add_cap.
		st.add_vertex(Vector3(center.x, top, center.y))
		st.add_vertex(Vector3(b.x, top, b.y))
		st.add_vertex(Vector3(a.x, top, a.y))
		# side walls (two tris per quad), wound to face outward
		var at := Vector3(a.x, top, a.y)
		var bt := Vector3(b.x, top, b.y)
		var ab := Vector3(a.x, bottom, a.y)
		var bb := Vector3(b.x, bottom, b.y)
		st.add_vertex(at); st.add_vertex(bb); st.add_vertex(ab)
		st.add_vertex(at); st.add_vertex(bt); st.add_vertex(bb)

# Local (un-rotated) shape, in plane coords. Heading is applied via _body_root yaw.
func _local_shape_points() -> PackedVector2Array:
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
	return pts

# Heading-baked points (kept so radial_projectile_3d / overlays can ask for a
# rotated silhouette the same way the 2D enemy exposed it).
func _shape_points() -> PackedVector2Array:
	var local := _local_shape_points()
	var out := PackedVector2Array()
	for p in local:
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

# --------------------------------------------------------------- transform sync
# Plane heading: 0 = facing +X. World rotation around Y: world basis maps plane
# +X -> world +X, plane +Y -> world +Z. A 2D rotation by `heading` corresponds
# to a world rotation around Y by `-heading` (handedness flips because Y is up).
func _sync_transform() -> void:
	position = Vector3(pp.x, GameBoard3D.COPPER_TOP, pp.y)
	_body_root.rotation = Vector3(0.0, -heading, 0.0)

# --------------------------------------------------------------- per-frame
func _process(delta: float) -> void:
	if not _alive:
		return
	if _index >= path_points.size() - 1:
		_reach_goal()
		return
	var target := path_points[_index + 1]
	var to_target := target - pp
	var dist := to_target.length()
	if dist > 0.001:
		heading = lerp_angle(heading, to_target.angle(), clampf(TURN_RATE * delta, 0.0, 1.0))
	var step := data.speed * delta
	if step >= dist:
		pp = target
		_index += 1
	else:
		pp += to_target / dist * step
	_sync_transform()

# --------------------------------------------------------------- damage / reduction
func take_damage(amount: float, pierces_ecc := false) -> void:
	if not _alive:
		return
	if data.ecc and not pierces_ecc:
		amount *= (1.0 - ECC_RESIST)
	health -= amount
	if health <= 0.0:
		_on_depleted()
	else:
		_refresh_bar_texture(health / data.health)

func _on_depleted() -> void:
	var am = get_node_or_null("/root/AudioManager")
	if am:
		am.play_sfx(data.death_sound)
	bounty.emit(data.reward)
	var lesser: EnemyData = data.reduces_to
	if lesser == null:
		_alive = false
		queue_free()
		return
	var count: int = maxi(1, data.reduce_count)
	var parent_index := _index
	var parent_pos := pp
	# morph this node into the lesser form
	data = lesser
	health = data.health
	_body.mesh = _build_body_mesh()
	_body.material_override = _body_material()
	_refresh_bar_texture(1.0)
	if count <= 1:
		return
	# the rest spawn along the path behind us, evenly spaced
	var spacing: float = _radius_estimate() * 2.0 + 6.0
	var placements := []
	for k in range(1, count):
		var res := _walk_back(parent_index, parent_pos, spacing * float(k))
		placements.append({"index": int(res.x), "pos": Vector2(res.y, res.z)})
	split.emit(lesser, placements)

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

func place_on_path(seg: int, pos: Vector2) -> void:
	_index = seg
	pp = pos
	if seg + 1 < path_points.size():
		heading = (path_points[seg + 1] - pos).angle()
	_sync_transform()

func _reach_goal() -> void:
	_alive = false
	reached_goal.emit()
	queue_free()

# --------------------------------------------------------------- health bar
# A tiny billboarded sprite. Cheap to redraw — only happens when health changes
# (or on setup/morph), not every frame.
func _refresh_bar_texture(frac: float) -> void:
	var img := Image.create(BAR_PIX_W, BAR_PIX_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0.6))
	var fill: int = maxi(0, int(round(float(BAR_PIX_W) * clampf(frac, 0.0, 1.0))))
	if fill > 0:
		img.fill_rect(Rect2i(0, 0, fill, BAR_PIX_H), Color(0.2, 0.9, 0.3))
	if _bar_tex == null:
		_bar_tex = ImageTexture.create_from_image(img)
		_bar.texture = _bar_tex
	else:
		_bar_tex.update(img)
