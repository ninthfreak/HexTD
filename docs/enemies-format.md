# HexTD Enemy JSON Spec

`data/enemies.json` is one JSON object. Keys are unique enemy IDs; values are
enemy definitions. Key order = display order (list weakest first; the last entry
is treated as "strongest" by that tower targeting mode).

```json
{
  "<id>": { "...fields..." },
  "<id>": { "...fields..." }
}
```

## Fields

| Field | Type | Default | Notes |
|---|---|---|---|
| `name` | string | id | Display name. |
| `shape` | enum | `"square"` | One of the shape strings below. |
| `color` | `"#rrggbb"` | `"#dd5555"` | Body and edge-glow color. |
| `health` | number | 20 | HP for this form. |
| `speed` | number | 90 | Authored plane units/sec (1 hex ≈ 11.3). **In play the actual speed is ×2.5** (a global `SPEED_MULT` in `enemy_3d.gd`); the authored value is the base. |
| `reward` | int | 3 | Money granted on destroy. |
| `glow` | number | 1.0 | Glow/bloom multiplier; 0 = none. Omit if 1. |
| `reduces_to` | id or `""` | `""` | Morph into this form on death; `""` = dies. Must be an existing id. |
| `reduce_count` | int | 1 | Copies spawned on death (use with `reduces_to`). |
| `ecc` | bool | false | Resists 90% damage unless tower has Bit Corruption. |
| `encrypted` | bool | false | Untargetable unless tower has Cipher. |
| `death_sound` | string | `""` | `res://audio/<name>.wav`; blank = default. |

### Size fields (only the one(s) for the chosen `shape` are used)

| Field | Type | Default | Used by |
|---|---|---|---|
| `radius` | number | 16 | `octagon`, `polygon`, and all 3D solids (circumradius); typical 10–28. |
| `side` | number | 16 | `square` (edge length). |
| `length` | number | 32 | `rect` (size along the path). |
| `width` | number | 16 | `rect` (size across the path). |
| `sides` | int | 8 | `polygon` (number of sides). |

`ecc` + `encrypted` together = "TLS" (both apply). Omit any optional field to use
its default.

## Shapes (exact strings)

**Legacy extruded silhouettes** — flat 2D outline extruded to a slab; sized by the
size field(s) noted, **not** `radius`:

```
square    (uses side)
rect      (uses length, width)
octagon   (uses radius)
polygon   (uses radius, sides)
```

**3D solids** — true faceted bodies (Platonic solids, their dual compounds, and the
Kepler–Poinsot stars); all sized by `radius`:

```
tetrahedron
cube
octahedron
dodecahedron
icosahedron
stella_octangula
cube_octahedron
dodeca_icosahedron
great_dodecahedron
great_stellated_dodecahedron
great_icosahedron
```

Unknown shape strings fall back to the extruded `square` body.
