# HexTD Tower JSON Spec

`data/towers.json` is one JSON object. Keys are unique tower IDs; values are tower
definitions. Key order = build-bar order in-game.

```json
{
  "<id>": { "...fields..." },
  "<id>": { "...fields..." }
}
```

The tower format is **not** kept backward compatible — redefine towers freely.

## Base fields

| Field | Type | Default | Notes |
|---|---|---|---|
| `name` | string | `"Tower"` | Display name. |
| `description` | string | `""` | Build-button tooltip body (the name is shown above it). Multi-line; `\n` for line breaks. |
| `color` | `"#rrggbb"` | `"#59b2ff"` | Body / projectile / beam color. |
| `range` | int | 3 | Attack radius in hex tiles (min 1). |
| `fire_rate` | number | 1.5 | Shots per second (`single`) / volleys per second (`radial`) / waves per second (`arc`). Ignored by `laser`. |
| `damage` | number | 10 | Damage per hit. For `laser`, this is **max damage per second** at full charge. For `arc`, 0 deals no damage (still applies ability effects). |
| `cost` | int | 40 | Build cost. |
| `projectile_speed` | number | 320 | Plane units/sec for `single`/`radial` shots and the `arc` wave front (1 hex ≈ 11.3). |
| `fire_mode` | enum | `"single"` | `"single"` \| `"radial"` \| `"laser"` \| `"arc"` (see below). |
| `directions` | int | 6 | `radial` only: number of equally spaced spokes (min 1; 6 = hex flat sides). |
| `targets` | int | 1 | `single` only: distinct enemies engaged per fire cycle (one shot each, no overkill), furthest-along first (min 1). |
| `arc_angle` | number | 70 | `arc` only: aimed wedge width in degrees (clamped 1–360; ≥360 = all directions). |
| `ramp_time` | number | 2.0 | `laser` only: seconds of sustained fire to reach full power (min 0.05). |
| `focus_time` | number | 0.0 | Seconds the tower is idle after **killing** a target (min 0). Taxes swarm clearing. |
| `bit_corruption` | bool | false | Ignores enemy ECC 90% damage resist. |
| `cipher` | bool | false | Can see and target Encrypted enemies. |
| `buffer_overflow` | bool | false | Single-hit surplus damage spills into the target's decay children. Single-target only. |
| `ignore_walls` | bool | false | "Tunneling": attack through blocking tiles (LOS ignored; `radial` spokes pass through walls). |
| `dos` | bool | false | "Denial of Service": a hit freezes the enemy briefly, then slows it for a short window. `single`/`radial` only (laser ignores it). |
| `dos_freeze` | number | 0.5 | DoS: seconds the enemy is fully stopped (min 0). |
| `dos_slow_time` | number | 2.0 | DoS: seconds slowed after the stop (min 0). |
| `dos_slow_factor` | number | 0.5 | DoS: speed multiplier while slowed (clamped 0.05–1.0; lower = stronger jam). Re-hits take the stronger (lower) factor. |
| `height_scale` | number | 1.0 | Body height multiplier, 3D view (min 0.05). |
| `width_scale` | number | 1.0 | Body width / footprint multiplier (min 0.05; also scales the 2D body). |
| `upgrades` | array | `[]` | Up to 3 upgrade slots — see below. |

Omit any optional field to use its default. `target_priority` (first/last/strongest)
is a per-tower in-game toggle, not a JSON field.

## Fire modes

- **`single`** — homing shot at the enemy furthest along the path within range and
  line of sight. The only mode that uses `buffer_overflow`.
- **`radial`** — fires a volley of `directions` straight spokes whenever any enemy
  is in range. Spokes are stopped by blocking walls unless `ignore_walls`.
- **`laser`** — locks one target and ramps damage with a convex (quadratic
  ease-in) curve: `damage_per_sec = damage * (elapsed / ramp_time)²`, reaching full
  at `ramp_time`. The ramp resets to 0 whenever the target changes or is lost, so a
  stream of small targets never reaches full power.
