class_name TowerData
extends Resource
## Stat block for a tower type. Make a new one to add a new tower.

@export var display_name: String = "Tower"
@export var color: Color = Color(0.4, 0.7, 1.0)
@export var range_tiles: int = 3              # view/attack radius measured in hex tiles
@export var fire_rate: float = 1.5            # shots per second
@export var damage: float = 10.0
@export var cost: int = 40
@export var projectile_speed: float = 320.0   # pixels per second
@export var fire_mode: String = "single"      # "single" = homing shot; "radial" = burst; "laser" = charging beam
@export var directions: int = 6               # radial only: number of equally-spaced spokes (6 = hex flat sides)
@export var ignore_walls: bool = false        # "Tunneling": attack through blocking tiles (targeting ignores LOS; radial spokes pass through walls)
@export var ramp_time: float = 2.0            # laser only: seconds of sustained fire to reach full power (damage = max dmg/sec)
@export var focus_time: float = 0.0           # seconds a tower is blind/idle after killing its target (Beam swarm tax)
@export var bit_corruption := false           # ignores enemy ECC damage resistance
@export var cipher := false                   # can see and target Encrypted enemies
@export var buffer_overflow := false          # single-hit surplus damage spills into the target's decay children
@export var dos := false                      # "Denial of Service": a hit briefly freezes the enemy, then slows it (single/radial only)
@export var height_scale: float = 1.0         # body height multiplier (3D view)
@export var width_scale: float = 1.0          # body width / footprint multiplier
## Up to 3 upgrade slots (independent paths), authored in the editor. Each slot is a
## Dictionary {"name": String, "tiers": Array}. Each tier (up to 5 per slot) is a
## Dictionary {"cost": int, optional "damage"/"range"/"fire_rate"/"directions"/"ramp_time"/
## "focus_time"/"height"/"width": additive deltas (may be negative), optional "color": "#rrggbb" override,
## optional "cipher"/"bit_corruption"/"ignore_walls"/"buffer_overflow"/"dos": "on"|"off"}.
## Slots are bought independently, level by level; tiers within a slot are sequential.
@export var upgrades: Array = []
