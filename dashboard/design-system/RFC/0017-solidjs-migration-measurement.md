# RFC 0017 — KpiStrip Island Performance Measurement (2026-04-30)

Companion document to RFC 0017 (`0017-solidjs-migration.md`). Records the first runtime measurement on the actual island wrapper after PRs #12162 → #12268 migrated 6 callers.

## Headline finding

**The migration does not improve user-perceived latency on our app.** For every page that uses any migrated caller, mount time is ≈30 ms slower than the Preact original; update time is similarly slower. The performance hypothesis from RFC 0017 §4 (krausest geomean 1.40→1.12) was measured on a 1000-row table benchmark — far from our actual usage where the maximum strip count on any page is roughly 10. Our usage falls entirely in the Preact-wins region.

## Method

| Item | Value |
|------|-------|
| Bench page | `dashboard/design-system/preview/bench-kpi.html` + `bench-kpi.ts` |
| Runner | `puppeteer` headless Chromium |
| Measurement | `requestAnimationFrame` poll for `[role="listitem"]` count to reach `count × cells/strip` |
| Cells per strip | 6 |
| Update samples | 3 per N |
| Warmup | 3 silent rounds at default N before suite |
| Side A | Preact KpiStrip + KpiCell via `htm/preact` (children pattern) |
| Side B | Solid KpiStripIsland (`solid-js/web` mount inside Preact `useEffect`) |

Both sides are entered through Preact's `render()` because that is the production entry point — KpiStripIsland is itself a Preact component whose `useEffect` mounts the Solid subtree.

A naive `t1 - t0` around `render(...)` would lie: KpiStripIsland's first synchronous render returns an empty `<div>`. The actual Solid mount happens inside a `useEffect` callback that fires at task tier. The bench therefore polls the DOM until cells appear, capturing the user-visible time.

## Raw numbers (warm cache, headless Chromium)

```
=== suite n=10 (strips=10, cells/strip=6, expected listitems=60) ===
Preact mount→DOM:           6.10 ms
Solid  mount→DOM:          33.30 ms     (Solid/Preact = 5.46)
Preact updates→DOM:   min=10.00 avg=16.37 max=22.40 ms (3 samples)
Solid  updates→DOM:   min=33.10 avg=33.57 max=34.30 ms     (Solid/Preact = 2.05)

=== suite n=50 (strips=50, cells/strip=6, expected listitems=300) ===
Preact mount→DOM:          16.00 ms
Solid  mount→DOM:          40.50 ms     (Solid/Preact = 2.53)
Preact updates→DOM:   min=9.60 avg=14.27 max=16.70 ms
Solid  updates→DOM:   min=33.10 avg=34.30 max=36.30 ms     (Solid/Preact = 2.40)

=== suite n=100 (strips=100, cells/strip=6, expected listitems=600) ===
Preact mount→DOM:          16.30 ms
Solid  mount→DOM:          28.80 ms     (Solid/Preact = 1.77)
Preact updates→DOM:   min=16.60 avg=19.53 max=25.10 ms
Solid  updates→DOM:   min=33.20 avg=33.27 max=33.40 ms     (Solid/Preact = 1.70)

=== suite n=250 (strips=250, cells/strip=6, expected listitems=1500) ===
Preact mount→DOM:          42.20 ms
Solid  mount→DOM:          31.20 ms     (Solid/Preact = 0.74)
Preact updates→DOM:   min=43.00 avg=43.73 max=44.30 ms
Solid  updates→DOM:   min=32.20 avg=35.97 max=39.30 ms     (Solid/Preact = 0.82)

=== suite n=500 (strips=500, cells/strip=6, expected listitems=3000) ===
Preact mount→DOM:          87.00 ms
Solid  mount→DOM:          47.10 ms     (Solid/Preact = 0.54)
Preact updates→DOM:   min=94.80 avg=102.57 max=108.00 ms
Solid  updates→DOM:   min=62.30 avg=63.47 max=64.30 ms     (Solid/Preact = 0.62)
```

## Observations

1. **Solid has a ~30 ms fixed overhead** that is independent of N. Mount and update times are roughly `30 ms + work_proportional_to_N`. The overhead is the `useEffect` → task-tier scheduling step before the Solid root actually mounts.
2. **Preact is purely linear in N** with no fixed overhead — `render()` is synchronous, cells appear within the same tick.
3. **Cross-over point ≈ 200 strips.** Below this, Preact wins. Above this, Solid wins because its per-cell render work scales better than the fixed 30 ms cost.

