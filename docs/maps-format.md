# HexTD Map JSON Spec

One `.json` file per map, dropped into `res://maps/`. The graphical editor exports
this format; `map_loader.gd` reads it. If `maps/` is empty the game falls back to a
built-in serpentine level.

All cell coordinates are **offset `[col, row]` pairs** on a **pointy-top, odd-r**
hex grid (the loader converts them to axial internally).

```json
{
  "name": "Trace 01",
  "format": "hex-oddr-pointy-v1",
  "cols": 20,
  "rows": 14,
  "build_color": "#754799",
  "spawn": [0, 6],
  "goal": [19, 7],
  "path":     [[0,6],[1,6],[2,6], "...ordered spawn->goal..."],
  "trace":    [[0,6],[1,6], "..."],
  "blocking": [[5,3],[5,4]],
  "cells":    [[0,6],[1,6], "...every hex on the board..."]
}
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `path` | `[[c,r], …]` | **yes** | Ordered enemy route, spawn → goal. Consecutive cells should be hex neighbours. |
| `spawn` | `[c, r]` | **yes** | Enemy entry cell (should be `path[0]`). |
| `goal` | `[c, r]` | **yes** | Enemy exit cell (should be the last `path` entry). |
| `name` | string | no (`"Map"`) | Display name in the map picker. |
| `trace` | `[[c,r], …]` | no | The copper region (non-buildable), any width. Absent/empty → falls back to `path`. Include `spawn`/`goal` here so they read as copper. |
| `blocking` | `[[c,r], …]` | no | Line-of-sight walls. Tower targeting can't see through them (unless the tower has Tunneling); radial spokes stop on them unless `ignore_walls`. |
| `cells` | `[[c,r], …]` | no | Every valid hex on the board. Absent → falls back to `path`. |
| `build_color` | `"#rrggbb"` | no | Tint of the frosted "frozen smoke" build area. Absent → the default purple (`#754799`). |
| `format` | string | no | Editor metadata (`"hex-oddr-pointy-v1"`). Ignored by the loader. |
| `cols`, `rows` | int | no | Editor grid size. Metadata only; ignored by the loader. |

## Derived (not authored)

`buildable` is computed by the loader, not stored: every cell in `cells` that is
**not** in `trace` and **not** in `blocking`. So towers may be placed on board
cells that are off the copper route and clear of walls.

## Notes

- Missing any of `path` / `spawn` / `goal` → the map is rejected (loader returns null).
- Backward compatibility is maintained: maps that predate `trace`, `cells`, or
  `build_color` still load (those fields fall back as described). Keep map JSON
  parsing backward compatible when extending it.
- The editor writes `spawn`/`goal` into both `cells` and `trace` automatically, so
  they render as copper and are never buildable.
