#!/usr/bin/env python3
"""HexTD balance sim — throughput model (non-spatial: no LOS/placement/overkill-waste).
Runs from anywhere (defaults to the repo's data/ found relative to this script — so
it works from the editor/ directory or the repo root), or pass an explicit data dir:
    python3 balance_sim.py [path/to/data]
Models: ECC-aware effective HP across full decay trees, per-fire-mode DPS incl. the
laser ramp integral, time-to-kill, per-tower DPS/$, and a wave-pressure vs income curve.
Edit TOWERS below to match data/towers.json after you change numbers.
"""
import json, sys, math, os
# Default to <repo>/data resolved from this file's location (editor/ -> repo root),
# so the script is CWD-independent; an explicit path arg still overrides it.
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_ROOT, "data")
E = json.load(open(f"{DATA}/enemies.json")); W = json.load(open(f"{DATA}/waves.json"))
SPEED_MULT, HEX, ECC_RESIST = 2.5, 11.34, 0.9
tps = lambda e: E[e]["speed"]*SPEED_MULT/HEX

def tree_hp(eid, pierce):
    e=E[eid]; h=e["health"]
    if e.get("ecc") and not pierce: h/=(1-ECC_RESIST)
    rt,rc=e.get("reduces_to",""),e.get("reduce_count",1)
    return h + (rc*tree_hp(rt,pierce) if rt else 0)
def tree_reward(eid):
    e=E[eid]; r=e.get("reward",3); rt,rc=e.get("reduces_to",""),e.get("reduce_count",1)
    return r + (rc*tree_reward(rt) if rt else 0)

def laser_ttk(maxdps, ramp, hp):
    cap=maxdps*ramp/3.0
    return (3*ramp*ramp*hp/maxdps)**(1/3.0) if hp<=cap else ramp+(hp-cap)/maxdps

def cum_income():
    out=[]; run=0
    for w in W["waves"]:
        run+=sum(g.get("count",1)*tree_reward(g["type"]) for g in w.get("groups",[]) if g.get("type") in E)
        out.append(run)
    return out

def wave_window(w, path_tiles=24):
    gs=w.get("groups",[]); absmode=any("start" in g for g in gs); slow=99; last=0.0; t=0.0
    for g in gs:
        c,gap=g.get("count",1),g.get("gap",0.7); typ=g.get("type","bit")
        if typ in E: slow=min(slow,tps(typ))
        if absmode: last=max(last, g.get("start",0.0)+(c-1)*gap)
        else: t+=c*gap; last=t
    return max(last+path_tiles/max(slow,0.5), 5.0)

def report():
    CUM=cum_income()
    print(f"Enemies {len(E)} | Waves {len(W['waves'])} | total income (full clear) {CUM[-1]:,}")
    print(f"TLS-Tebibyte full-tree HP: {tree_hp('tls_tebibyte',False):,.0f} unpierced / "
          f"{tree_hp('tls_tebibyte',True):,.0f} with Bit Corruption")
    print("\nWave pressure (req DPS = effHP/window, afford = cumIncome*0.8*0.12):")
    for i,w in enumerate(W["waves"]):
        if i%16 and i not in (len(W['waves'])-1,):  # sample
            continue
        win=wave_window(w)
        req=sum(g.get("count",1)*tree_hp(g["type"],True) for g in w.get("groups",[]) if g.get("type") in E)/win
        aff=CUM[i]*0.8*0.12
        print(f"  wave {i+1:>3}: req {req:>9.0f}  afford {aff:>10.0f}  {'OK' if aff>=req else 'TIGHT'}")

if __name__ == "__main__":
    report()
