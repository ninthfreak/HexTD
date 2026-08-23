#!/usr/bin/env python3
"""Procedural SFX generator for HexTD (chiptune/synth, binary-computing theme).

Regenerates every .wav in this directory:  python3 audio/gen_sfx.py

Design rules (deliberate, to keep the mix from becoming noise):
- frequent events (shots, hits) are the SHORTEST and QUIETEST cues;
- rare events (wave start/clear, defeat, victory) may be longer/louder;
- every sound's level is baked into the file, so AudioManager needs no
  per-sound volume table;
- laser_hum is built from integer-cycle components over exactly 1s, so the
  forward loop is click-free by construction.

Levels are normalised on LOUDNESS, not peak. Peak normalisation was the
original mistake: the ear integrates energy over roughly a 200 ms window, so a
short cue is perceived far quieter than its peak implies (~3 dB per halving
below that). Combined with envelopes that dumped ~96% of their energy in the
first few milliseconds, the frequent cues measured -42 dB effective and were
inaudible in the mix while still peaking at a respectable 0.30. LOUDNESS below
is 20*log10(rms) + 10*log10(min(dur, 0.2) / 0.2) — energy inside that window —
and durations/decays were relaxed so each cue actually has a body to hear.
"""
import math
import wave
import numpy as np

SR = 44100
RNG = np.random.default_rng(0xB17)  # fixed seed: regeneration is reproducible


def t_axis(dur):
	return np.linspace(0.0, dur, int(SR * dur), endpoint=False)


def env_ad(n, attack_s, k):
	"""Attack ramp then exponential decay (k = decay rate per second)."""
	t = np.arange(n) / SR
	a = np.clip(t / max(attack_s, 1e-5), 0.0, 1.0)
	return a * np.exp(-t * k)


def sweep_phase(f0, f1, dur):
	"""Phase array for an exponential frequency sweep f0 -> f1 over dur."""
	t = t_axis(dur)
	if abs(f1 - f0) < 1e-9:
		f = np.full_like(t, f0)
	else:
		f = f0 * (f1 / f0) ** (t / dur)
	return 2.0 * np.pi * np.cumsum(f) / SR


def tri(phase):
	return 2.0 / np.pi * np.arcsin(np.sin(phase))


def soft_square(phase, soft=0.7):
	return np.tanh(np.sin(phase) / max(1e-3, 1.0 - soft))


def lowpass(x, alpha):
	"""One-pole lowpass; alpha in (0,1], smaller = darker."""
	y = np.empty_like(x)
	acc = 0.0
	for i, v in enumerate(x):
		acc += alpha * (v - acc)
		y[i] = acc
	return y


def bitcrush(x, bits=5, hold=4):
	q = 2 ** (bits - 1)
	held = np.repeat(x[::hold], hold)[: len(x)]
	return np.round(held * q) / q


CEILING = 0.95          # sample ceiling; the SFX bus limiter handles stacking


def loudness_db(x, dur):
	"""Energy inside the ear's ~200 ms integration window, in dB."""
	rms = float(np.sqrt(np.mean(x * x))) if x.size else 0.0
	return 20.0 * math.log10(max(rms, 1e-9)) + 10.0 * math.log10(min(dur, 0.2) / 0.2)


def write_wav(name, x, target_db):
	"""Normalise to a target LOUDNESS, soft-limiting peaks rather than losing it.

	Sounds built from stacked notes have sparse, aligned peaks, so plain scaling
	to a peak ceiling throws away several dB of the loudness just asked for.
	Where that would happen the signal is driven through a tanh knee instead,
	which pulls the crest down and lets the body reach the target; a couple of
	passes converge because each knee changes the loudness slightly.
	"""
	dur = len(x) / SR
	softened = ""
	for _ in range(4):
		x = x * 10.0 ** ((target_db - loudness_db(x, dur)) / 20.0)
		m = float(np.max(np.abs(x)))
		if m <= CEILING:
			break
		# Drive chosen so the loudest sample lands on the ceiling.
		drive = m / CEILING
		x = np.tanh(x * drive) / np.tanh(drive)
		softened = "  (soft-limited)"
	m = float(np.max(np.abs(x)))
	if m > CEILING:
		x = x * (CEILING / m)
	rms = float(np.sqrt(np.mean(x * x)))
	clamped = softened
	data = (np.clip(x, -1, 1) * 32767).astype("<i2")
	with wave.open(f"audio/{name}.wav", "wb") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(SR)
		w.writeframes(data.tobytes())
	print(f"{name:16s} {dur*1000:6.0f}ms  peak {np.max(np.abs(x)):.2f}  "
		f"rms {rms:.3f}  loudness {loudness_db(x, dur):6.1f} dB{clamped}")


