class_name HexMapData
extends Resource
## Describes a single level: which hex cells exist, the ordered enemy path,
## which cells can hold towers, and the spawn/goal cells (all in axial coords).

@export var display_name: String = "Level"
@export var cells: Array[Vector2i] = []      # every valid hex on the board
@export var path: Array[Vector2i] = []        # ordered spawn -> goal (enemy route)
@export var trace: Array[Vector2i] = []       # copper region (non-buildable); empty -> falls back to path
@export var buildable: Array[Vector2i] = []   # cells where towers may be placed
@export var blocking: Array[Vector2i] = []    # walls that block tower line of sight
@export var spawn: Vector2i = Vector2i.ZERO
@export var goal: Vector2i = Vector2i.ZERO
# Tint of the frosted "frozen smoke" build area, per map. Defaults to the
# original purple so maps that predate this field look unchanged.
@export var build_color: Color = Color(0.46, 0.28, 0.60)
