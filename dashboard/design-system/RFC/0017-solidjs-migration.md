# RFC 0017 — SolidJS Cockpit Migration

> **Status**: KpiStrip migration **complete** (#12162 → #12268). Performance hypothesis **falsified** for our app shape — see [`0017-solidjs-migration-measurement.md`](./0017-solidjs-migration-measurement.md) (2026-04-30). Phase 2 (Lifeline) and Phase 3 (Ticker) **paused** pending a synchronous-mount spike.
> **Date**: 2026-04-30
> **Relation to RFC 0013**: Amends RFC 0013 (cockpit-migration). RFC 0013 specified Preact for Phase 1 (KpiStrip), 2 (Lifeline), 3 (Ticker). This RFC supersedes the framework choice based on (then-projected) performance evidence; the phasing and component scope from RFC 0013 are preserved. Section 1 below records the original projection; the measurement companion document records what we actually observed.

## 1. Motivation (original projection — see §7 for the post-implementation reality)

The MASC Cockpit's "extreme information density" target — 1,000+ live KPI updates, 100K+ row event feeds, 24/7 runtime — exposes the Virtual DOM cost paid on every Preact re-render. krausest benchmark (Chrome 146, M4) shows Preact Hooks at geometric mean **1.40** vs vanilla baseline 1.00. SolidJS measures **1.12** (~3-4× closer to vanilla). For partial updates and single-row selection — the cockpit's dominant pattern — SolidJS is 26-52% faster.

Memory follows the same shape: VDOM trees are a permanent in-memory representation. SolidJS's signal subscription graph is ~50% smaller for equivalent state.

| Operation | Preact Hooks | SolidJS | Improvement |
|-----------|--------------|---------|-------------|
| create 1K rows | ~31ms | ~23ms | **26%** |
| partial update | ~14.5ms | ~10.7ms | **26%** |
| select row | ~6.5ms | ~3.1ms | **52%** |
| ready memory | ~1.2 MB | 0.56 MB | **53%** |
| run memory (1K) | ~3.5 MB | 2.64 MB | **25%** |

Source: krausest/js-framework-benchmark, Chrome 146.

## 2. Why SolidJS over Svelte 5 / Leptos

The performance analysis at `/Users/dancer/Downloads/masc-cockpit-performance-analysis.md` weighed all four candidates. Summary:

| Framework | Migration cost | MASC fit | Rationale |
|-----------|----------------|----------|-----------|
| **SolidJS** | **3-4 weeks** | 88/100 | JSX 90% compatible; fastest path; ecosystem (Ark UI, corvu) covers headless |
| Svelte 5 | 8-12 weeks | 92/100 | Best long-term fit but full DSL switch |
| Leptos (WASM) | 12-16 weeks | 78/100 | Highest perf for partial update but JS interop drag |
| Vanilla + Lit | 6-8 weeks | 75/100 | Zero runtime but 2-3× hand-written code |

SolidJS is chosen for the smallest incremental transition cost given our headless-core base. Svelte may revisit if we identify a >6mo runway and a willingness to retool DX.

## 3. Strategy: Adapter Swap, Core Reuse

The framework-agnostic `headless-core/` (17 primitives) is reused **unchanged**. The 12 `headless-preact/` adapters are progressively re-implemented as `headless-solid/`. Production components migrate one at a time as **Solid islands** (Solid subtree mounted inside the Preact app), with a fallback path to the original Preact component if the island regresses.

This makes the migration:
- **Reversible** — each PR rolls back independently.
- **Measurable** — bundle and runtime numbers per island vs Preact baseline.
- **Co-existent** — no flag day. Preact + SolidJS run together until the last island is migrated.

## 4. Phased Plan

| PR | Scope | Production touch | Risk |
|----|-------|------------------|------|
| **#1 (this PR)** | RFC + build config + `use-task-queue` Solid adapter + hidden preview page | None | Low |
| #2 | Solid adapters for `use-toasts`, `use-portal`, `use-tabs` | None | Low |
| #3 | KpiStrip → Solid island (replace `src/components/kpi-strip.ts`) | First production | Medium — first measurable |
| #4 | If #3 metrics validate: Lifeline + Ticker islands. Else: rollback + post-mortem | Production | Medium |
| #5+ | Remaining adapters + EventFeed virtual scroller migration | Production | Highest |
| #N | Drop Preact deps, swap `jsxImportSource` to `solid-js` globally | Cleanup | Low |

## 5. Coexistence Mechanism

| Concern | Resolution |
|---------|-----------|
| **JSX runtime split** | tsconfig stays `jsxImportSource: "preact"`. Solid files opt-in via per-file `/** @jsxImportSource solid-js */` pragma. |
| **Vite plugin order** | `vite-plugin-solid` registered **before** `@preact/preset-vite` with `include` regex limiting Solid's JSX transform to `design-system/headless-solid/` and `design-system/preview/solid-*` paths. |
| **Bundle isolation** | `solid-js` chunked separately from `vendor` (Preact) in `manualChunks`. Bundle delta measurable per PR. |
| **Signal name clash** | `@preact/signals.createSignal` and `solid-js.createSignal` are namespaced via folder split. eslint enforcement deferred to PR #2. |
| **Test runner** | `@testing-library/preact` and `@solidjs/testing-library` coexist under happy-dom; vitest already configured. |

## 6. PoC Scope (this PR)

Files created:
- `dashboard/design-system/headless-solid/use-task-queue.ts` — Solid adapter mirroring `headless-preact/use-task-queue.ts`. Returns accessor (Solid convention) instead of value.
- `dashboard/design-system/headless-solid/use-task-queue.test.ts` — same scenarios as Preact version, using `@solidjs/testing-library`.
- `dashboard/design-system/headless-solid/README.md` — adapter conventions for next PRs.
- `dashboard/design-system/preview/solid-poc.tsx` — demo component using the adapter.
- `dashboard/design-system/preview/solid-poc.html` — standalone preview page (not linked from index).

Files modified:
- `dashboard/package.json` — adds `solid-js`, `vite-plugin-solid`, `@solidjs/testing-library`.
- `dashboard/vite.config.ts` — registers Solid plugin scoped to PoC paths; adds `solid` chunk.

Out of scope for this PR: any change to `dashboard/src/components/`, eslint rules, CI gates, perf measurement.

## 7. Verification

### 7a. Original PR #1 acceptance criteria

PR #1 succeeds when all of the following hold:
1. `pnpm install` clean — no peer-dep conflicts.
2. `pnpm typecheck` passes — dual JSX runtimes resolve.
3. `pnpm test design-system/headless-solid/use-task-queue` — Solid adapter tests pass. **This is the load-bearing check** — proves the headless-core primitive is genuinely framework-agnostic.
4. `pnpm build` produces a separate `solid-*.js` chunk; `index-*.js` size unchanged.
5. `pnpm dev` and `solid-poc.html` renders, button clicks update list, HMR works.

### 7b. Post-implementation measurement (2026-04-30)

After 7 sequential PRs (#12162 → #12268) migrated 6 callers, headless Chromium measurement (`bench-kpi.html` + puppeteer runner) produced the numbers in [`0017-solidjs-migration-measurement.md`](./0017-solidjs-migration-measurement.md).

**Headline**: KpiStripIsland adds a ~30 ms fixed mount overhead vs Preact KpiStrip, dominated by `useEffect` task-tier scheduling. The cross-over point (where Solid's faster per-cell work amortises the fixed cost) is around N=200 strips. **Every production page using the migrated callers has N ≤ 10**, so the migration is a net latency regression on our app shape.

| Workload | Preact | Solid island | Solid wins? |
|----------|--------|--------------|-------------|
| Mount n=10 | 6.10 ms | 33.30 ms | ❌ (5.5×) |
| Mount n=100 | 16.30 ms | 28.80 ms | ❌ (1.8×) |
| Mount n=250 | 42.20 ms | 31.20 ms | ✅ (0.74×) |
| Mount n=500 | 87.00 ms | 47.10 ms | ✅ (0.54×) |
| Update n=10 | 16.37 ms | 33.57 ms | ❌ (2.0×) |
| Update n=500 | 102.57 ms | 63.47 ms | ✅ (0.62×) |

### 7c. Sustained-load measurement (16-keeper SSE workload, added later same day)

The single-shot 3-sample numbers above don't tell us what happens when the dashboard is consuming a continuous SSE event stream. Added a sustained-mode bench at **n=16** (= production keeper count):

| Mode | Preact | Solid island |
|------|--------|--------------|
| Burst (60 sequential updates @ n=16) | 1019 ms total, mean 16.98 ms/update | 1987 ms total, mean 33.12 ms/update |
| 5 s sustained window @ n=16 | **296 updates** (~59 Hz), 99% frame retention | **148 updates** (~30 Hz), 99% frame retention |

**Solid throughput is exactly half of Preact's** at our production scale. Frame retention is 99% on both because the rAF poll between updates yields naturally — but the throughput gap means Solid will start lagging the SSE queue at event rates Preact still keeps up with. For a 16-keeper × 1 Hz/keeper stream Preact uses ~27% of a second of main-thread time; Solid uses ~53%.

**What we kept anyway**: bundle isolation (9.3 KB amortised, 0 B per subsequent caller), `headless-core` framework-agnosticism proven, reusable `vi.doMock` test-shim pattern, file-boundary transform isolation for Preact↔Solid coexistence. Those are real wins that justify the migration *as code organisation*, not as latency improvement.

The krausest figures in §1 do not generalise to our usage shape (small N, but high update rate from SSE). The companion measurement document records what we actually observed and recommends Phase 2 (Lifeline) and Phase 3 (Ticker) be paused pending a synchronous-mount spike that could close the 30 ms `useEffect` gap.

## 8. Rollback Criteria

This RFC is rolled back (and PR #N reverted) if:
- A production island (PR #3+) shows >5% regression in any of: input latency, frame budget, ready memory.
- Vite plugin coexistence breaks Preact HMR or bundle determinism in CI.
- Solid ecosystem gap (Headless UI, ARIA primitives) requires >2 weeks of in-house re-implementation per primitive.

## 9. Out of Scope

- Server-side rendering or hydration — cockpit is SPA-only.
- Migration of unrelated Preact apps in the monorepo (none exist today).
- Performance comparison with Svelte 5 / Leptos / Lit — re-evaluate if SolidJS PoC fails.