def blip(f0, f1, dur, k, attack=0.002, wave_fn=tri):
	ph = sweep_phase(f0, f1, dur)
	return wave_fn(ph) * env_ad(len(ph), attack, k)


def noise_burst(dur, k, alpha=0.5, attack=0.001):
	n = int(SR * dur)
	x = RNG.standard_normal(n)
	return lowpass(x, alpha) * env_ad(n, attack, k)


def place_at(total_dur, offset, x):
	out = np.zeros(int(SR * total_dur))
	i = int(SR * offset)
	seg = x[: len(out) - i]
	out[i : i + len(seg)] += seg
	return out


# ---------------------------------------------------------------- combat (short + quiet)

# single-mode shot: tight descending zap. Longer body + gentler decay than the
# original 60ms/k=55, which was over before the ear could integrate it.
write_wav("tower_fire", blip(1400, 650, 0.11, 26), -19.0)

# radial volley: breathier spread (noise + low zap)
x = noise_burst(0.14, 28, alpha=0.35) * 0.8 + blip(900, 380, 0.14, 22)
write_wav("radial_fire", x, -19.0)

# arc wave launch: soft FM whoosh rising then settling
dur = 0.20
t = t_axis(dur)
car = sweep_phase(260, 720, dur)
mod = np.sin(2 * np.pi * 55 * t) * np.exp(-t * 12) * 4.0
x = np.sin(car + mod) * env_ad(len(t), 0.015, 13)
write_wav("arc_fire", x, -18.0)

# DoS jam wave: descending warble (reads "slow/jam", pairs with the frost tint)
dur = 0.22
t = t_axis(dur)
ph = sweep_phase(700, 240, dur)
warble = np.sin(2 * np.pi * 28 * t) * 0.5
x = np.sin(ph + warble * np.sin(ph * 0.5)) * env_ad(len(t), 0.01, 12)
x = lowpass(x, 0.5)
write_wav("dos_wave", x, -18.0)

# projectile hit: tiny ping + tick (replaces the 8ms click)
# The tick still leads, but a ringing tail carries the energy the ear needs.
x = place_at(0.10, 0.0, noise_burst(0.014, 190, alpha=0.8)) \
	+ place_at(0.10, 0.002, blip(2300, 1700, 0.098, 30, wave_fn=np.sin))
write_wav("projectile_hit", x, -19.0)

# enemy death: bit-crushed descending shatter — "data structure destroyed"
seq = [(950, 0.0), (640, 0.06), (420, 0.12)]
x = np.zeros(int(SR * 0.22))
for f, off in seq:
	x += place_at(0.22, off, blip(f, f * 0.8, 0.10, 26, wave_fn=lambda p: soft_square(p, 0.6)))
x = bitcrush(x, bits=5, hold=4) + noise_burst(0.22, 22, alpha=0.3) * 0.25
write_wav("enemy_death", x, -16.0)

# decay split: two quick descending blips (one thing becomes lesser things)
x = place_at(0.16, 0.0, blip(760, 600, 0.08, 30)) + place_at(0.16, 0.07, blip(560, 430, 0.09, 26))
write_wav("enemy_split", bitcrush(x, bits=6, hold=3), -17.0)

# ---------------------------------------------------------------- economy / flow

# life lost: compact two-tone down alarm — urgent but not shrill
x = place_at(0.26, 0.0, blip(880, 880, 0.11, 18, wave_fn=lambda p: soft_square(p, 0.5))) \
	+ place_at(0.26, 0.12, blip(587, 587, 0.13, 15, wave_fn=lambda p: soft_square(p, 0.5)))
write_wav("enemy_leak", lowpass(x, 0.35), -14.0)

# tower placed: low seat-thunk + tiny metallic confirm
x = place_at(0.18, 0.0, blip(130, 55, 0.17, 16, wave_fn=np.sin)) \
	+ place_at(0.18, 0.0, noise_burst(0.018, 150, alpha=0.7) * 0.5) \
	+ place_at(0.18, 0.05, blip(1500, 1400, 0.10, 30, wave_fn=np.sin) * 0.35)
write_wav("build_place", x, -16.0)

