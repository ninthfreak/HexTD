class_name HealthBarField
extends MultiMeshInstance3D
## Every visible enemy health bar, as ONE MultiMesh draw call.
##
## Each bar used to be a per-enemy billboarded Sprite3D with no_depth_test — an
## unbatchable transparent draw call and a whole extra node per enemy. Here a
## single unit quad is instanced once per DAMAGED enemy, billboarded in the
## vertex shader and painted procedurally in the fragment shader: the 40x6
## nearest-filtered texture the sprites sampled is reproduced texel-for-texel
## from floor()/step() on UV, so the frame, track and fill edges stay crisp.
##
## Instances stay PACKED: slot i belongs to _nodes[i] and a release swap-removes
## the tail into the hole, so visible_instance_count is always exactly the number
## of live bars — a wave nobody has hit yet draws nothing. Owners keep their own
## slot and are told when a swap-remove moves them (owner.set_bar_slot).
##
## OWNER CONTRACT
##   var slot := HealthBarField.for_parent(get_parent()).acquire(self, w, y, f)
##   field.set_fraction(slot, f)         # on damage
##   field.set_metrics(slot, w, y)       # on a body morph
##   field.release(slot)                 # before the owner frees itself
##   func set_bar_slot(i: int) -> void   # the owner MUST accept a slot move
## The owner's LOCAL position is read every frame (owner and field share a
## parent), so the owner only ever pushes state that actually changed.

# One field per parent, found by name — a scene reload gets a new parent and
# therefore a new field, and nothing outlives the board that holds it.
const FIELD_NAME := "HealthBarField"
const FIELD_PATH := ^"HealthBarField"
# Texel grid of the 40x6 bar the sprites sampled. The shader still draws on it,
# so every frame/track/fill edge lands on exactly the same texel boundary, and
# the world height of a bar stays width * (6/40).
const TEXELS_X := 40.0
const TEXELS_Y := 6.0
const BAR_ASPECT := TEXELS_Y / TEXELS_X
# Same priority the Sprite3D bars carried: above the board/overlay transparents,
# below the tower range indicator.
const RENDER_PRIORITY := 8
# Instance capacity grows in blocks: reallocating a MultiMesh zeroes the
# server-side buffer, so each growth costs a full re-upload.
const CAPACITY_STEP := 32
# The billboard swings the quad out of the axis-aligned box the server derives
# from the (unrotated) instance transforms; the widest bar's half-diagonal has to
# be handed back or bars pop out at the screen edge.
const CULL_MARGIN := 48.0

# MultiMesh 3D buffer layout, per instance: a row-major 3x4 transform (basis row
# i followed by origin component i) then 4 custom-data floats. The basis is a
# pure diag(width, height, 1) scale, so only these seven slots are ever written.
const STRIDE := 16
const _SCALE_X := 0
const _ORIGIN_X := 3
const _SCALE_Y := 5
const _ORIGIN_Y := 7
const _SCALE_Z := 10
const _ORIGIN_Z := 11
const _FRACTION := 12   # custom_data.x

const _BAR_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, depth_test_disabled;

// The 40x6 texel grid of the texture this replaces. Every edge is a floor()
// boundary on it, so the bar reads as the same hard-edged nearest-filtered
// sprite at any zoom instead of a filtered ramp.
const vec2 GRID = vec2(40.0, 6.0);
const vec3 FRAME = vec3(0.0);
const vec3 TRACK = vec3(0.08, 0.10, 0.14);
const vec3 GREEN = vec3(0.2, 0.9, 0.3);
const vec3 AMBER = vec3(0.95, 0.75, 0.15);
const vec3 RED = vec3(0.95, 0.25, 0.2);
const float FRAME_A = 0.9;
const float TRACK_A = 0.85;

// Constant across a bar, so the ramp/fill decision is made once per instance.
varying flat float v_fill;
varying flat vec3 v_ramp;

vec3 srgb_to_lin(vec3 c) {
	// The sprite's albedo was a source_color sampler, so Godot converted these
	// values on sample; the same conversion has to happen here or the bar shifts.
	vec3 hi = pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4));
	vec3 lo = c * (1.0 / 12.92);
	return mix(lo, hi, step(vec3(0.04045), c));
}