- **`arc`** — an aimed expanding wave. Each shot emits a wave from the tower toward
  its prioritised target (the `target_priority` direction); the front travels
  outward at `projectile_speed` and dissipates at the range edge. Every enemy the
  front crosses within range — and within the aimed wedge — is affected once (no
  pierce cap; breadth is set by range). It applies `damage` (default 0 deals none)
  and the tower's ability flags through the normal effect path, gated by Cipher for
  Encrypted enemies. `fire_rate` is waves/second; `directions`/`ramp_time`/
  `focus_time` are unused. A pure delivery mechanism — it carries whatever the tower
  has (e.g. pair with `dos` for a freeze wave).

## Upgrades

`upgrades` is an array of **slots** (max 3). Each slot is an independent path the
player buys level-by-level in-game; tiers within a slot are sequential.

**Crosspathing (BTD6 rule):** at most **two** of the three paths may rise above
tier 0, and only **one** of those may rise above tier 2 (the second is capped at
tier 2). The game enforces this — a path blocked by the rule shows as *locked*
rather than purchasable.

```json
"upgrades": [
  { "name": "Caliber", "tiers": [ { "...tier..." }, { "...tier..." } ] },
  { "name": "Lens",    "tiers": [ { "...tier..." } ] }
]
```

Each slot: `{ "name": string, "tiers": [ ... ] }` (max 5 tiers). A bare array of
tiers (no slot wrapper) is tolerated and treated as a single slot.

### Tier fields

A tier mutates the tower's effective stats when purchased. All numeric entries are
**additive deltas** (may be negative); flags are tri-state; absent keys mean "no
change".

| Key | Type | Effect |
|---|---|---|
| `cost` | int | Price of this tier (not a delta). |
| `damage` | number | Add to `damage`. |
| `range` | number | Add to `range` (rounded). |
| `fire_rate` | number | Add to `fire_rate`. |
| `directions` | number | Add to `directions` (rounded). |
| `targets` | number | Add to `targets` (rounded, floored at 1). |
| `arc_angle` | number | Add to `arc_angle` (clamped 1–360). |
| `ramp_time` | number | Add to `ramp_time` (floored at 0). |
| `focus_time` | number | Add to `focus_time` (floored at 0.1). |
| `dos_freeze` | number | Add to `dos_freeze` (floored at 0). |
| `dos_slow_time` | number | Add to `dos_slow_time` (floored at 0). |
| `dos_slow_factor` | number | Add to `dos_slow_factor` (clamped 0.05–1.0). |
| `height` | number | Add to `height_scale` (floored at 0.05). |
| `width` | number | Add to `width_scale` (floored at 0.05). |
| `color` | `"#rrggbb"` | Replace `color` (omit / `""` = no change). |
| `cipher` | `"on"`\|`"off"` | Enable/disable Cipher. |
| `bit_corruption` | `"on"`\|`"off"` | Enable/disable Bit Corruption. |
| `ignore_walls` | `"on"`\|`"off"` | Enable/disable Tunneling. |
| `buffer_overflow` | `"on"`\|`"off"` | Enable/disable Buffer Overflow. |
| `dos` | `"on"`\|`"off"` | Enable/disable Denial of Service. |

Flags resolve in slot order — a later slot's `"on"`/`"off"` overrides an earlier
one.

## Example

```json
{
  "basic": {
    "name": "Basic", "color": "#59b2ff", "range": 3, "fire_rate": 1.6,
    "damage": 9, "cost": 40, "projectile_speed": 340, "fire_mode": "single",
    "upgrades": [
      { "name": "Caliber", "tiers": [
        { "cost": 50, "damage": 6 },
        { "cost": 120, "damage": 10, "buffer_overflow": "on" }
      ] }
    ]
  },
  "beam": {
    "name": "Beam", "color": "#ff5ad0", "range": 4, "damage": 200, "cost": 200,
    "fire_mode": "laser", "ramp_time": 6, "focus_time": 0.3,
    "upgrades": [
      { "name": "Lens", "tiers": [ { "cost": 150, "focus_time": -0.1 } ] }
    ]
  }
}
```
