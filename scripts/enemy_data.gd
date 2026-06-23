class_name EnemyData
extends Resource
## One enemy type. These are loaded from data/enemies.json — see that file to
## edit stats or add new enemies. `reduces_to_id` chains an enemy to the smaller
## form it becomes when its health is depleted (empty = it dies).

@export var id := ""
@export var display_name := "Enemy"

# shape — legacy extruded silhouettes: "square" | "rect" | "octagon" | "polygon"
# 3D platonic solids (sized by `radius`): "tetrahedron" | "cube" | "octahedron" |
#   "dodecahedron" | "icosahedron"
# dual compounds (sized by `radius`): "stella_octangula" (2 tetrahedra) |
#   "cube_octahedron" | "dodeca_icosahedron"
@export var shape := "square"
@export var color := Color(0.85, 0.3, 0.3)

# combat
@export var health := 20.0      # max health for THIS form
@export var speed := 90.0       # pixels per second
@export var reward := 3         # money granted when this form is destroyed
@export var glow := 1.0         # glow brightness multiplier (0 = no glow); read by the bloom glow

# size fields (only the ones for the chosen shape are used)
@export var side := 16.0        # square: edge length
@export var length := 32.0      # rect: size along the path (front-to-back)
@export var width := 16.0       # rect: size across the path
@export var radius := 16.0      # octagon / polygon: corner radius
@export var sides := 8          # polygon: number of sides

# reduction chain
@export var reduces_to_id := ""
@export var reduce_count := 1    # how many of the lesser form to spawn on death (1, 2, 4, or 10)
@export var ecc := false         # resists most damage unless the tower has Bit Corruption
@export var encrypted := false   # invisible to towers that lack Cipher
@export var death_sound := ""    # SFX name (res://audio/<name>.wav); blank = shared default
@export var rank := 0            # position in the editor list (0 = top); "Strongest" targeting prefers the largest rank (lowest in the list)
var reduces_to: EnemyData = null
