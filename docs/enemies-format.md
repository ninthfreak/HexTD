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
| `shape` | enum | `"cube"` | One of the shape strings below. |
| `radius` | number | 16 | Body size (circumradius); typical 10–28. |
| `color` | `"#rrggbb"` | `"#dd5555"` | Body and edge-glow color. |
| `health` | number | 20 | HP for this form. |
| `speed` | number | 90 | Plane units/sec (1 hex ≈ 11.3). |
| `reward` | int | 3 | Money granted on destroy. |
| `glow` | number | 1.0 | Glow/bloom multiplier; 0 = none. Omit if 1. |
| `reduces_to` | id or `""` | `""` | Morph into this form on death; `""` = dies. Must be an existing id. |
| `reduce_count` | int | 1 | Copies spawned on death (use with `reduces_to`). |
| `ecc` | bool | false | Resists 90% damage unless tower has Bit Corruption. |
| `encrypted` | bool | false | Untargetable unless tower has Cipher. |
| `death_sound` | string | `""` | `res://audio/<name>.wav`; blank = default. |

`ecc` + `encrypted` together = "TLS" (both apply). Omit any optional field to use
its default.

## Shapes (exact strings, all sized by `radius`)

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
