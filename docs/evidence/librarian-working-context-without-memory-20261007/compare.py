import json, os, sys, statistics, tempfile
R = json.load(open(os.path.join(os.environ.get('WC_AB_OUT', os.path.join(tempfile.gettempdir(), 'wc-ab')), 'results.json')))
def pockets(x):
    if not isinstance(x, dict) or 'working_contexts' not in x: return None
    return {frozenset(c.get('sources') or []): (frozenset(c.get('merge_contexts') or []), c.get('completeness'))
            for c in x['working_contexts']}
def partition(p): return None if p is None else frozenset(p.keys())
stats = {'cases': len(R), 'parsed_both': 0, 'A_eq_recorded_partition': 0, 'B_eq_A_partition': 0, 'B_eq_recorded_partition': 0,
         'B_eq_A_merge': 0, 'B_eq_A_completeness': 0}
diff = []
tok = {'with': [], 'without': [], 'with_cached': [], 'without_cached': []}
for r in R:
    rec, a, b = pockets(r['recorded']), pockets(r.get('with_memory')), pockets(r.get('without_memory'))
    if r.get('with_memory_usage'):
        tok['with'].append(r['with_memory_usage']['prompt_tokens']); tok['with_cached'].append((r['with_memory_usage'].get('prompt_tokens_details') or {}).get('cached_tokens', 0))
    if r.get('without_memory_usage'):
        tok['without'].append(r['without_memory_usage']['prompt_tokens']); tok['without_cached'].append((r['without_memory_usage'].get('prompt_tokens_details') or {}).get('cached_tokens', 0))
    if a is None or b is None:
        diff.append((r['keeper'], r['run'], 'parse', str(r.get('with_memory'))[:120], str(r.get('without_memory'))[:120])); continue
    stats['parsed_both'] += 1
    stats['A_eq_recorded_partition'] += partition(a) == partition(rec)
    stats['B_eq_recorded_partition'] += partition(b) == partition(rec)
    same = partition(a) == partition(b); stats['B_eq_A_partition'] += same
    if same:
        stats['B_eq_A_merge'] += all(a[k][0] == b[k][0] for k in a)
        stats['B_eq_A_completeness'] += all(a[k][1] == b[k][1] for k in a)
    if not same or not all(a[k] == b.get(k) for k in a):
        diff.append((r['keeper'], r['run'], 'pockets', sorted(map(sorted, a)), sorted(map(sorted, b))))
print(json.dumps(stats, indent=1))
for k, v in tok.items():
    if v: print(k, 'p50', int(statistics.median(v)), 'sum', sum(v))
print('differing cases:', len(diff))
for d in diff: print(' ', d[0], d[1][-8:], d[2], '\n    A:', d[3], '\n    B:', d[4])