void vertex() {
	// Billboard at the bar's own world size: the instance basis is a pure
	// diag(width, height, 1) scale, so its column lengths ARE the bar size and
	// the camera's right/up axes can replace its orientation outright.
	float w = length(MODEL_MATRIX[0].xyz);
	float h = length(MODEL_MATRIX[1].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(normalize(INV_VIEW_MATRIX[0].xyz) * w, 0.0),
		vec4(normalize(INV_VIEW_MATRIX[1].xyz) * h, 0.0),
		vec4(normalize(INV_VIEW_MATRIX[2].xyz), 0.0),
		MODEL_MATRIX[3]);
	float frac = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
	// Filled texel count, matching the fill_rect width the CPU used: round(38 * f).
	v_fill = floor(38.0 * frac + 0.5);
	// Ramp: red below 0.2, amber up to AND including 0.5, green above.
	float is_red = 1.0 - step(0.2, frac);
	float is_green = 1.0 - step(frac, 0.5);
	v_ramp = RED * is_red + GREEN * is_green + AMBER * (1.0 - is_red - is_green);
}

void fragment() {
	vec2 texel = floor(UV * GRID);
	// 1px frame around a dark track; the fill occupies the track's left v_fill texels.
	float edge = step(texel.x, 0.5) + step(38.5, texel.x)
		+ step(texel.y, 0.5) + step(4.5, texel.y);
	float is_frame = step(0.5, edge);
	float is_fill = (1.0 - is_frame) * step(texel.x, v_fill + 0.5);
	ALBEDO = srgb_to_lin(mix(mix(TRACK, v_ramp, is_fill), FRAME, is_frame));
	ALPHA = mix(mix(TRACK_A, 1.0, is_fill), FRAME_A, is_frame);
}
"""

# Mesh and material are one shared pair for the whole game — nothing per-enemy
# or per-board lives in either, so they are built once and never rebuilt.
static var _quad: ArrayMesh = null
static var _mat: ShaderMaterial = null
# Last field handed out. Validated against the CALLER's parent rather than
# trusted, so a freed field (scene reload) is never resurrected; the reference
# itself pins nothing, since a Node is not refcounted.
static var _cached: HealthBarField = null

var _mm: MultiMesh
# Untyped on purpose: the loop reads Node3D.position through an explicit local,
# while the swap-remove has to call the owner's set_bar_slot, which Node3D has no
# static knowledge of.
var _nodes: Array = []
var _anchors := PackedFloat32Array()   # per slot: bar height above the owner's origin
var _buf := PackedFloat32Array()       # shadow copy of the whole MultiMesh buffer
var _capacity := 0

# The field serving `parent` (the enemies' own parent — the board's entity
# holder), created on the first damaged enemy. Lookup is by child name so the
# field is an ordinary node with an ordinary lifetime: it is freed with the board
# and cannot leak into the next scene.
static func for_parent(parent: Node) -> HealthBarField:
	if parent == null:
		return null
	if _cached != null and is_instance_valid(_cached) and _cached.get_parent() == parent:
		return _cached
	_cached = null
	var found := parent.get_node_or_null(FIELD_PATH) as HealthBarField
	if found != null:
		_cached = found
		return found
	var made := HealthBarField.new()
	made.name = FIELD_NAME
	parent.add_child(made)
	_cached = made
	return made

func _init() -> void:
	# Built here, not in _ready: for_parent() returns to a caller that acquires an
	# instance immediately, before this node has ticked once.
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true      # must precede instance_count (it allocates)
	_mm.instance_count = 0
	_mm.visible_instance_count = 0
	_mm.mesh = _quad_mesh()
	multimesh = _mm
	material_override = _bar_material()
	# A HUD billboard must never darken the board below it.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = CULL_MARGIN
	# Bars are placed from positions the enemies have already moved this frame.
	process_priority = 100

func _ready() -> void:
	set_process(not _nodes.is_empty())

# Unit quad in the XY plane with UV (0,0) at the top-left corner, so the shader's
# texel grid matches the image the sprites used (row 0 = the bar's top frame).
static func _quad_mesh() -> ArrayMesh:
	if _quad != null:
		return _quad
	var pts: Array = [Vector3(-0.5, 0.5, 0.0), Vector3(0.5, 0.5, 0.0),
		Vector3(0.5, -0.5, 0.0), Vector3(-0.5, -0.5, 0.0)]
	var uvs: Array = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in [0, 1, 2, 0, 2, 3]:
		var p: Vector3 = pts[i]
		var uv: Vector2 = uvs[i]
		st.set_normal(Vector3(0.0, 0.0, 1.0))
		st.set_uv(uv)
		st.add_vertex(p)
	_quad = st.commit()
	return _quad

static func _bar_material() -> ShaderMaterial:
	if _mat != null:
		return _mat
	var sh := Shader.new()
	sh.code = _BAR_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.render_priority = RENDER_PRIORITY
	return _mat

# ---------------------------------------------------------------- owner API
# Claim an instance for `owner`. Returns the slot the owner keeps and hands back
# to set_fraction / set_metrics / release; a later swap-remove reaches the owner
# through set_bar_slot. `width` is the bar's world width (height follows from
# BAR_ASPECT), `anchor_y` its height above the owner's own origin.
func acquire(node: Node3D, width: float, anchor_y: float, frac: float) -> int:
	var slot: int = _nodes.size()
	_nodes.append(node)
	_anchors.append(anchor_y)
	_ensure_capacity(slot + 1)
	set_metrics(slot, width, anchor_y)
	set_fraction(slot, frac)
	_place(slot)
	# Uploaded now rather than deferred to the next _process: a slot whose server
	# data is still zeroed would draw a degenerate quad at the board origin.
	_flush()
	set_process(true)
	return slot

# Fraction only — the cheap, frequent call. Picked up by the next frame's flush,
# which runs after all damage for the frame has landed.
func set_fraction(slot: int, frac: float) -> void:
	if slot < 0 or slot >= _nodes.size():
		return
	_buf[slot * STRIDE + _FRACTION] = clampf(frac, 0.0, 1.0)

# Bar size + anchor, for a body that changed shape under a live bar.
func set_metrics(slot: int, width: float, anchor_y: float) -> void:
	if slot < 0 or slot >= _nodes.size():
		return
	_anchors[slot] = anchor_y
	var b: int = slot * STRIDE
	_buf[b + _SCALE_X] = width
	_buf[b + _SCALE_Y] = width * BAR_ASPECT
	_buf[b + _SCALE_Z] = 1.0

func release(slot: int) -> void:
	_drop(slot)
	if _nodes.is_empty():
		_mm.visible_instance_count = 0
		set_process(false)
		return
	# The tail moved into the hole, so the whole live range has to go up again
	# this frame or the moved bar blinks out until the next _process.
	_flush()

# ---------------------------------------------------------------- per frame
func _process(_delta: float) -> void:
	var i := 0
	while i < _nodes.size():
		var ref = _nodes[i]        # untyped: may be a previously freed owner
		if not is_instance_valid(ref):
			_drop(i)               # owner freed without releasing — reclaim the slot
			continue               # the tail landed on i; test it before moving on
		var holder: Node3D = ref
		var p: Vector3 = holder.position
		var b: int = i * STRIDE
		_buf[b + _ORIGIN_X] = p.x
		_buf[b + _ORIGIN_Y] = p.y + _anchors[i]
		_buf[b + _ORIGIN_Z] = p.z
		i += 1
	if _nodes.is_empty():
		_mm.visible_instance_count = 0
		set_process(false)
		return
	_trim_capacity()
	_flush()

# ---------------------------------------------------------------- internals
func _place(slot: int) -> void:
	var ref = _nodes[slot]
	if not is_instance_valid(ref):
		return
	var holder: Node3D = ref
	var p: Vector3 = holder.position
	var b: int = slot * STRIDE
	_buf[b + _ORIGIN_X] = p.x
	_buf[b + _ORIGIN_Y] = p.y + _anchors[slot]
	_buf[b + _ORIGIN_Z] = p.z

# One upload for the whole field. visible_instance_count trails the buffer, so
# the GPU never reads a slot the CPU has not written this frame.
func _flush() -> void:
	if _capacity == 0:
		return
	_mm.buffer = _buf
	_mm.visible_instance_count = _nodes.size()

# Swap-remove `slot`: the tail instance moves into the hole (and its owner is
# told), keeping the live range packed at [0, size).
func _drop(slot: int) -> void:
	var last: int = _nodes.size() - 1
	if slot < 0 or slot > last:
		return
	if slot != last:
		_nodes[slot] = _nodes[last]
		_anchors[slot] = _anchors[last]
		var src: int = last * STRIDE
		var dst: int = slot * STRIDE
		for k in range(STRIDE):
			_buf[dst + k] = _buf[src + k]
		var moved = _nodes[slot]   # untyped: set_bar_slot is the owner's, not Node3D's
		if is_instance_valid(moved):
			moved.set_bar_slot(slot)
	_nodes.remove_at(last)
	_anchors.remove_at(last)

func _ensure_capacity(n: int) -> void:
	if n <= _capacity:
		return
	_capacity = _blocks(n)
	# resize() keeps what is already there; instance_count does NOT — it
	# reallocates and zeroes the server buffer, which the caller's _flush repairs.
	_buf.resize(_capacity * STRIDE)
	_mm.instance_count = _capacity

# Hand capacity back once a wave's peak is long over: the flush uploads the WHOLE
# buffer, so a high-water mark would otherwise be paid for every later frame.
# Only shrinks at 4x slack, so a wave that ebbs and flows never thrashes the
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
