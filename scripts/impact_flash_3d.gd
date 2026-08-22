class_name ImpactFlash3D
extends Node3D
## One-shot impact burst: a small unshaded low-poly octahedron in the hit
## colour that flares (scale up + emission spike) and dissolves in ~0.12s,
## then retires itself — back to the board's node pool when there is one, freed
## otherwise. Projectiles spawn it at the contact point as a sibling on the board
## so it outlives the shot that spawned it. Bursts are capped per frame
## (MAX_SPAWNS_PER_FRAME): on a mass-kill frame the surplus is simply not drawn.

const LIFE := 0.12
const START_SCALE := 0.6
const END_SCALE := 2.4
const BURST_ENERGY := 3.0      # starting emission — well over bloom threshold for a free flash
const POOL_KEY := &"impact_flash3d"   # private to this class: a take can only return an ImpactFlash3D
# Cosmetic budget for a mass-kill frame: past this many bursts in one process
# frame the rest are skipped outright. Deliberate trade-off — a frame that kills
# 60 enemies shows 16 flashes. Damage, hit sets, targeting and audio never read
# this counter, so skipping a burst changes nothing but the picture.
const MAX_SPAWNS_PER_FRAME := 16

static var _burst_mesh: ArrayMesh   # shared unit geometry (colour lives in the material)

# Shared material cache: the recipe below is deterministic per colour and never
# animated (the fade rides the per-instance `transparency` property), so every
# flash of a colour reuses one material.
static var _mat_cache := {}    # rgba32 -> StandardMaterial3D

static var _spawn_frame := -1  # process frame the counter below belongs to
static var _spawn_count := 0   # bursts spawned so far this frame (see MAX_SPAWNS_PER_FRAME)
# Last (parent -> board) pair resolved by _resolve_board: every caller passes the
# same board-owned entities node, so the walk runs once and then hits this cache.
# Untyped on purpose — pool_take/pool_put are not Node methods, so a typed
# reference to the board would not compile.
static var _pool_parent = null
static var _pool_board = null

var _mi: MeshInstance3D
var _t := 0.0
var _start_scale := START_SCALE
var _end_scale := END_SCALE
# Board this flash was taken from, or null when none was found (then the flash
# keeps the plain queue_free lifetime). Set by spawn().
var _board
var _dead := false             # released already — makes a double release impossible

# Colour, place and parent a flash in one call — a parked one when the pool has
# it, a fresh one otherwise. Pooling is internal: the signature and the visual
# envelope are unchanged. Over the per-frame cap the call is a no-op.
# `size` scales the whole burst (1.0 for the standard hit; larger for e.g. the
# wall-blocked spark).
static func spawn(parent: Node, at: Vector3, color: Color, size := 1.0) -> void:
	if parent == null:
		return
	var frame: int = Engine.get_process_frames()
	if frame != _spawn_frame:
		_spawn_frame = frame
		_spawn_count = 0
	if _spawn_count >= MAX_SPAWNS_PER_FRAME:
		return
	_spawn_count += 1
	var b = _resolve_board(parent)
	var f: ImpactFlash3D = null
	if b != null:
		var n: Node = b.pool_take(POOL_KEY)
		if n is ImpactFlash3D:
			f = n
		elif n != null:
			n.queue_free()   # wrong class under our key: drop it rather than orphan it
	if f == null:
		f = ImpactFlash3D.new()
	f._board = b
	# Per-life reset, every field a burst writes: _board, _t, _dead, _start_scale,
	# _end_scale, node transform / visibility / processing, mesh material /
	# transparency / visibility. Add new fields here when adding them above.
	f._ensure_mesh()
	f._mi.material_override = _shared_mat(color)
	f._mi.transparency = 0.0
	f._mi.visible = true
	f._t = 0.0
	f._dead = false
	f._start_scale = START_SCALE * size
	f._end_scale = END_SCALE * size
	f.visible = true
	f.set_process(true)
	f.transform = Transform3D.IDENTITY
	f.scale = Vector3.ONE * f._start_scale
	f.position = at
	parent.add_child(f)

