---
rfc: "0132"
title: "Keeper Phase Casing SSOT Consolidation"
status: Draft
created: 2026-05-19
updated: 2026-05-19
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0046", "0088"]
implementation_prs: []
---

# RFC-0133 — Keeper Phase Casing SSOT Consolidation

> **Note**: Allocated as RFC-0131 in iteration #3 but renumbered to 0132 at
> merge prep time because PR #16323 ("Shell Command Gate facade") also
> claimed 0131 from the same ledger snapshot (recurrence of the pattern in
> `feedback_rfc_number_reservation_needed.md`). #16323 retains 0131.

## 1. Problem

The keeper `phase` value travels through **two parallel pipelines** with different casing conventions, mediated by **four duplicate normalizers** plus a **dual-keyed display map**. The same logical state — e.g. the keeper is alive and serving turns — surfaces on the dashboard as `Running`, `running`, or `가동 중` depending on which surface and which pipeline rendered it. The accumulation matches RFC-0088 §Symptom 억제 #4 (Repair / Sanitize) anti-pattern executed *four times*, plus RFC-0042 closed-sum boundary violation.

### 1.1 Concrete map of duplicate state

| Surface | Field | Format on the wire | Format consumed |
|---|---|---|---|
| Backend `Keeper_state_machine.phase_to_string` (lib/keeper/keeper_state_machine.ml:21-35) | KSM phase | `lowercase` + `snake_case` (`running`, `handing_off`) | — |
| `KeeperCompositeSnapshotSchema.phase` (dashboard/src/api/schemas/keeper-composite.ts:41,204) | composite endpoint | raw `string()`, no normalization at parse | `snapshot.phase` lowercase as-emitted |
| `Keeper.phase` (dashboard/src/types/core.ts:854-867) | flat keeper feed | TypeScript type declares `PascalCase` | `keeper.phase` PascalCase **after** `toKeeperPhase()` normalization |
| `toKeeperPhase()` (dashboard/src/keeper-store-normalize.ts:35-70) | normalizer #1 | lowercase → PascalCase | applied to flat field only |
| `monitoring-runtime.ts:159 normalizePhase` | normalizer #2 | lowercase → PascalCase | applied to monitoring fields |
| `keeper-state-diagram.ts:42-60` | normalizer #3 | dual-keyed map | applied to diagram input |
| `keeper-phase-strip.ts:16 toPascalPhase` | normalizer #4 | lowercase → PascalCase via regex | applied to transition events |
| `STATE_DISPLAY_NAMES` (dashboard/src/components/fsm-hub-types.ts:147-189) | display map | **both lowercase AND PascalCase keys** | both resolve to the same Korean label |

### 1.2 Effects observed in production

