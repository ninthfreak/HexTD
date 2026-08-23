class_name EnemyCrowdField
extends MultiMeshInstance3D
## Every reduced-tier enemy body of ONE enemy type, as a single MultiMesh draw call.
##
## At 400 enemies the crowd rule buries nearly the whole wave in the reduced LOD
## tier, where each body is the SAME faces-only mesh with the SAME per-type
## material — several hundred draw calls that differ only by transform and three
## per-enemy floats. Here that becomes one instance each: the per-frame draw drops
## to roughly one call per distinct enemy type.
##
## A MultiMesh carries one mesh and one material, so there is one field per enemy
## TYPE KEY (Enemy3D._type_key(), which folds every input both the geometry and the
## material read). Fields are siblings of the enemies under the board's entity
## holder, so an instance transform is written in the same space the enemies' own
## `position` lives in.
##
## This is VISUAL ONLY. Nothing here is read by targeting, and an owner's pp /
## cell / health / lifecycle never passes through this file.
##
## Instances stay PACKED: slot i belongs to _nodes[i] and a release swap-removes
## the tail into the hole, so visible_instance_count is always exactly the number
## of live crowd bodies. Owners keep their own slot and are told when a
## swap-remove moves them (owner.set_crowd_slot).
##
## OWNER CONTRACT
##   var slot := EnemyCrowdField.for_type(parent, key, mesh, mat).acquire(self, x, f, k, p)
##   field.set_instance(slot, xform, flash, frost, scan_phase)   # every frame
##   field.release(slot)                    # leaving the tier, morphing, dying
##   func set_crowd_slot(i: int) -> void    # the owner MUST accept a slot move
## Unlike the health bars, owners PUSH their transform (composed from pp, so no
## transform sync is forced); this node only uploads what they wrote.

# One field per (parent, type key), found by name — a scene reload gets a new
# parent and therefore new fields, and nothing outlives the board that holds it.
# The name carries a hash of the key, since a type key holds characters a node
# name may not; a collision is stepped past rather than trusted (see for_type).
const FIELD_PREFIX := "EnemyCrowdField_"
# Instance capacity grows in blocks: reallocating a MultiMesh zeroes the
# server-side buffer, so each growth costs a full re-upload. Crowds are large, so
# the block is bigger than the bar field's.
const CAPACITY_STEP := 64

# MultiMesh 3D buffer layout, per instance: a row-major 3x4 transform (basis row
# i = the three basis COLUMN components i, then origin component i), no colour
# (use_colors stays false), then 4 custom-data floats.
const STRIDE := 16
const _CUSTOM := 12     # custom_data.x = flash, .y = frost, .z = scan_phase, .w unused

# Enemy3D._type_key() of the bodies in this field. Kept so a name-hash collision
# between two live types is detected instead of silently merging them.
var type_key := ""

var _mm: MultiMesh
# Untyped on purpose: the swap-remove has to call the owner's set_crowd_slot,
# which Node3D has no static knowledge of.
var _nodes: Array = []
var _buf := PackedFloat32Array()       # shadow copy of the whole MultiMesh buffer
var _capacity := 0
# Frame of the last upload. An acquire/release landing AFTER this frame's flush
# has to re-upload, or a swap-removed body ghosts for a frame.
var _flushed_frame := -1

static var _fields: Dictionary = {}    # type key -> field (validated on every lookup)

# The field serving `key` under `parent` (the enemies' own parent — the board's
# entity holder), created on the first body of that type to enter the tier.
# Lookup is by child name so the field is an ordinary node with an ordinary
# lifetime: it is freed with the board and cannot leak into the next scene.
static func for_type(parent: Node, key: String, mesh: Mesh, mat: Material) -> EnemyCrowdField:
	if parent == null or mesh == null:
		return null
	var cached: EnemyCrowdField = _fields.get(key)
	if cached != null and is_instance_valid(cached) and cached.get_parent() == parent:
		return cached
	_fields.erase(key)
	var base: String = FIELD_PREFIX + str(key.hash())
	var nm: String = base
	for i in range(8):
		var found := parent.get_node_or_null(NodePath(nm)) as EnemyCrowdField
		if found == null:
			break
		if found.type_key == key:
			_fields[key] = found
			return found
		nm = "%s_%d" % [base, i + 1]   # different type, same name hash: step past it
	var made := EnemyCrowdField.new()
	made.name = nm
	made.type_key = key
	made._setup(mesh, mat)
	parent.add_child(made)
	_fields[key] = made
	return made

# Built before the node enters the tree: for_type() returns to a caller that
# acquires an instance immediately, before this node has ticked once.
func _setup(mesh: Mesh, mat: Material) -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true      # must precede instance_count (it allocates)
	_mm.instance_count = 0
	_mm.visible_instance_count = 0
	_mm.mesh = mesh
	multimesh = _mm
	material_override = mat
	# Enemy bodies do not cast — see Enemy3D.ENEMY_CASTS_SHADOW, which this tier
	# must match or a reduced enemy would gain a shadow the full one never had.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Uploaded from data the enemies have already written this frame.
	process_priority = 100

func _ready() -> void:
	set_process(not _nodes.is_empty())