## Mapping to actual production usage

| Caller | Strip count per page render |
|--------|------------------------------|
| `feature-health.ts` | 1 |
| `governance.ts` | 1 |
| `harness-health.ts` | 3 |
| `safe-autonomy.ts` | 1 outer + N inner (one per domain row, typically <10) |
| `connector-status.ts` | 1 |
| `FunnelCard` (`overview/funnel.ts` via #12260) | 1 |

Maximum simultaneous strips on any production page: ~10. **Every actual usage falls in the Preact-wins region.**

## Sustained-load measurement (added 2026-04-30, addresses 16-keeper SSE workload)

The single-shot 3-sample suite above leaves a critical question unanswered: what happens when the dashboard is consuming a continuous SSE event stream from many keepers and the parent component re-renders many times per second? The bench was extended with two modes that target this shape — both at **n=16** (= production keeper count).

### Burst — 60 sequential updates at n=16

```
Preact: total 1019 ms, mean 16.98 ms, p95 20.60 ms, max 25.00 ms
Solid:  total 1987 ms, mean 33.12 ms, p95 35.80 ms, max 38.90 ms
```

A 60-update burst (one second of typical 1 Hz/keeper traffic over 16 keepers, compressed) takes Solid **2× longer** to drain. Every individual update is also 2× slower.

### Sustained 5-second window at n=16, target ≈30 Hz

```
Preact:   296 updates,  frames 296/300 (99%)  mean=16.89 p95=20.60 max=30.30 ms
Solid:    148 updates,  frames 296/300 (99%)  mean=33.97 p95=40.20 max=53.40 ms
  → throughput ratio Solid/Preact = 0.50
```

Preact sustains ~59 updates/sec; Solid sustains ~30 updates/sec. **Solid's throughput is exactly half** of Preact's at our production scale.

Both sides keep 99% frame retention because the rAF poll between updates yields naturally — but the throughput gap means that if SSE event arrival exceeds Solid's drain rate (~30 Hz), the queue grows and the UI shows stale data. Preact has roughly 2× the headroom before the same back-pressure starts.

### Implication for the 16-keeper case

If keepers emit at 1 Hz each (16 events/sec total) and the parent re-renders on every event:

| | Preact | Solid |
|--|--------|-------|
| Time to drain one event batch (n=16) | ~17 ms | ~33 ms |
| Steady-state CPU per second of stream | ~270 ms (27%) | ~530 ms (53%) |
| Headroom before queue grows | up to ~59 events/sec | up to ~30 events/sec |

The Solid path consumes roughly twice the main-thread budget for the same stream rate. At higher event rates (e.g. burst keeper-startup: 16 keepers × multiple state changes/sec), Solid will start lagging at a rate Preact would still keep up with.

### Caveats specific to sustained mode

- The bench drives both implementations through Preact `render()` at the top, so Preact's sync render cycle and Solid's `useEffect` → solid-root path are both included end-to-end.
- Headless Chromium with no concurrent workload — a real laptop with other tabs would amplify the absolute numbers but the ratio (Solid 2× slower) is the durable signal.
- Solid's 33 ms floor is dominated by `useEffect` task-tier scheduling. Targeted signal updates that bypass the parent re-render entirely (e.g. a dedicated keeper-state store the island reads via `createMemo`) would close most of the gap. That refactor is out of scope for the current `KpiStripIsland` shape, which takes a fresh `cells` array literal on every parent render.

## Caveats

- Headless Chromium has no concurrent workload; numbers may differ on a real laptop running the dashboard alongside other apps. The relative gap between the two implementations is what carries; absolute numbers will vary.
- The update measurement re-renders the entire tree each round (worst case for Preact). Solid's *targeted* signal updates (changing a single cell value through a stored ref) would be faster, but our caller pattern always re-renders from scratch on prop change because `cells` is a fresh array literal each parent render. Refactoring callers to keep persistent stores would shift the comparison, but is itself a non-trivial migration.
- The 30 ms overhead is dominated by `useEffect` scheduling. A different mounting strategy (e.g. `solidRender` called synchronously in the Preact component body during the first render) could close most of this gap, but would break the eventual-consistency model the test shim relies on, and require a redesign of `KpiStripIsland`.

## Synchronous-mount spike (RFC 0017 §7d, added 2026-04-30)

Recommendation 4 below proposed investigating a sync-mount strategy. That spike is now done: `kpi-strip-island-sync.ts` moves the Solid mount into a Preact ref callback (commit-phase synchronous) and the prop sync into `useLayoutEffect` (synchronous, before paint). Both shift the work out of task tier.

Numbers at n=16 (warm cache, headless Chromium):

```
Mount → DOM:
  Preact KpiStrip:          16.50 ms
  Solid useEffect island:   32.80 ms   ← shipping wrapper
  Solid sync-mount island:  16.80 ms   ← spike variant (kpi-strip-island-sync.ts)
    delta vs useEffect:     16.00 ms saved
    delta vs Preact:         0.30 ms slower

Update burst (60 sequential re-renders):
  Preact KpiStrip:          total= 991 ms, mean=16.51 ms
  Solid useEffect island:   total=1999 ms, mean=33.32 ms   ← shipping (~half throughput)
  Solid sync-mount island:  total=1008 ms, mean=16.80 ms   ← spike (parity with Preact)

  throughput sync/Preact:    1.02   (1.0 = parity)
  throughput sync/useEffect: 0.50   (sync mount is 2× the useEffect path)
```

The `useEffect` overhead is **eliminated** by the ref-callback approach. Sync-mount island reaches **parity with Preact** at our production scale.

**But parity is not a win.** This spike removes the latency *regression* the shipping wrapper introduces, but the original RFC 0017 promise — that Solid would be *faster* — is still unrealised. The reason: at small N with full prop replacement on every parent render, both Preact's diff and Solid's per-cell render do similar amounts of work. Solid's fine-grained reactivity advantage only surfaces when individual cells subscribe to their own signals and the parent doesn't recreate the `cells` array on every event.

For the RFC 0017 trajectory this means:

1. **Sync-mount can be promoted to production** as a low-risk improvement: removes the 30 ms regression on every page using a migrated caller, no API change, identical DOM contract.
2. **Phase 2 / Phase 3 islands stay paused** until the per-cell signal redesign (separate larger RFC) is done. Adding more sync-mount islands at parity gives no win, just larger frame budget consumption with no benefit.

## Recommendations

1. **Do not roll back blindly.** Bundle isolation (9.3 KB amortised after first caller, 0 B per subsequent caller), type safety, and the test-shim infrastructure are all clean wins; reverting them costs more than the latency we'd recover.
2. **Amend RFC 0017 §4.** The krausest citation does not generalise to our app shape. Replace it with these measured numbers and an explicit note that the migration was not justified by user-perceived latency *unless paired with a per-cell signal API*.
3. **Skip RFC 0017 §6 (Lifeline/Ticker islands) for now.** Per these numbers, more islands have no performance justification unless those components have N>200 cells (they do not) or use fine-grained signals (current API does not).
4. **Promote `KpiStripIslandSync` to the shipping wrapper** as a separate small PR. Spike result is unambiguous: removes the 30 ms regression, achieves parity with Preact. Risk is bounded — the wrapper is a thin Preact component, the Solid factory it imports is unchanged, and the existing test shim still works (it bypasses the wrapper entirely with `vi.doMock`).
5. **Per-cell signal API redesign** as a separate, larger RFC if real perf wins are needed. This would change `KpiStripIslandData` from `cells: ReadonlyArray<KpiCellProps>` to `cellSignals: ReadonlyArray<Accessor<KpiCellProps>>`, allowing callers to mutate one cell without recreating the array. Costly: every caller refactors its data flow.
6. **Keep the current migration as deliberate code organisation.** The Solid island gives us framework-agnostic primitives, a clean migration boundary, and a reusable test pattern (`vi.doMock` shim). Those are the actual wins to report — performance was not, until the sync-mount spike, which now gives us parity.

## Reproduction

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp/.worktrees/ds-v2-rfc0017-perf-bench/dashboard
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935 pnpm dev &

cd /tmp/rfc0017-bench   # or wherever the runner lives
node run-bench.mjs
```

The bench page is also reachable interactively at
`http://localhost:5173/dashboard/design-system/preview/bench-kpi.html`.
