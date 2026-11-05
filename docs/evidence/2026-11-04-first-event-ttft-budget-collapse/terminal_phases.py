import sys, json, re, collections
# Distinct failed turns ("<keeper>: turn terminal" lines) by timeout phase and day, split at a cutover instant.
cut = sys.argv[1]; paths = sys.argv[2:]
def phase(msg):
    if 'made no progress for' in msg: return 'no_progress(wall_clock)'
    m = re.search(r'phase=([\w:]+)', msg)
    if m: return m.group(1)
    # Not a 900s-class bucket: unphased failures whose text mentions a timeout (Muse silence, agent_core errors, SSE parse, connect).
    if 'timeout' in msg.lower(): return 'no_phase_timeout_text'
    return None
day = collections.defaultdict(collections.Counter); post = collections.Counter(); post_rows = []
for p in paths:
    with open(p, errors='replace') as f:
        for l in f:
            if 'turn terminal' not in l: continue
            try: d = json.loads(l)
            except Exception: continue
            msg = d.get('message') or ''
            if not re.match(r'[\w-]+: turn terminal', msg): continue
            ph = phase(msg)
            if ph is None: continue
            ts = d['ts']
            if ts >= cut: post[ph] += 1; post_rows.append((ts, msg[:200]))
            else: day[ts[:10]][ph] += 1
phases = sorted({k for c in day.values() for k in c} | set(post))
w = {p: max(len(p), 4) for p in phases}
print('day        ' + '  '.join(f'{p:>{w[p]}}' for p in phases))
for dd in sorted(day): print(dd + ' ' + '  '.join(f'{day[dd][p]:>{w[p]}}' for p in phases))
tot = collections.Counter();  [tot.update(c) for c in day.values()]
print('pre-total  ' + '  '.join(f'{tot[p]:>{w[p]}}' for p in phases))
print('post-cut   ' + '  '.join(f'{post[p]:>{w[p]}}' for p in phases), ' since', cut)
for r in post_rows: print('  ', r)