# ---------------------------------------------------------------- owner API
# Claim an instance for `node`, seeded with the state it is drawn from. Returns
# the slot the owner keeps and hands back to set_instance / release; a later
# swap-remove reaches the owner through set_crowd_slot.
func acquire(node: Node3D, xform: Transform3D, flash: float, frost: float, scan_phase: float) -> int:
	var slot: int = _nodes.size()
	_nodes.append(node)
	var grew := _ensure_capacity(slot + 1)
	set_instance(slot, xform, flash, frost, scan_phase)
	# Owners all process ahead of this node (priority 100), so an ordinary acquire
	# is picked up by this frame's flush and the new slot — which sits beyond the
	# visible count until then — can never draw stale data. Two cases still need
	# the upload now: a capacity change zeroed the server buffer under every slot
	# that IS visible, and re-arming an idle field enables _process too late for it
	# to run this frame, which would blink the owner out for one.
	if grew or slot == 0:
		_flush()
	set_process(true)
	return slot

# Transform + the three per-enemy shader values, pushed by the owner every frame.
# Picked up by this frame's flush, which runs after every enemy has moved.
func set_instance(slot: int, xform: Transform3D, flash: float, frost: float, scan_phase: float) -> void:
	if slot < 0 or slot >= _nodes.size():
		return
	var b: int = slot * STRIDE
	var bx: Vector3 = xform.basis.x
	var by: Vector3 = xform.basis.y
	var bz: Vector3 = xform.basis.z
	var o: Vector3 = xform.origin
	_buf[b] = bx.x; _buf[b + 1] = by.x; _buf[b + 2] = bz.x; _buf[b + 3] = o.x
	_buf[b + 4] = bx.y; _buf[b + 5] = by.y; _buf[b + 6] = bz.y; _buf[b + 7] = o.y
	_buf[b + 8] = bx.z; _buf[b + 9] = by.z; _buf[b + 10] = bz.z; _buf[b + 11] = o.z
	_buf[b + _CUSTOM] = flash
	_buf[b + _CUSTOM + 1] = frost
	_buf[b + _CUSTOM + 2] = scan_phase

func release(slot: int) -> void:
	_drop(slot)
	if _nodes.is_empty():
		_mm.visible_instance_count = 0
		_flushed_frame = -1
		set_process(false)
		return
	# The tail moved into the hole. If this frame's upload already happened, the
	# server still holds the released body at its old spot — re-upload rather than
	# let it ghost for a frame.
	if _flushed_frame == Engine.get_process_frames():
		_flush()

# ---------------------------------------------------------------- per frame
func _process(_delta: float) -> void:
	var i := 0
	while i < _nodes.size():
		var ref = _nodes[i]        # untyped: may be a previously freed owner
		if not is_instance_valid(ref):
			_drop(i)               # owner freed without releasing — reclaim the slot
			continue               # the tail landed on i; test it before moving on
		i += 1
	if _nodes.is_empty():
		_mm.visible_instance_count = 0
		_flushed_frame = -1
		set_process(false)
		return
	_trim_capacity()
	_flush()

# ---------------------------------------------------------------- internals
# One upload for the whole field. visible_instance_count trails the buffer, so
# the GPU never reads a slot the CPU has not written.
func _flush() -> void:
	if _capacity == 0:
		return
	_mm.buffer = _buf
	_mm.visible_instance_count = _nodes.size()
	_flushed_frame = Engine.get_process_frames()

# Swap-remove `slot`: the tail instance moves into the hole (and its owner is
# told), keeping the live range packed at [0, size).
func _drop(slot: int) -> void:
	var last: int = _nodes.size() - 1
	if slot < 0 or slot > last:
		return
	if slot != last:
		_nodes[slot] = _nodes[last]
		var src: int = last * STRIDE
		var dst: int = slot * STRIDE
		for k in range(STRIDE):
			_buf[dst + k] = _buf[src + k]
		var moved = _nodes[slot]   # untyped: set_crowd_slot is the owner's, not Node3D's
		if is_instance_valid(moved):
			moved.set_crowd_slot(slot)
	_nodes.remove_at(last)

# True when capacity actually changed (and the server buffer was therefore zeroed).
func _ensure_capacity(n: int) -> bool:
	if n <= _capacity:
		return false
	_capacity = _blocks(n)
	# resize() keeps what is already there; instance_count does NOT — it
	# reallocates and zeroes the server buffer, which the caller's _flush repairs.
	_buf.resize(_capacity * STRIDE)
	_mm.instance_count = _capacity
	return true

# Hand capacity back once a wave's peak is long over: the flush uploads the WHOLE
# buffer, so a high-water mark would otherwise be paid for every later frame.
# Only shrinks at 4x slack, so a crowd that thins and re-forms never thrashes the
# (reallocating, buffer-zeroing) instance_count setter. Callers flush after.
func _trim_capacity() -> void:
	var want: int = _blocks(_nodes.size())
	if _capacity <= CAPACITY_STEP or want * 4 > _capacity:
		return
	_capacity = want
	_buf.resize(_capacity * STRIDE)
	# Lowered first: instance_count must never drop below the visible count.
	_mm.visible_instance_count = _nodes.size()
	_mm.instance_count = _capacity

func _blocks(n: int) -> int:
	if n <= 0:
		return CAPACITY_STEP
	return ((n - 1) / CAPACITY_STEP + 1) * CAPACITY_STEP
