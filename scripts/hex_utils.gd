class_name HexUtils
## Pointy-top hexagon math using axial coordinates (q, r).
## Authoring is done in offset (col, row) coords and converted to axial here.

const SQRT3 := 1.7320508075688772

## Odd-r offset (col, row) -> axial (q, r). Odd rows are shifted right.
static func offset_to_axial(col: int, row: int) -> Vector2i:
	var q := col - (row - (row & 1)) / 2
	return Vector2i(q, row)

## Axial (q, r) -> pixel center (before any board origin offset).
static func axial_to_pixel(hex: Vector2i, size: float) -> Vector2:
	var x := size * SQRT3 * (hex.x + hex.y / 2.0)
	var y := size * 1.5 * hex.y
	return Vector2(x, y)

## Pixel (relative to hex (0,0) center) -> fractional axial coords.
static func pixel_to_axial(p: Vector2, size: float) -> Vector2:
	var q := (SQRT3 / 3.0 * p.x - 1.0 / 3.0 * p.y) / size
	var r := (2.0 / 3.0 * p.y) / size
	return Vector2(q, r)

## Hex (grid) distance between two axial cells, in tiles.
static func axial_distance(a: Vector2i, b: Vector2i) -> int:
	var dq := a.x - b.x
	var dr := a.y - b.y
	return (absi(dq) + absi(dq + dr) + absi(dr)) / 2

## True when the delta (dq, dr) from a center cell falls inside the 30-degree
## rotated hex range of radius n.  Geometric rotation of the standard hex disk:
## same circumradius, rotated 30 degrees (taller, narrower, pointy top/bottom).
static func in_rotated_range(dq: int, dr: int, n: int) -> bool:
	var a: int = (2 * dq + dr) * (2 * dq + dr)
	var b: int = (dq - dr) * (dq - dr)
	var c: int = (dq + 2 * dr) * (dq + 2 * dr)
	return maxi(a, maxi(b, c)) <= 3 * n * n

## Round fractional axial coords to the nearest hex (cube rounding).
static func axial_round(qf: float, rf: float) -> Vector2i:
	var xf := qf
	var zf := rf
	var yf := -xf - zf
	var rx := roundf(xf)
	var ry := roundf(yf)
	var rz := roundf(zf)
	var dx := absf(rx - xf)
	var dy := absf(ry - yf)
	var dz := absf(rz - zf)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2i(int(rx), int(rz))
