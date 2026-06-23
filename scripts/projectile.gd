class_name Projectile
extends Node2D
## Homing shot. Flies toward its target enemy and deals damage on contact.

var target            # Enemy (untyped to avoid a class dependency cycle)
var speed: float
var damage: float
var col: Color
var pierces_ecc := false   # tower had Bit Corruption

const GLOW := 1.7          # over-bright factor: >1.0 is what the HDR glow blooms

func setup(start: Vector2, t, dmg: float, spd: float, c: Color, pierce := false) -> void:
	position = start
	target = t
	damage = dmg
	speed = spd
	col = c
	pierces_ecc = pierce
	queue_redraw()

func _process(delta: float) -> void:
	if not is_instance_valid(target):
		queue_free()
		return
	var to_target: Vector2 = target.position - position
	var dist := to_target.length()
	var step := speed * delta
	if step >= dist:
		target.take_damage(damage, pierces_ecc)
		var am = get_node_or_null("/root/AudioManager")
		if am:
			am.play_sfx("projectile_hit")
		queue_free()
	else:
		position += to_target / dist * step
		queue_redraw()

func _draw() -> void:
	# over-bright so the HDR 2D glow blooms the shot (values >1.0 bloom)
	var c: Color = col.lightened(0.3)
	draw_circle(Vector2.ZERO, 4.0, Color(c.r * GLOW, c.g * GLOW, c.b * GLOW, c.a))
	draw_circle(Vector2.ZERO, 2.0, Color(GLOW, GLOW, GLOW))
