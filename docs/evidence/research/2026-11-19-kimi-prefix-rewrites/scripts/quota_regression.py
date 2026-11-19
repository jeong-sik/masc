# Usage: python3 -I quota_regression.py <base-path>/.masc   (reads the runtime records read-only)
import sys
import json, glob, os, collections, datetime, itertools
H=sys.argv[1]
UTC=datetime.timezone.utc
def ts(s): return datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
snaps=[]
for f in sorted(glob.glob(H+'/provider_usage_history/2026-11/*.jsonl')):
    for line in open(f):
        if 'kimi_coding' not in line: continue
        try: arr=json.loads(line)
        except Exception: continue
        if isinstance(arr,dict): arr=[arr]
        for r in arr:
            if r.get('source')=='kimi_coding.usages' and r.get('kind') in ('five_hour','provider:usage (provider resetTime)'):
                snaps.append((r['observed_at'],r['kind'],r['value'],r.get('resets_at')))
reqs=[]
for f in sorted(glob.glob(H+'/costs/2026-11/1[0-9].jsonl')):
    for line in open(f):
        if 'kimi_coding' not in line: continue
        try: r=json.loads(line)
        except Exception: continue
        if not (r.get('runtime_id') or '').startswith('kimi_coding') or r.get('usage_projection')!='raw_observation': continue
        cm=r.get('cache_miss_input_tokens')
        if cm is None: cm=r.get('non_cached_input_tokens') or 0
        reqs.append((ts(r['timestamp']), r.get('cache_read_tokens') or 0, cm, r.get('output_tokens') or 0, r['runtime_id']))
reqs.sort()
def series(kind):
    s=sorted((t,v,ra) for t,k,v,ra in snaps if k==kind)
    return s
import bisect
rt=[r[0] for r in reqs]
def interval_sum(a,b):
    i=bisect.bisect_right(rt,a); j=bisect.bisect_right(rt,b)
    sel=reqs[i:j]
    return (sum(x[1] for x in sel), sum(x[2] for x in sel), sum(x[3] for x in sel), len(sel), collections.Counter(x[4] for x in sel))
for kind in ['five_hour','provider:usage (provider resetTime)']:
    s=series(kind)
    rows=[]
    for (t0,v0,r0),(t1,v1,r1) in zip(s,s[1:]):
        if r0!=r1 or t1-t0>1800: continue   # reset or gap
        # The window the RFC reports: 11-18 10:00Z .. 11-19 01:40Z.
        if t0 < datetime.datetime(2026,11,18,10,0,tzinfo=UTC).timestamp(): continue
        if t1 > datetime.datetime(2026,11,19,1,40,tzinfo=UTC).timestamp(): continue
        rd,ms,out,n,models=interval_sum(t0,t1)
        rows.append((t0,t1,(v1-v0)*100,rd/1e6,ms/1e6,out/1e6,n))
    # aggregate into hourly bins to cut quantization
    print('==',kind,'intervals',len(rows))
    tot=[sum(r[i] for r in rows) for i in range(2,7)]
    print(f"  total d%={tot[0]:.1f} read={tot[1]:.1f}M miss={tot[2]:.2f}M out={tot[3]:.3f}M n={tot[4]}")
    # least squares with nonneg via brute coarse search on 3 coefficients
    import math
    best=None
    for a in [x*0.25 for x in range(0,41)]:          # % per M miss
        for c in [x*1.0 for x in range(0,81)]:        # % per M output
            for b in [0,0.001,0.002,0.005,0.01,0.02,0.05,0.1]:  # % per M read
                err=sum((r[2]-(a*r[4]+b*r[3]+c*r[5]))**2 for r in rows)
                if best is None or err<best[0]: best=(err,a,b,c)
    err,a,b,c=best
    sst=sum((r[2]-tot[0]/len(rows))**2 for r in rows)
    print(f"  fit: d% = {a:.2f}*miss(M) + {b:.3f}*read(M) + {c:.1f}*out(M)   R2={1-err/sst:.3f}")
    for b2 in [0,0.01,0.05,0.1,0.25]:
        best2=None
        for a in [x*0.25 for x in range(0,41)]:
            for c in [x*1.0 for x in range(0,81)]:
                e=sum((r[2]-(a*r[4]+b2*r[3]+c*r[5]))**2 for r in rows)
                if best2 is None or e<best2[0]: best2=(e,a,c)
        print(f"   force read={b2:<5}%/M -> miss {best2[1]:.2f} out {best2[2]:.1f}  R2={1-best2[0]/sst:.3f}")
