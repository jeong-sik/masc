# Usage: python3 -I stable_prefix_hits.py <base-path>/.masc   (reads the runtime records read-only)
import json, os, re, sys, collections, datetime
H=sys.argv[1]
def ts(s): return datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
sha=re.compile(r'sha256=([0-9a-f]+)')
def ref(a):
    m=sha.search((a or {}).get('content_ref') or '') if isinstance(a,dict) else None
    return m.group(1) if m else None
days=['16','17','18','19']
reqs=collections.defaultdict(list)
last_by_agent={}
for d in days:
    for line in open(H+f'/costs/2026-11/{d}.jsonl'):
        try: r=json.loads(line)
        except Exception: continue
        if r.get('usage_projection')!='raw_observation' or r.get('usage_missing'): continue
        reqs[(r['agent'],r['keeper_turn_id'])].append((ts(r['timestamp']),r.get('input_tokens') or 0,r.get('cache_read_tokens') or 0,r.get('runtime_id') or ''))
for k in reqs: reqs[k].sort()
out=collections.defaultdict(list)
for keeper in sys.argv[2:]:
    snaps=[]
    for d in days:
        f=H+f'/keepers/{keeper}/provider-inputs/2026-11/{d}.jsonl'
        if os.path.exists(f):
            for line in open(f):
                try: snaps.append(json.loads(line))
                except Exception: pass
    snaps.sort(key=lambda r:r['captured_at'])
    for a,b in zip(snaps,snaps[1:]):
        if a['runtime_profile']!=b['runtime_profile']: continue
        m0=[ref(m.get('artifact')) for m in a['messages']]; m1=[ref(m.get('artifact')) for m in b['messages']]
        if not m0 or not m1 or m1[:len(m0)]!=m0: continue          # messages append-only
        if ref(a.get('system_prompt'))!=ref(b.get('system_prompt')): continue
        t0=[ref(t.get('artifact')) for t in a.get('tool_schemas') or []]; t1=[ref(t.get('artifact')) for t in b.get('tool_schemas') or []]
        if t0!=t1: continue
        ra=reqs.get((keeper,a['absolute_turn'])); rb=reqs.get((keeper,b['absolute_turn']))
        if not ra or not rb: continue
        gap=rb[0][0]-ra[-1][0]
        prov=b['runtime_profile'].split('.')[0]
        out[prov].append((gap, rb[0][2]/max(rb[0][1],1), rb[0][1]))
for prov,rows in out.items():
    buckets=[(0,120),(120,300),(300,600),(600,1800),(1800,1e9)]
    s=[]
    for lo,hi in buckets:
        sel=[r for r in rows if lo<=r[0]<hi]
        if sel: s.append(f"{int(lo)}-{int(hi) if hi<1e9 else 'inf'}s n={len(sel)} hit={100*sum(r[1]*r[2] for r in sel)/sum(r[2] for r in sel):.0f}%")
    print(f"{prov:24s} fully-stable turns={len(rows):3d} | "+' | '.join(s))
