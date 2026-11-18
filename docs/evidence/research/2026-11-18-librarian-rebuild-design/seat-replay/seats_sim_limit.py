"""Run-limit sensitivity (seats_tables.md; numbers only)."""
import json, os, sys, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import seats_sim as S
d = S.load()
kc = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'seats_keeper_calls.json')))
for a in ('glm-coding', 'openai_compat:deepseek-v4.1-flash'):
    xs = [e - s for s, e in kc[a] if d[4] <= s < d[5]]
    print(f'Keeper stream hold {a}: n={len(xs)} mean {statistics.mean(xs):.1f}s p50 {S.q(xs,.5):.1f}s')
out = {}
for v in ('B', 'D'):
    for lim in (None, 1, 4, 16, 64, 256, 'strict'):
        r = S.run(v, lim, 0.0, data=d)
        key = f'mean {v} limit={lim}'
        print(key, '|', S.fmt(r), flush=True); out[key] = r
json.dump(out, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'seats_sim_limit.json'), 'w'), indent=1)
