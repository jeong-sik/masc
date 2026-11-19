# Usage: python3 -I turn_pair_changes.py <base-path>/.masc   (reads the runtime records read-only)
import sys
import json, os, re, glob, collections
H=sys.argv[1]
sha=re.compile(r'sha256=([0-9a-f]+)')
def ref(a):
    if not isinstance(a,dict): return None
    m=sha.search(a.get('content_ref') or ''); return m.group(1) if m else None
def size(a): return (a or {}).get('bytes') or 0
rows=collections.Counter(); ex=collections.defaultdict(list); sizes=collections.defaultdict(list)
for f in sorted(glob.glob(H+'/keepers/*/provider-inputs/2026-11/1[89].jsonl')):
    snaps=[]
    for line in open(f):
        try: r=json.loads(line)
        except Exception: continue
        snaps.append(r)
    keeper=f.split('/keepers/')[1].split('/')[0]
    snaps.sort(key=lambda r:r['captured_at'])
    for a,b in zip(snaps,snaps[1:]):
        if not b['runtime_profile'].startswith('kimi_coding') or a['runtime_profile']!=b['runtime_profile']: continue
        sysch = ref(a.get('system_prompt'))!=ref(b.get('system_prompt'))
        t0=[ref(t.get('artifact')) for t in a.get('tool_schemas') or []]; t1=[ref(t.get('artifact')) for t in b.get('tool_schemas') or []]
        toolch = t0!=t1
        m0=[ref(m.get('artifact')) for m in a['messages']]; m1=[ref(m.get('artifact')) for m in b['messages']]
        if not m0 or not m1: mc='empty'
        elif m0[0]!=m1[0]: mc='front_moved'
        else:
            k=next((i for i,(x,y) in enumerate(zip(m0,m1)) if x!=y),None)
            mc='rewrite_mid' if k is not None and k<len(m0) else 'append_only'
        key=(('SYS' if sysch else 'sys=') ,('TOOLS' if toolch else 'tools='),mc)
        rows[key]+=1
        sizes[key].append((b['system_prompt'].get('bytes',0), sum(size(m.get('artifact')) for m in b['messages']), len(b['messages']), b['wire'].get('body_bytes',0)))
tot=sum(rows.values())
print('kimi consecutive turn pairs (11-18..19):',tot)
for k,n in rows.most_common():
    s=sizes[k]; med=sorted(s,key=lambda x:x[3])[len(s)//2]
    print(f"  {k} n={n} ({100*n/tot:.0f}%)  median: sys={med[0]}B msgs={med[1]}B nmsg={med[2]} body={med[3]}B")