Pre-PR-1 (#16312), 11 `snapshot.phase === '<PascalCase>'` comparisons across three components silently evaluated to false because `snapshot.phase` arrives lowercase from the backend. PR-1 closed those dead branches by aligning compares with the wire format. The structural duplication that *enabled* the defect remains:

- New code can pick either casing and "work" via the four normalizers + dual-keyed display map, perpetuating the split.
- AI agents (Claude / Codex / Gemini) doing dashboard work learn the pattern from the codebase statistics and emit further dual-casing code (per RFC-0088 §Workaround Rejection Bar — *self-fulfilling spiral*).
- The schema docstring at `keeper-composite.ts:35-39` justifies open `string()` for forward-compat ("backend can ship new variants ahead of dashboard"); the same docstring then names `Stable/idle/clean` as undesirable normalization targets — implicitly admitting that consumers do exactly this elsewhere.

### 1.3 Why this is not just style

Same logical state is shown to the operator in three skins on a single keeper detail page. After PR-1:

- Page header (`keeper-detail-shell.ts:193 KeeperPhaseAndStage`) consumes `keeper.phase` (PascalCase normalized) → badge renders the Korean label via `PHASE_STYLES`.
- FsmHub body consumes `snapshot.phase` (lowercase raw) → various surfaces render the lowercase token raw, the Korean label via `displayState()`, or the badge via `PHASE_STYLES`.
- Some debug-style interpolations still print `KSM=running` lowercase deliberately for operator clarity in diagnostic strings.

The dual-keyed `STATE_DISPLAY_NAMES` papers over the casing split for the *Korean translation* path but not for raw template interpolations (`fsm-hub-invariant-analysis.ts:192 headline: \`${snapshot.phase} 가 활성 lifecycle edge\``).

## 2. Goals

1. **One canonical wire format on the dashboard side**: lowercase + snake_case, matching `phase_to_string` exactly. No parallel PascalCase domain.
2. **Zero normalizers**. The dashboard does not repair the wire — it consumes it as-is.
3. **Single display point**. `displayState()` is the only place that converts wire format → human-readable label.
4. **Closed-sum at the schema boundary** (RFC-0042). `KeeperCompositePhaseSchema` and the flat `Keeper.phase` schema both validate against the same canonical 13-state enum, with an explicit `unknown` carrier for forward-compat (preserving the schema docstring's stated drift-signal requirement).

## 3. Non-goals

- No change to backend OCaml. `phase_to_string` already emits the canonical wire format; the lift is dashboard-side only.
- No change to the 7-phase composite projection question (`Stable` carrier). That stays as a separate OOS item — RFC-0046 §7 OOS still owns it.
- No backwards-compatibility shims. Per 사용자 절대 원칙 (legacy 박멸), legacy PascalCase pathway is removed in the same PR that introduces the canonical form.

## 4. Design

### 4.1 Canonical type

```ts
// dashboard/src/types/core.ts
export const KEEPER_PHASE_VALUES = [
  'offline', 'running', 'failing', 'overflowed', 'compacting',
  'handing_off', 'draining', 'paused', 'stopped', 'crashed',
  'restarting', 'dead', 'zombie',
] as const

export type KeeperPhase = typeof KEEPER_PHASE_VALUES[number]

export function isKeeperPhase(s: string): s is KeeperPhase {
  return (KEEPER_PHASE_VALUES as readonly string[]).includes(s)
}
```

### 4.2 Schema boundary

```ts
// dashboard/src/api/schemas/keeper-composite.ts
const KeeperCompositePhaseSchema = pipe(
  string(),
  transform(s => isKeeperPhase(s) ? s : { unknown: s } as const),
)
```

Schema returns either a canonical `KeeperPhase` literal or a typed `{unknown: string}` carrier. Consumers `match` exhaustively; unknown variants surface explicitly in the UI rather than coercing to a sentinel.

### 4.3 Display point

`displayState()` accepts `KeeperPhase | {unknown: string}` and returns the Korean label or the raw unknown string. `STATE_DISPLAY_NAMES` loses its PascalCase keys — they were defensive double-coding for the now-unified wire format.

### 4.4 Deletion targets

- `toKeeperPhase()` / `BACKEND_PHASE_MAP` (keeper-store-normalize.ts:35-70) — DELETE.
- `normalizePhase` (monitoring-runtime.ts:159) — DELETE.
- `toPascalPhase` (keeper-phase-strip.ts:16) — DELETE.
- `keeper-state-diagram.ts:42-60` internal phase map — DELETE.
- All PascalCase keys in `STATE_DISPLAY_NAMES` (fsm-hub-types.ts:176-188) — DELETE.
- `keeper-memory-tier-panel.ts:164` defensive `phase === 'Compacting' || phase === 'compacting'` — REPLACE with single lowercase compare.

### 4.5 Consumer sweep

Every site comparing `keeper.phase === '<PascalCase>'` becomes `keeper.phase === '<lowercase>'`. Audited site count (pre-RFC):

| File | Compares to migrate |
|---|---|
| `keeper-reactivity-monitor.ts:192,225` | `'Paused' / 'Crashed' / 'Dead' / 'Zombie'` |
| `keeper-action-panel.ts:229` | `'Paused'` |
| `keeper-action-panel.ts:95-117` | already lowercase via `.toLowerCase()` — can drop the conversion |
| `keeper-state-diagram.ts` PascalCase-keyed maps | drop |
| `keeper-phase-indicator.ts:48 PHASE_STYLES` | rekey to lowercase |
| `monitoring-runtime.ts:54-55` `OFFLINE_PHASES / ATTENTION_PHASES` Set | rekey to lowercase |
| `keeper-phase-indicator.ts:64 BUFFER_PHASES` | rekey to lowercase |

Total estimated blast radius: 12-18 files. **All in one PR per 사용자 절대 원칙**; splitting creates N-of-M cycle (RFC-0088 §3 anti-pattern).

## 5. Migration phases

| Phase | Output | Verification |
|---|---|---|
| 0 | This RFC merged (Draft → Active on PR start) | RFC body merge |
| 1 | PR sweep: type flip + 4 normalizers deleted + consumer compares rekeyed + display map purged | `pnpm typecheck` clean, `pnpm vitest run` no new failures, `rg "'(Running\|Failing\|Compacting\|HandingOff\|Draining\|Overflowed\|Paused\|Stopped\|Crashed\|Restarting\|Dead\|Zombie\|Offline)'" dashboard/src/` → only test fixtures + scripts |
| 2 | Schema picklist + `{unknown}` carrier + exhaustive match conversion | parse-error test asserts unknown phase surfaces as `{unknown: 'newphase'}` not coerced |
| 3 | Closeout commit + RFC status → Implemented | grep audit shows zero PascalCase phase literals in dashboard runtime code |

Each phase is a single atomic PR. No transitional shims between phases.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Some component reads `keeper.phase` PascalCase and renders it raw (e.g. for tooltip), now produces lowercase | Phase-1 audit grep finds all template interpolations; wrap with `displayState()` where user-facing, leave raw for debug-style `KSM=<phase>` strings |
| Test fixtures break en masse | Migration includes fixture realign in the same PR (mock↔mock loophole closure — see `Test Mock: mock↔mock 순환검증` learning) |
| RFC-0046 follow-up tests (which expect PascalCase) | Updated in-place; RFC-0046 §1-6 merged already, no new conflicts |
| 7-phase composite projection (`Stable`) eventually emitted by backend | Out of scope — when backend ships, schema picklist adds the literal, consumers handle in exhaustive match |
| External tooling depending on dashboard types (other repos) | None known; if any surface, deprecation note in CHANGELOG |

## 7. Anti-pattern avoidance (RFC-0088)

- ❌ Adding a 5th normalizer or case-insensitive helper (workaround #2 string classifier, #4 Repair).
- ❌ Keeping dual keys "for safety" (defensive double-coding witnesses the split rather than closing it).
- ❌ Splitting consumer sweep across many PRs (N-of-M anti-pattern §3).
- ✅ Single PR removes the legacy domain entirely. Compiler enforces exhaustive matches.
- ✅ Schema picklist + typed unknown carrier closes the sum at the wire boundary (RFC-0042 closed-sum at boundary).

## 8. Acceptance criteria

- [ ] `KeeperPhase` is a closed sum of 13 lowercase + snake_case literals matching `phase_to_string` exactly.
- [ ] Zero normalizers convert phase casing on the dashboard. (`rg 'BACKEND_PHASE_MAP|toPascalPhase|normalizePhase' dashboard/src/` → 0 hits.)
- [ ] `STATE_DISPLAY_NAMES` keys are lowercase only.
- [ ] `KeeperCompositePhaseSchema` is a typed picklist + unknown carrier.
- [ ] `pnpm typecheck` clean; `pnpm vitest run` no new failures vs main baseline.
- [ ] No PascalCase phase literals in `dashboard/src/` runtime code (test fixtures excepted only if backend emits both — which it does not).
- [ ] Closeout commit lands on main.

## 9. Evidence Record

- Evidence:
  - `lib/keeper/keeper_state_machine.ml:21-35` `phase_to_string` — backend lowercase 13-state emit.
  - `lib/keeper/keeper_composite_observer.ml:628` — composite passes the same value.
  - `dashboard/src/components/keeper-phase-strip.ts:15` — explicit "Server sends lowercase" witness comment.
  - `dashboard/src/keeper-store-normalize.ts:35-70` — normalizer #1.
  - `dashboard/src/lib/monitoring-runtime.ts:159-172` — normalizer #2.
  - `dashboard/src/components/keeper-state-diagram.ts:42-60` — normalizer #3.
  - `dashboard/src/components/keeper-phase-strip.ts:16-20` — normalizer #4.
  - `dashboard/src/components/fsm-hub-types.ts:147-189` `STATE_DISPLAY_NAMES` dual-keyed map.
  - `dashboard/src/types/core.ts:854-867` PascalCase `KeeperPhase` type.
  - PR-1 (#16312, fix/keeper-phase-case-ssot-20260519) — closed 11 dead PascalCase compares on `snapshot.phase` but kept the parallel domain intact.
- Timestamp: 2026-05-19T01:30+09:00 (KST).
- Confidence: High. All claims verified by direct file read + `rg -n` measurement.
- Delta: PR-1 fixed the immediate dead-branch defect. This RFC scopes the structural closure so future PRs (AI or human) cannot reintroduce the casing split.

## 10. Out of scope (separate RFCs)

- 7-phase composite projection with `Stable` carrier — RFC-0046 §7 OOS still owns; either backend ships projection or dashboard drops `collapsed_from` semantics.
- Keeper `status` field casing (separate axis, `keeper-store-normalize.ts:72-89 normalizeKeeperAgentStatus`). Investigate if same Repair pattern applies; likely yes, deserves its own RFC if so.