# sell: reverse coin (two rising blips)
x = place_at(0.19, 0.0, blip(520, 560, 0.09, 26, wave_fn=np.sin)) \
	+ place_at(0.19, 0.07, blip(780, 840, 0.12, 20, wave_fn=np.sin))
write_wav("sell", x, -16.0)

# upgrade: 3-note ascending arpeggio with a sparkle on top
notes = [(523, 0.0), (659, 0.08), (784, 0.16)]
x = np.zeros(int(SR * 0.30))
for f, off in notes:
	x += place_at(0.30, off, blip(f, f, 0.12, 18))
x += place_at(0.30, 0.18, blip(1568, 1568, 0.12, 22, wave_fn=np.sin) * 0.4)
write_wav("upgrade", x, -15.0)

# cheat coin: single tight coin blip (spammable while held — kept tiny)
x = place_at(0.13, 0.0, blip(988, 988, 0.06, 34, wave_fn=np.sin)) \
	+ place_at(0.13, 0.045, blip(1319, 1319, 0.085, 26, wave_fn=np.sin))
write_wav("cheat_money", x, -18.0)

# ---------------------------------------------------------------- rare moments (may breathe)

# wave start: filtered riser + arrival tick
dur = 0.45
t = t_axis(dur)
riser = tri(sweep_phase(220, 660, dur)) * np.minimum(t / dur * 1.6, 1.0) * np.exp(-np.maximum(t - dur * 0.8, 0) * 30)
shim = np.sin(sweep_phase(1200, 2400, dur)) * 0.18 * (t / dur)
x = lowpass(riser, 0.35) + shim
x += place_at(dur, 0.40, blip(880, 880, 0.05, 60) * 0.6)
write_wav("wave_start", x * env_ad(len(t), 0.02, 2.2), -14.0)

# wave clear: bright dyad + coin sparkles
x = place_at(0.42, 0.0, blip(784, 784, 0.20, 14, wave_fn=np.sin)) \
	+ place_at(0.42, 0.0, blip(988, 988, 0.20, 14, wave_fn=np.sin) * 0.7) \
	+ place_at(0.42, 0.12, blip(1568, 1568, 0.10, 35, wave_fn=np.sin) * 0.4) \
	+ place_at(0.42, 0.20, blip(2093, 2093, 0.12, 35, wave_fn=np.sin) * 0.3)
write_wav("wave_clear", x, -14.0)

# victory (all waves cleared): rising fanfare + long chime tail
notes = [(523, 0.00), (659, 0.10), (784, 0.20), (1047, 0.32)]
x = np.zeros(int(SR * 0.75))
for f, off in notes:
	x += place_at(0.75, off, blip(f, f, 0.16, 16))
x += place_at(0.75, 0.32, blip(2093, 2093, 0.35, 9, wave_fn=np.sin) * 0.35)
write_wav("victory", x, -12.0)

# defeat: power-down sweep with growing wobble + terminal thud
dur = 1.15
t = t_axis(dur)
wob = np.sin(2 * np.pi * (2 + 10 * t / dur) * t) * (0.15 + 0.5 * t / dur)
ph = sweep_phase(440, 52, dur)
x = soft_square(ph + wob, 0.5) * np.exp(-t * 1.6)
x = lowpass(x, 0.25)
x += place_at(dur, 0.92, blip(70, 40, 0.2, 14, wave_fn=np.sin) * 0.9)
x += noise_burst(dur, 3.5, alpha=0.15) * 0.12
write_wav("defeat", x, -11.0)

# ---------------------------------------------------------------- UI + loop

# ui click: a tick, but with enough tail to actually register. 20ms at k=160
# put ~96% of its energy in the first 5ms and measured -41 dB effective.
write_wav("ui_click", blip(1900, 1500, 0.055, 55, wave_fn=np.sin), -22.0)

# laser hum: 1.0s seamless loop — every component completes integer cycles in 1s
dur = 1.0
t = t_axis(dur)
x = (np.sin(2 * np.pi * 110 * t)
	+ 0.5 * np.sin(2 * np.pi * 220 * t)
	+ 0.28 * np.sin(2 * np.pi * 331 * t)      # 331 (not 330): slow 1Hz beat vs 330 harmonics
	+ 0.18 * np.sin(2 * np.pi * 443 * t))
x *= 1.0 + 0.12 * np.sin(2 * np.pi * 3 * t)   # 3Hz AM, integer cycles
write_wav("laser_hum", x, -22.0)
