"""Aggregates from seats_events.json (numbers only). Output: seats_measure.out, seats_keeper_calls.json."""
import json, os, collections, statistics, datetime
HERE = os.path.dirname(os.path.abspath(__file__))
d = json.load(open(os.path.join(HERE, 'seats_events.json')))
START, END = d['window']
def q(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else None
def day(t): return datetime.datetime.fromtimestamp(t).strftime('%m-%d %H:%M')

print('== A. Streaming summaries (Keeper-turn calls) by provider kind / model, whole extract')
ss = d['ss']
print('span', day(min(r[0] for r in ss)), '->', day(max(r[0] for r in ss)))
by = collections.defaultdict(list)
for t, prov, model, ms, term, ktid, cid in ss:
    by[(prov, model)].append((t, ms, term))
for k, rs in sorted(by.items(), key=lambda kv: -len(kv[1]))[:15]:
    ms = [r[1] / 1000 for r in rs if r[1] is not None]
    terms = collections.Counter(r[2] for r in rs)
    print(f"{k[0]} | {k[1]} | n={len(rs)} | dur s p50 {q(ms,.5):.1f} p90 {q(ms,.9):.1f} p99 {q(ms,.99):.1f} max {max(ms):.0f} | terminals {dict(terms)}")

print('\n== B. Admission waits (requests that met a full account) by provider / class / outcome, per day')
adm = d['adm']
c = collections.Counter(); w = collections.defaultdict(list)
for t, pid, model, cls, wms, out in adm:
    c[(pid, cls, out)] += 1
    if wms is not None: w[(pid, cls, out)].append(wms / 1000)
for k, n in c.most_common(20):
    xs = w.get(k, [])
    print(f"{k} n={n} wait s p50 {q(xs,.5) or 0:.1f} p90 {q(xs,.9) or 0:.1f} max {max(xs) if xs else 0:.0f}")
perday = collections.Counter((datetime.datetime.fromtimestamp(t).strftime('%m-%d'), pid, cls, out) for t, pid, _, cls, _, out in adm if pid == 'glm-coding')
print('glm-coding waits per day/class/outcome:')
for k in sorted(perday): print('  ', k, perday[k])

print('\n== C. Keeper-turn runtime profiles (metrics rows, 7 d window)')
pr = [r for r in d['prof'] if START <= r[0] < END]
pc = collections.Counter(r[2] for r in pr)
for k, n in pc.most_common(15): print(f"  {k} {n} ({n/len(pr)*100:.1f}%)")
print('  rows', len(pr), 'keepers', len({r[1] for r in pr}))

print('\n== D. Seat occupancy by Keeper-turn streaming calls, per account (interval = [ts - total_ms, ts])')
ACC = {('glm', 'glm-5.3-flash'): 'glm-coding', ('glm', 'glm-5.3'): 'glm-coding'}
def acc(prov, model):
    if prov == 'glm': return 'glm-coding'
    return f'{prov}:{model}'
# total_ms counts from the latency counter; for every first chunk in the extract, ttfrc_ms equals
# (first-chunk ts - requested_at) within 1 s (124,925 of 124,925), and requested_at is taken inside
# complete_stream_http, which runs inside the admission callback (complete.ml ~670-700). So total_ms
# is the post-grant seat hold, not the wait. Interval = [ts - total_ms, ts].
iv = collections.defaultdict(list)
for t, prov, model, ms, term, ktid, cid in ss:
    if ms is None or t is None: continue
    iv[acc(prov, model)].append((t - ms / 1000, t))
long = collections.Counter(acc(p_, m_) for t, p_, m_, ms, *_ in ss if ms and ms > 1200e3)
print('streaming calls longer than 1,200 s per account:', dict(long))
# GLM max concurrency per day
for dd in range(10, 19):
    a0 = datetime.datetime(2026, 11, dd).timestamp(); b0 = a0 + 86400
    ev = []
    for s_, e_ in iv['glm-coding']:
        s2, e2 = max(s_, a0), min(e_, b0)
        if e2 > s2: ev += [(s2, 1), (e2, -1)]
    ev.sort(); cur = mx = 0; tmx = None
    for t_, x in ev:
        cur += x
        if cur > mx: mx = cur; tmx = t_
    print(f'  glm-coding Keeper-stream max concurrent on 11-{dd}: {mx}' + (f' first at {day(tmx)}' if tmx else ''))
out = {}
for label, a, b in (('7d 11-10 23:00 -> 11-17 23:00', START, END),
                    ('11-17 18:00 -> 11-18 now (glm 8 seats since 11-17)', datetime.datetime(2026, 11, 17, 18).timestamp(), max(r[0] for r in ss))):
    print(f'-- {label}')
    for k, xs in sorted(iv.items(), key=lambda kv: -len(kv[1]))[:6]:
        ev = []
        for s, e in xs:
            s2, e2 = max(s, a), min(e, b)
            if e2 > s2: ev += [(s2, 1), (e2, -1)]
        ev.sort(); cur = 0; last = a; dist = collections.Counter(); busy = 0.0
        for t, dd in ev:
            dist[cur] += t - last; busy += cur * (t - last); cur += dd; last = t
        dist[cur] += b - last
        span = b - a
        # per-hour mean occupancy
        hh = collections.Counter()
        for s, e in xs:
            s2, e2 = max(s, a), min(e, b)
            h = int(s2 // 3600)
            while h * 3600 < e2:
                lo, hi = max(s2, h * 3600), min(e2, (h + 1) * 3600)
                if hi > lo: hh[h] += hi - lo
                h += 1
        hrs = [hh.get(h, 0) / 3600 for h in range(int(a // 3600), int(b // 3600))]
        share = {lvl: round(v / span, 3) for lvl, v in sorted(dist.items()) if v / span >= 0.001}
        print(f"  {k}: calls {sum(1 for s,e in xs if a <= e < b)}, mean seats held {busy/span:.2f}, per-hour mean p50 {q(hrs,.5):.2f} p90 {q(hrs,.9):.2f} max {max(hrs):.2f}, max concurrent {max(dist)}, time share by level {share}")
        out[(label, k)] = dict(mean=busy / span, p50h=q(hrs, .5), p90h=q(hrs, .9), maxh=max(hrs), maxc=max(dist), share=share)
# keep the GLM and ollama keeper call intervals for the replay
json.dump({k: sorted(v) for k, v in iv.items() if k in ('glm-coding', 'openai_compat:deepseek-v4.1-flash')},
          open(os.path.join(HERE, 'seats_keeper_calls.json'), 'w'))
