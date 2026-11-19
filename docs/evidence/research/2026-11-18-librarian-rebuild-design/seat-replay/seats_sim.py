"""Seat replay (RFC section 15.2; seats_tables.md states the model). Numbers only.

Inputs, all beside this file: seats_events.json (turn closes), seats_keeper_calls.json (Keeper streaming
holds per account), slot_latency.json (Librarian visit holds), wc_runs.json (working-context runs).
"""
import json, os, sys, heapq, collections, random, math, statistics, itertools

HERE = os.path.dirname(os.path.abspath(__file__))
PULSE = 60.0
FAIL_HOLD_GLM = 903.0       # measured GLM durable Execution_failed hold (17 visits, all ~903 s)
FAIL_HOLD_TINKER = 180.0    # measured tinker durable Execution_failed hold (8 visits)
P_ASK_FAIL = 2 / 301        # measured whole-request failure share, durable, 11-15..11-18
P90_FACTOR = 166 / 98.3     # hourly p90 arrival / mean arrival (RFC section 1.1)
BROKEN_HOLD = 1.0           # measured haiku visit time before its 400 (0-1.5 s)
WC_CAP = 1320.0             # cap on working-context holds

def q(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else 0.0

def load():
    ev = json.load(open(os.path.join(HERE, 'seats_events.json')))
    start, end = ev['window']
    arr = sorted((t, k) for k, v in ev['arrivals'].items() for t, _ in v if start <= t < end)
    kc = json.load(open(os.path.join(HERE, 'seats_keeper_calls.json')))
    kcalls = {'glm': [(s, e - s) for s, e in kc['glm-coding'] if start <= s < end],
              'ollama': [(s, e - s) for s, e in kc['openai_compat:deepseek-v4.1-flash'] if start <= s < end]}
    sl = json.load(open(os.path.join(HERE, 'slot_latency.json')))
    def durs(slot):
        return sorted(o['dur'] for o in sl['obs'] if o['dur'] is not None and o['output'] == 'durable'
                      and o['slot'] == slot and o['outcome'] == 'Accepted')
    service = {'glm': durs('glm-coding.glm-5.3-flash'), 'tinker': durs('tinker.tinker-inkling-2-small'),
               'ollama': durs('ollama_cloud.ollama-cloud-deepseek-v4-1-flash')}
    wc = sorted((t, min(el, WC_CAP)) for t, el, _ in json.load(open(os.path.join(HERE, 'wc_runs.json')))
                if start <= t < end)
    return arr, kcalls, service, wc, start, end

class Account:
    def __init__(self, name, seats, limit):
        self.name, self.seats, self.limit = name, seats, limit   # limit: None | int | 'strict'
        self.held = 0; self.fifo = collections.deque(); self.fg = collections.deque(); self.bg = collections.deque()
        self.fg_run = 0
    def has_waiters(self):
        self._clean()
        return bool(self.fifo or self.fg or self.bg)
    def _clean(self):
        for dq in (self.fifo, self.fg, self.bg):
            while dq and dq[0].claimed: dq.popleft()
    def enqueue(self, w):
        if self.limit is None: self.fifo.append(w)
        elif w.fg: self.fg.append(w)
        else: self.bg.append(w)
    def next_waiter(self):
        self._clean()
        if self.limit is None:
            return self.fifo.popleft() if self.fifo else None
        if self.bg and (not self.fg or (self.limit != 'strict' and self.fg_run >= self.limit)):
            self.fg_run = 0; return self.bg.popleft()
        if self.fg:
            if self.bg: self.fg_run += 1
            return self.fg.popleft()
        return None

class Waiter:
    __slots__ = ('fg', 'claimed', 'payload', 'since')
    def __init__(self, fg, payload, since): self.fg, self.claimed, self.payload, self.since = fg, False, payload, since

def run(variant, limit, p_fail, factor=1.0, fixed_glm_hold=None, keeper_load=True, wc_load=True, seed=1, data=None):
    arr, kcalls, service, wc, start, end = data
    rng = random.Random(seed)
    sc = lambda t: start + (t - start) / factor
    T_end = sc(end)
    # lane: list of (slot, account, kind) kind in {'ok','broken'}
    if variant == 'A':
        seats = {'opencode': 4, 'glm': 8, 'tinker': 4, 'ollama': 4, 'haiku': 4}
        lane = [('opencode', 'ok'), ('glm', 'ok'), ('tinker', 'ok'), ('ollama', 'ok'), ('haiku', 'ok')]
    elif variant in ('B', 'D'):
        seats = {'glm': 8, 'tinker': 4, 'ollama': 4}
        lane = [('glm', 'ok'), ('tinker', 'ok'), ('ollama', 'ok')]
    elif variant == 'C':
        seats = {'glm': 8, 'tinker': 4, 'ollama': 4, 'haiku': 4}
        lane = [('glm', 'ok'), ('tinker', 'ok'), ('ollama', 'ok'), ('haiku', 'broken')]
    if fixed_glm_hold:
        seats['glm'] -= fixed_glm_hold
    acc = {a: Account(a, n, limit) for a, n in seats.items()}
    def sample(slot):
        if variant == 'D' and slot in ('tinker', 'ollama'): return rng.choice(service[slot])
        return rng.choice(service['glm'])
    def fail_hold(slot):
        return FAIL_HOLD_TINKER if (variant == 'D' and slot == 'tinker') else FAIL_HOLD_GLM
    ev = []; n = itertools.count()
    def push(t, kind, p): heapq.heappush(ev, (t, next(n), kind, p))
    for t, k in arr: push(sc(t), 'arr', k)
    if keeper_load and not fixed_glm_hold:
        for a in ('glm', 'ollama'):
            for s, d in kcalls[a]: push(sc(s), 'kc', (a, d))
    if wc_load:
        for t, el in wc: push(sc(t), 'wc', el)
    unread = collections.defaultdict(collections.deque)
    busy = set(); resting = set()
    narrowing = collections.defaultdict(list)          # keeper -> stack of unit counts (innermost last)
    st = dict(asks=0, answers=0, units=0, gens=0, failed=0, refused=0, narrow=0, cli=0)
    widths = []; lat = []; lib_wait = []; kc_wait = collections.defaultdict(list); wc_wait = []
    seat_s = collections.Counter(); kc_seat_s = collections.Counter()
    visits = collections.Counter(); answers_by = collections.Counter()
    per_keeper_max = collections.Counter(); hourly_asks = collections.Counter(); hourly_arr = collections.Counter()

    def start_service(t, ask, i):
        slot, kind = lane[i]
        acc[slot].held += 1; visits[slot] += 1
        ask['at'] = i
        if kind == 'broken':
            d = BROKEN_HOLD; outcome = 'refused'
        elif ask['doomed']:
            d = fail_hold(slot); outcome = 'failed_final'; st['gens'] += 1
        else:
            d = sample(slot); outcome = 'answer'; st['gens'] += 1
        seat_s[slot] += d
        push(t + d, 'lib_end', (ask, i, outcome))

    def walk(t, ask, i):
        # first free seat from i on, waiting for nobody
        for j in range(i, len(lane)):
            a = acc[lane[j][0]]
            if a.held < a.seats and not a.has_waiters():
                lib_wait.append(t - ask['wait_from']); start_service(t, ask, j); return
        if i >= len(lane):
            end_ask(t, ask); return
        w = Waiter(False, ('lib', ask, i), t)
        ask['waiter'] = w
        for j in range(i, len(lane)): acc[lane[j][0]].enqueue(w)

    def end_ask(t, ask):
        # every HTTP slot failed or was passed -> CLI layer, modelled as an immediate failure
        st['cli'] += 1
        finish(t, ask, 'refused' if ask['refused'] else 'silent')

    def begin_ask(t, k):
        q_ = unread[k]
        width = narrowing[k][-1] if narrowing[k] else len(q_)
        units = list(itertools.islice(q_, 0, min(width, len(q_))))
        ask = dict(k=k, units=units, refused=False, wait_from=t, waiter=None, doomed=rng.random() < p_fail)
        busy.add(k); st['asks'] += 1; hourly_asks[int((t - start) // 3600)] += 1
        walk(t, ask, 0)

    def finish(t, ask, result):
        k = ask['k']; busy.discard(k)
        u = len(ask['units'])
        if result == 'answer':
            st['answers'] += 1; st['units'] += u; widths.append(u)
            for _ in range(u):
                a = unread[k].popleft(); lat.append(t - a); per_keeper_max[k] = max(per_keeper_max[k], t - a)
            narrowing[k] = [x - u for x in narrowing[k] if x - u > 0]
            if unread[k]: begin_ask(t, k)
        elif result == 'refused' and u > 1:
            st['narrow'] += 1
            if not narrowing[k] or narrowing[k][-1] != u: narrowing[k].append(u)
            narrowing[k].append(u // 2)
            begin_ask(t, k)
        else:
            if result == 'refused': st['refused'] += 1
            else: st['failed'] += 1
            resting.add(k); push(math.floor(t / PULSE) * PULSE + PULSE, 'pulse', k)

    def grant(t, a):
        A = acc[a]
        while A.held < A.seats:
            w = A.next_waiter()
            if w is None: return
            w.claimed = True
            kind = w.payload[0]
            if kind == 'lib':
                _, ask, i = w.payload
                j = [s for s, _ in lane].index(a)
                lib_wait.append(t - ask['wait_from'])
                start_service(t, ask, j)
            elif kind == 'kc':
                d = w.payload[1]; A.held += 1; kc_wait[a].append(t - w.since); kc_seat_s[a] += d
                push(t + d, 'kc_end', a)
            elif kind == 'wc':
                d = w.payload[1]; A.held += 1; wc_wait.append(t - w.since); push(t + d, 'wc_end', a)

    while ev:
        t, _, kind, p = heapq.heappop(ev)
        if kind == 'arr':
            unread[p].append(t); hourly_arr[int((t - start) // 3600)] += 1
            if p not in busy and p not in resting: begin_ask(t, p)
        elif kind == 'kc':
            a, d = p; A = acc[a]
            if A.held < A.seats and not A.has_waiters():
                A.held += 1; kc_wait[a].append(0.0); kc_seat_s[a] += d; push(t + d, 'kc_end', a)
            else:
                A.enqueue(Waiter(True, ('kc', d), t))
        elif kind == 'wc':
            A = acc['glm']
            if A.held < A.seats and not A.has_waiters():
                A.held += 1; wc_wait.append(0.0); push(t + p, 'wc_end', 'glm')
            else:
                A.enqueue(Waiter(False, ('wc', p), t))
        elif kind in ('kc_end', 'wc_end'):
            acc[p].held -= 1; grant(t, p)
        elif kind == 'lib_end':
            ask, i, outcome = p
            slot = lane[i][0]; acc[slot].held -= 1
            if outcome == 'answer':
                answers_by[slot] += 1; finish(t, ask, 'answer')
            elif outcome == 'refused':
                ask['refused'] = True; ask['wait_from'] = t; walk(t, ask, i + 1)
            else:   # the measured whole-request failure: units stay unread, Silent_lane, next pulse
                finish(t, ask, 'silent')
            grant(t, slot)
        elif kind == 'pulse':
            resting.discard(p)
            if unread[p] and p not in busy: begin_ask(t, p)
    hours = (T_end - start) / 3600
    lat.sort()
    hrs = sorted(hourly_asks.get(h, 0) for h in range(int(hours)))
    gen_h = st['gens'] / hours
    return dict(hours=hours, asks_h=st['asks'] / hours, answers_h=st['answers'] / hours, gens_h=gen_h, gens_day=gen_h * 24,
                units_per_answer=st['units'] / max(1, st['answers']), width_p50=q(widths, .5), width_p90=q(widths, .9),
                width_max=max(widths) if widths else 0,
                lag_p50=q(lat, .5), lag_p90=q(lat, .9), lag_p99=q(lat, .99), lag_max=lat[-1] if lat else 0,
                lib_wait_p50=q(lib_wait, .5), lib_wait_p90=q(lib_wait, .9), lib_wait_max=max(lib_wait) if lib_wait else 0,
                seat_h_per_h={s: round(v / 3600 / hours, 2) for s, v in seat_s.items()},
                keeper_seat_h_per_h={s: round(v / 3600 / hours, 2) for s, v in kc_seat_s.items()},
                visit_share={s: round(v / max(1, sum(visits.values())), 3) for s, v in visits.items()},
                answer_share={s: round(v / max(1, st['answers']), 3) for s, v in answers_by.items()},
                kc_wait={a: dict(n=len(v), p50=q(v, .5), p90=q(v, .9), p99=q(v, .99), max=max(v) if v else 0,
                                 over900=sum(1 for x in v if x > 900), over60=sum(1 for x in v if x > 60)) for a, v in kc_wait.items()},
                wc_wait_p50=q(wc_wait, .5), wc_wait_p90=q(wc_wait, .9), wc_wait_max=max(wc_wait) if wc_wait else 0,
                failed=st['failed'], refused_rest=st['refused'], narrowings=st['narrow'], cli_reached=st['cli'],
                asks_per_hour_p50=q(hrs, .5), asks_per_hour_p90=q(hrs, .9), asks_per_hour_max=hrs[-1] if hrs else 0,
                worst_keepers=[(k[:3] + '*', round(v / 60)) for k, v in per_keeper_max.most_common(3)])

def fmt(r):
    m = lambda s: f"{s/60:.0f}m"
    kw = ' '.join(f"{a}:n{v['n']} p50 {v['p50']:.0f}s p90 {v['p90']:.0f}s p99 {v['p99']:.0f}s max {v['max']:.0f}s >60s {v['over60']} >900s {v['over900']}" for a, v in sorted(r['kc_wait'].items()))
    return (f"asks/h {r['asks_h']:.1f} ans/h {r['answers_h']:.1f} gens/h {r['gens_h']:.1f} ({r['gens_day']:.0f}/day) "
            f"units/ans {r['units_per_answer']:.2f} (p50 {r['width_p50']} p90 {r['width_p90']} max {r['width_max']}) "
            f"lag p50 {m(r['lag_p50'])} p90 {m(r['lag_p90'])} p99 {m(r['lag_p99'])} max {m(r['lag_max'])} "
            f"| lib seat wait p50 {r['lib_wait_p50']:.0f}s p90 {r['lib_wait_p90']:.0f}s max {r['lib_wait_max']:.0f}s "
            f"| lib seat-h/h {r['seat_h_per_h']} visits {r['visit_share']} answers {r['answer_share']} "
            f"| keeper seat-h/h {r['keeper_seat_h_per_h']} keeper wait {kw} "
            f"| wc wait p50 {r['wc_wait_p50']:.0f}s p90 {r['wc_wait_p90']:.0f}s max {r['wc_wait_max']:.0f}s "
            f"| failed {r['failed']} refused->rest {r['refused_rest']} narrowings {r['narrowings']} cli {r['cli_reached']} "
            f"| asks per clock hour p50 {r['asks_per_hour_p50']} p90 {r['asks_per_hour_p90']} max {r['asks_per_hour_max']} worst {r['worst_keepers']}")

if __name__ == '__main__':
    data = load()
    arr, kcalls, service, wc, start, end = data
    hourly = collections.Counter(int((t - start) // 3600) for t, _ in arr)
    hs = sorted(hourly.get(h, 0) for h in range(168))
    print(f"turn closes {len(arr)} over 168 h = {len(arr)/168:.1f}/h; hourly p50 {q(hs,.5)} p90 {q(hs,.9)} max {hs[-1]}; Keepers {len({k for _,k in arr})}")
    print(f"Keeper calls replayed: glm {len(kcalls['glm'])}, ollama {len(kcalls['ollama'])}; working-context runs {len(wc)}")
    print(f"service samples: glm n={len(service['glm'])} p50 {q(service['glm'],.5):.0f}; tinker n={len(service['tinker'])} p50 {q(service['tinker'],.5):.0f}; ollama n={len(service['ollama'])} p50 {q(service['ollama'],.5):.0f}")
    out = {}
    which = sys.argv[1] if len(sys.argv) > 1 else 'main'
    if which == 'main':
        for factor, flabel in ((1.0, 'mean'), (P90_FACTOR, 'p90x1.69')):
            for variant in ('A', 'B', 'C', 'D'):
                for limit, llabel in ((None, 'no-limit'), (4, 'L=4'), ('strict', 'strict')):
                    for pf in (0.0, P_ASK_FAIL):
                        r = run(variant, limit, pf, factor=factor, data=data)
                        key = f"{flabel} {variant} {llabel} pfail={pf:.4f}"
                        print(key, '|', fmt(r), flush=True)
                        out[key] = r
        json.dump(out, open(os.path.join(HERE, 'seats_sim_main.json'), 'w'), indent=1)
    elif which == 'fixed':
        for factor, flabel in ((1.0, 'mean'), (P90_FACTOR, 'p90x1.69')):
            for h in (0, 2, 4, 6):
                r = run('B', None, 0.0, factor=factor, fixed_glm_hold=h or None, keeper_load=False, data=data)
                key = f"{flabel} B fixed GLM seats held by Keeper turns = {h} (no Keeper replay)"
                print(key, '|', fmt(r), flush=True)
                out[key] = r
        json.dump(out, open(os.path.join(HERE, 'seats_sim_fixed.json'), 'w'), indent=1)
