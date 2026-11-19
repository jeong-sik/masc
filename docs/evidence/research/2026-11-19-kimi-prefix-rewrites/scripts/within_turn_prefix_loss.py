# Usage: python3 -I within_turn_prefix_loss.py <base-path>/.masc   (reads the runtime records read-only)
import json, os, collections, datetime, sys
H=sys.argv[1]
def ts(s): return datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
days=sys.argv[2:] or ["17","18","19"]
turns=collections.defaultdict(list)
for d in days:
    for line in open(H+f'/costs/2026-11/{d}.jsonl'):
        try: r=json.loads(line)
        except Exception: continue
        if r.get('usage_projection')!='raw_observation' or r.get('usage_missing'): continue
        rid=r.get('runtime_id') or ''
        if not rid: continue
        turns[(r['agent'],r['keeper_turn_id'],rid)].append((ts(r['timestamp']), r.get('input_tokens') or 0, r.get('cache_read_tokens') or 0, r.get('output_tokens') or 0))
stat=collections.defaultdict(lambda:[0,0,0,0.0])  # pairs, low(<50%), zero, lost_tokens(M)
for (a,t,rid),rs in turns.items():
    rs.sort()
    prov=rid.split('.')[0]
    for (t0,i0,c0,o0),(t1,i1,c1,o1) in zip(rs,rs[1:]):
        if i1 < i0: continue   # window cut inside turn (shrink) - skip
        s=stat[prov]; s[0]+=1
        expect=i0  # previous prompt fully cached at least
        if c1 < 0.5*expect: s[1]+=1; s[3]+=(expect-c1)/1e6
        if c1==0: s[2]+=1
print(f"{'provider':24s} {'pairs':>6s} {'hit<50%prev':>11s} {'zero':>5s} {'lost(M)':>8s}")
for p,(n,low,z,lost) in sorted(stat.items(), key=lambda kv:-kv[1][0]):
    print(f"{p:24s} {n:6d} {low:6d} ({100*low/max(n,1):4.1f}%) {z:5d} {lost:8.2f}")
