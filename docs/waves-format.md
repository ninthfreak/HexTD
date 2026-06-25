# HexTD Wave JSON Spec

`data/waves.json` is one JSON object describing the wave schedule. `wave_loader.gd`
reads it, falling back to a built-in default if the file is missing or invalid.

```json
{
  "spawn_interval_default": 0.7,
  "waves": [
    { "name": "First Contact", "groups": [
      { "type": "bit", "count": 12, "gap": 0.55 }
    ] },
    { "groups": [
      { "type": "2bit", "count": 6, "gap": 0.8 },
      { "type": "bit",  "count": 8, "gap": 0.45 }
    ] }
  ]
}
```

## Top level

| Field | Type | Default | Notes |
|---|---|---|---|
| `spawn_interval_default` | number | 0.7 | Seconds between spawns used by any group that omits `gap`. |
| `waves` | array | `[]` | Ordered list of waves; their index is the wave number. |

## Wave

| Field | Type | Default | Notes |
|---|---|---|---|
| `name` | string | the 1-based index (`"1"`, `"2"`, …) | Shown in the wave picker. |
| `groups` | array | `[]` | The enemy groups that make up the wave (see below). |

## Group

| Field | Type | Default | Notes |
|---|---|---|---|
| `type` | enemy id | `"bit"` | Must be a key in `enemies.json`. |
| `count` | int | 1 | How many of that enemy this group spawns. |
| `gap` | number | `spawn_interval_default` | Seconds between consecutive spawns within the group. |
| `start` | number | 0.0 | Seconds from the wave's start for this group's first spawn. Optional — see timeline. |

## Timeline (how groups combine)

A wave is flattened into one sorted list of spawn events, then played on a wave
clock. There are two modes, chosen automatically per wave:

- **Sequential (default / backward-compatible):** if **no** group in the wave
  specifies `start`, groups run end-to-end — each group begins only after the
  previous one finishes. A group of `count` × `gap` occupies `count * gap` seconds.
- **Absolute timeline:** if **any** group in the wave specifies `start`, every
  group is placed on an absolute timeline — its k-th enemy spawns at
  `start + k * gap` (k = 0 … count-1). Groups without a `start` default to `0`, so
  groups can overlap, repeat a type at different times, or run at different rates.

Either way the events are sorted by time, so group order in JSON does not matter
in absolute mode. A wave is over once its spawns are exhausted and the board is
clear.

### Example — overlapping groups (absolute mode)

```json
{ "name": "Pincer", "groups": [
  { "type": "byte",   "count": 3, "gap": 2.0, "start": 0.0 },
  { "type": "bit",    "count": 20, "gap": 0.3, "start": 1.0 },
  { "type": "nybble", "count": 4, "gap": 1.5, "start": 6.0 }
] }
```

The bytes lead, a bit swarm pours in from t=1s, and nybbles join at t=6s — all
interleaved on the one timeline.

## Notes

- Keep wave JSON parsing backward compatible: maps that predate `name` / `start`
  still load (they use the defaults and the sequential timeline).
- Enemy `type`s that aren't found in `enemies.json` are skipped at spawn time with
  a warning.
