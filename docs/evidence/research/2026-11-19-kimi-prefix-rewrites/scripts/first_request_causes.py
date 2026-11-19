# Usage: python3 -I first_request_causes.py <base-path>/.masc   (reads the runtime records read-only)
import json, os, re, sys, collections, datetime
H=sys.argv[1]
UTC=datetime.timezone.utc
T0=datetime.datetime(2026,11,18,10,0,tzinfo=UTC).timestamp()
T1=datetime.datetime(2026,11,19,1,40,tzinfo=UTC).timestamp()
A_MISS,A_OUT,A_READ=2.5,20.0,0.01   # % of 5h window per 1M tokens (fit)
def ts(s): return datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
sha=re.compile(r'sha256=([0-9a-f]+)')
def ref(a):
    m=sha.search((a or {}).get('content_ref') or '') if isinstance(a,dict) else None
    return m.group(1) if m else None
reqs=collections.defaultdict(list)
for d in ['18','19']:
    for line in open(H+f'/costs/2026-11/{d}.jsonl'):
        try: r=json.loads(line)
        except Exception: continue
        if r.get('usage_projection')!='raw_observation' or r.get('usage_missing'): continue
        if not (r.get('runtime_id') or '').startswith('kimi_coding'): continue
        t=ts(r['timestamp'])
        if not (T0<=t<=T1): continue
        cm=r.get('cache_miss_input_tokens')
        if cm is None: cm=r.get('non_cached_input_tokens') or 0
        reqs[(r['agent'],r['keeper_turn_id'])].append((t,r.get('input_tokens') or 0,r.get('cache_read_tokens') or 0,cm,r.get('output_tokens') or 0))
for k in reqs: reqs[k].sort()
# classify first request via provider-input snapshots
cls={}
for keeper in sorted({k[0] for k in reqs}):
    snaps=[]
    for d in ['18','19']:
        f=H+f'/keepers/{keeper}/provider-inputs/2026-11/{d}.jsonl'
        if os.path.exists(f):
            for line in open(f):
                try: snaps.append(json.loads(line))
                except Exception: pass
    snaps.sort(key=lambda r:r['captured_at'])
    for a,b in zip(snaps,snaps[1:]):
        if not a['messages'] or not b['messages']: continue
        m0=[ref(m.get('artifact')) for m in a['messages']]; m1=[ref(m.get('artifact')) for m in b['messages']]
        t0=[ref(t.get('artifact')) for t in a.get('tool_schemas') or []]; t1=[ref(t.get('artifact')) for t in b.get('tool_schemas') or []]
        if a['runtime_profile']!=b['runtime_profile']: c='runtime_changed'
        elif ref(a.get('system_prompt'))!=ref(b.get('system_prompt')): c='system_changed'
        elif t0!=t1: c='tools_changed'
        elif m0[0]!=m1[0]: c='front_moved'
        else:
            k=next((i for i,(x,y) in enumerate(zip(m0,m1)) if x!=y), None)
            c='rewrite_mid' if k is not None and k < len(m0) else 'append_only'
        cls[(keeper,b['absolute_turn'])]=c
agg=collections.defaultdict(lambda:[0,0.0,0.0])
tot=collections.defaultdict(float)
for (keeper,turn),rs in reqs.items():
    first=rs[0]; rest=rs[1:]
    c=cls.get((keeper,turn),'unclassified')
    a=agg[(keeper,'first:'+c)]; a[0]+=1; a[1]+=first[3]/1e6; a[2]+=first[1]/1e6
    tot[(keeper,'first_miss')]+=first[3]/1e6
    tot[(keeper,'rest_miss')]+=sum(x[3] for x in rest)/1e6
    tot[(keeper,'out')]+=sum(x[4] for x in rs)/1e6
    tot[(keeper,'read')]+=sum(x[2] for x in rs)/1e6
    tot[(keeper,'turns')]+=1; tot[(keeper,'reqs')]+=len(rs)
print('per keeper (est. % of 5h window = 2.5*miss + 20*out + 0.01*read, period 11-18 10:00Z..11-19 01:40Z)')
grand=collections.Counter()
for keeper in sorted({k[0] for k in reqs}):
    fm=tot[(keeper,'first_miss')]; rm=tot[(keeper,'rest_miss')]; o=tot[(keeper,'out')]; rd=tot[(keeper,'read')]
    parts={'first_miss':A_MISS*fm,'rest_miss':A_MISS*rm,'output':A_OUT*o,'read':A_READ*rd}
    for k,v in parts.items(): grand[k]+=v
    print(f"  {keeper:22s} turns={int(tot[(keeper,'turns')]):3d} reqs={int(tot[(keeper,'reqs')]):4d} total={sum(parts.values()):5.1f}% | "+' '.join(f"{k}={v:4.1f}%" for k,v in parts.items()))
print('  ALL', f"{sum(grand.values()):.1f}%", dict((k,round(v,1)) for k,v in grand.items()))
print('first-request miss by cause:')
g2=collections.defaultdict(lambda:[0,0.0,0.0])
for (keeper,c),(n,miss,inp) in agg.items():
    g=g2[c]; g[0]+=n; g[1]+=miss; g[2]+=inp
for c,(n,miss,inp) in sorted(g2.items(), key=lambda kv:-kv[1][1]):
    print(f"  {c:24s} turns={n:3d} miss={miss:5.2f}M ({A_MISS*miss:4.1f}% of window) hit={100*(1-miss/max(inp,1e-9)):4.1f}%")
