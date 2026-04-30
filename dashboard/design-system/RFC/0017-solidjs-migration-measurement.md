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

## Caveats

- Headless Chromium has no concurrent workload; numbers may differ on a real laptop running the dashboard alongside other apps. The relative gap between the two implementations is what carries; absolute numbers will vary.
- The update measurement re-renders the entire tree each round (worst case for Preact). Solid's *targeted* signal updates (changing a single cell value through a stored ref) would be faster, but our caller pattern always re-renders from scratch on prop change because `cells` is a fresh array literal each parent render. Refactoring callers to keep persistent stores would shift the comparison, but is itself a non-trivial migration.
- The 30 ms overhead is dominated by `useEffect` scheduling. A different mounting strategy (e.g. `solidRender` called synchronously in the Preact component body during the first render) could close most of this gap, but would break the eventual-consistency model the test shim relies on, and require a redesign of `KpiStripIsland`.

## Recommendations

1. **Do not roll back blindly.** Bundle isolation (9.3 KB amortised after first caller, 0 B per subsequent caller), type safety, and the test-shim infrastructure are all clean wins; reverting them costs more than the latency we'd recover.
2. **Amend RFC 0017 §4.** The krausest citation does not generalise to our app shape. Replace it with these measured numbers and an explicit note that the migration was not justified by user-perceived latency.
3. **Skip RFC 0017 §6 (Lifeline/Ticker islands) for now.** Per these numbers, more islands have no performance justification unless those components have N>200 cells. They do not.
4. **Investigate a synchronous mount strategy** as a future spike. If the 30 ms `useEffect` overhead can be eliminated, the cross-over point shifts down toward our actual usage and the migration becomes a real win. This is worth a separate, scoped RFC.
5. **Keep the current migration as deliberate code organisation.** The Solid island gives us framework-agnostic primitives, a clean migration boundary, and a reusable test pattern (`vi.doMock` shim). Those are the actual wins to report — performance is not.

## Reproduction

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp/.worktrees/ds-v2-rfc0017-perf-bench/dashboard
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935 pnpm dev &

cd /tmp/rfc0017-bench   # or wherever the runner lives
node run-bench.mjs
```

The bench page is also reachable interactively at
`http://localhost:5173/dashboard/design-system/preview/bench-kpi.html`.
