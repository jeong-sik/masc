import json, os, statistics, tempfile
R = json.load(open(os.path.join(os.environ.get('ORDER_AB_OUT', os.path.join(tempfile.gettempdir(), 'order-ab')), 'results.json')))
def delta(x):
    if not isinstance(x, dict) or 'new_claims' not in x: return None
    dropped = frozenset(d.get('memory_id') for d in (x.get('dropped') or []) if isinstance(d, dict))
    absorbs = frozenset(a for c in (x.get('new_claims') or []) for a in (c.get('absorbs') or []))
    return {'none': not x.get('new_claims') and not dropped, 'dropped': dropped, 'absorbs': absorbs, 'new': len(x.get('new_claims') or [])}
def jac(a, b): return 1.0 if not a and not b else len(a & b) / len(a | b)
pairs = {'stable_first vs recorded_order': ('stable_first', 'recorded_order'), 'recorded vs recorded_order (noise)': ('recorded', 'recorded_order')}
for name, (x, y) in pairs.items():
    same_none = jd = ja = dn = n = 0; jds = []; dns = []
    for r in R:
        a, b = delta(r.get(x)), delta(r.get(y))
        if a is None or b is None: continue
        n += 1; same_none += a['none'] == b['none']
        jds.append(jac(a['dropped'], b['dropped'])); dns.append(abs(a['new'] - b['new']))
    if n: print(f"{name}: n={n}, same no-change decision {same_none}/{n}, dropped-id Jaccard mean {statistics.mean(jds):.2f}, |new claims diff| mean {statistics.mean(dns):.2f}")
for arm in ('recorded_order', 'stable_first'):
    u = [r[arm + '_usage'] for r in R if r.get(arm + '_usage')]
    if u: print(arm, 'prompt tokens p50', int(statistics.median(x['prompt_tokens'] for x in u)), 'cached p50', int(statistics.median((x.get('prompt_tokens_details') or {}).get('cached_tokens', 0) for x in u)))
print('parse failures', sum(1 for r in R for arm in ('recorded_order', 'stable_first') if delta(r.get(arm)) is None))
