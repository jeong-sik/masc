import sys, json, re, bisect, collections
from datetime import datetime
def t(ts): return datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').timestamp()
done = collections.defaultdict(list)  # keeper -> [(t, tokens, latency_s)]
cuts = []  # (t, keeper, provider)
for path in sys.argv[1:]:
    with open(path, errors='replace') as f:
        for l in f:
            try: d = json.loads(l)
            except Exception: continue
            msg = d.get('message') or ''
            m = re.match(r'turn=\d+ total_turns=\d+ .*?tokens=(\d+) .*?latency_ms=(\d+)', msg)
            if m and d.get('keeper_name'):
                done[d['keeper_name']].append((t(d['ts']), int(m.group(1)), int(m.group(2))/1000)); continue
            if 'first_token' in msg:
                m = re.match(r'([\w-]+): turn terminal', msg)
                if m:
                    p = re.search(r"Provider '([\w-]+)'", msg)
                    cuts.append((t(d['ts']), m.group(1), p.group(1) if p else '?'))
for k in done: done[k].sort()
buckets = [0, 25_000, 50_000, 100_000, 150_000, 200_000, 10**9]
def b(x): return bisect.bisect_right(buckets, x) - 1
req = collections.Counter(); slow = collections.Counter(); cutb = collections.Counter(); nosize = 0
for k, rows in done.items():
    for _, tok, lat in rows:
        req[b(tok)] += 1
        if lat > 180: slow[b(tok)] += 1
for ct, k, p in cuts:
    rows = done.get(k, [])
    i = bisect.bisect_left(rows, (ct,)) - 1
    if i < 0 or ct - rows[i][0] > 6*3600: nosize += 1; continue
    cutb[b(rows[i][1])] += 1
print('bucket(tokens)        completed  completed>180s  first_token_cuts  cut_rate')
for i in range(len(buckets)-1):
    lo, hi = buckets[i], buckets[i+1]
    n, s, c = req[i], slow[i], cutb[i]
    print(f'{lo:>7}-{hi if hi<10**9 else "inf":>7}  {n:>9}  {s:>14}  {c:>16}  {c/(n+c)*100 if n+c else 0:6.2f}%')
print('cuts without a size proxy within 6h:', nosize, ' total cuts:', len(cuts))