# The board owning `parent`, or null if the flash is parented outside a board
# (then it just frees itself as before). Walks up at most a couple of levels and
# only on the first call for a given parent.
static func _resolve_board(parent: Node):
	if _pool_parent != null and is_instance_valid(_pool_parent) and parent == _pool_parent \
			and _pool_board != null and is_instance_valid(_pool_board):
		return _pool_board
	var n: Node = parent
	while n != null:
		if n.has_method(&"pool_take") and n.has_method(&"pool_put"):
			_pool_parent = parent
			_pool_board = n
			return n
		n = n.get_parent()
	_pool_parent = null
	_pool_board = null
	return null

# One-time mesh child: a pooled flash keeps the one it built on its first life.
# Per-burst mesh state is set by spawn(), not here.
func _ensure_mesh() -> void:
	if _mi != null and is_instance_valid(_mi):
		return
	_mi = MeshInstance3D.new()
	_mi.mesh = unit_octahedron()
	add_child(_mi)

static func _shared_mat(c: Color) -> StandardMaterial3D:
	var key := c.to_rgba32()
	var cached: StandardMaterial3D = _mat_cache.get(key)
	if cached != null:
		return cached
	var mat := StandardMaterial3D.new()
	var bright: Color = c.lightened(0.3)
	mat.albedo_color = bright
	mat.emission_enabled = true
	mat.emission = bright
	# The burst energy is baked in; the per-instance transparency fade carries
	# the whole dissolve (near-identical to the old parallel energy+alpha tween).
	mat.emission_energy_multiplier = BURST_ENERGY
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache[key] = mat
	return mat

func _ready() -> void:
	if _mi == null:             # only spawn() builds the mesh; bail if built by hand
		queue_free()

# Same envelope the old per-flash Tween ran (0.12s, cubic ease-out, scale up +
# fade out), as a tiny in-node _process — no Tween/material allocations per hit.
func _process(delta: float) -> void:
	if _mi == null:
		return
	_t += delta
	if _t >= LIFE:
		_release()
		return
	var u: float = _t / LIFE
	var k: float = 1.0 - pow(1.0 - u, 3.0)   # TRANS_CUBIC / EASE_OUT
	scale = Vector3.ONE * lerpf(_start_scale, _end_scale, k)
	_mi.transparency = k

# Death path. Parking instead of freeing is safe because a flash is fire-and-
# forget: spawn() returns nothing, so no caller can hold a reference, it is in no
# list, and no signal is connected to it. The dissolve is undone here as well as
# in spawn() so a parked flash never sits at transparency 1.0. After pool_put the
# node is out of the tree and not processing — callers must return immediately.
func _release() -> void:
	if _dead:
		return
	_dead = true
	if _mi != null and is_instance_valid(_mi):
		_mi.transparency = 0.0
	var b = _board
	_board = null
	if b != null and is_instance_valid(b):
		b.pool_put(POOL_KEY, self)
	else:
		queue_free()

# Shared unit octahedron (half-extent 1). Materials here are unshaded and
# cull-disabled, so winding is irrelevant and no normals are needed.
static func unit_octahedron() -> ArrayMesh:
	if _burst_mesh != null:
		return _burst_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var xp := Vector3.RIGHT; var xn := Vector3.LEFT
	var yp := Vector3.UP; var yn := Vector3.DOWN
	var zp := Vector3.BACK; var zn := Vector3.FORWARD
	for face in [[xp, yp, zp], [zp, yp, xn], [xn, yp, zn], [zn, yp, xp],
			[yn, zp, xp], [yn, xn, zp], [yn, zn, xn], [yn, xp, zn]]:
		for v in face:
			st.add_vertex(v)
	_burst_mesh = st.commit()
	return _burst_mesh
