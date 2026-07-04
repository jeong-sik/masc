# Dashboard Frontend-Improvement — Sequenced Execution Backlog

Status: Active · Created 2026-07-04 · Owner vincent
Scope: `dashboard/` (Preact + `@preact/signals` + `htm`). **Framework change is out of scope** — improve within the current stack (see the framework adversarial review: keep Preact, consolidate stacks).

## Baseline (measured, worktree `feat/dashboard-fe-improvement` @ main `fb59401289`)

- 1,265 `.ts/.tsx` files, ~302K LOC. **153 files > 500 LOC, 78 > 800, 32 > 1200** (300-line guideline).
- Gates (must stay green through every slice): `tsc --noEmit` = **0 errors**; `eslint src` = **0 errors**; vitest suites green.
- Perf harness present: `src/lib/performance-monitor.ts` (LoAF `blockingDuration`), `src/utils/performance-metrics.ts`, `src/utils/fps-adaptive.ts`; bundle report via `BUNDLE_REPORT=1 pnpm build` (rollup-plugin-visualizer).

Backlog produced by a mapped + **adversarially-verified** analysis (3 finders → per-slice verify → synthesis). Verification dropped/downgraded overstated claims; corrections are folded in below.

## 1. Strategy

Bank the low-risk, compiler-checkable, behavior-preserving wins first (typed-union SSOT), because they also *carve down* the giant files the expensive refactors must later move. Do performance work **only behind measurement** (measure → cheap mitigation → windowing only if justified). Anything that changes user-visible behavior or that verification downgraded to marginal becomes an RFC, not an opportunistic PR. Keep `main` green; enter the risky refactors on a smaller, better-typed codebase.

## 2. Ranked backlog

| # | Slice | Axis | Risk | Effort | Behavior-preserving | Status |
|---|-------|------|------|--------|---------------------|--------|
| 1 | Shared typed delivery classifier (`lib/keeper-delivery.ts`) | ssot | low | S | yes | **DONE** (this branch) |
| 2 | Total parsers for 4 store-normalizer unions | ssot | low | M | yes | **DONE** (this branch) |
| 3 | Connector vocabulary extraction (`connector-constants.ts`) | ssot | low | M | yes | **DONE** (this branch — SSOT only; cycle NOT broken, see note) |
| 4 | Transcript off-screen cost (`content-visibility` first, windowing = RFC) | perf | med | M | no | Wave 2 (measure-gated) |
| 5 | Decompose `chat/primitives.ts` along concern boundaries | refactor | med | L | yes | Wave 3 (after 1) |
| 6 | `fsm-hub` prop→state derivation (store-prev-during-render) | refactor | med | S | no (naive fix regresses) | Wave 3 |
| 7 | Unify 6 "running keeper" status sets | ssot | med | M | **no** | **RFC** |
| 8 | Connector-status fine-grained signal decomposition | perf | high | L | yes | **RFC** / fold into 5 |
| 9 | IDE reference-kind alias SSOT | ssot | med | M | yes | Optional/last (dup ≈ 6 tokens) |
| 10 | Content-derived keys for ChatBlock list | refactor | low | S | questionable | **DROP** (mechanism refuted) |

## 3. Waves

**Wave 1 — low-risk SSOT + safe extractions (behavior-preserving, `tsc`+vitest green, no user-visible change):**
- Slice 1 (delivery classifier) — **done**
- Slice 2 (store-normalizer total parsers) — needs a completeness check (`type _Covered = Exclude<T, typeof VALUES[number]> extends never ? true : never`); preserve each callsite's exact normalization (taskStatus trims+lowercases; executionTone lowercases only; signalTruth/evidenceSource case-sensitive). Severity SSOT is `types/dashboard-execution.ts` `DashboardExecutionTone`, not `core.ts`. Helper is `assertExhaustive`.
- Slice 3 (connector vocabulary) — **DONE, SSOT-only.** Extracted the pure vocabulary (KNOWN_CONNECTOR_IDS, display names, sidecar commands, accent style, channel icon) to `connector-constants.ts` (a leaf — imports nothing from connector-status, so no new cycle); connector-status re-exports for back-compat; skeleton/onboarding repointed. **Cycle NOT broken and NOT claimed:** the sidecar actions (start/stop/bind) close over connector-status's signal-backed UI state (`patchConnectorUiState`/`refresh`), so they cannot move to a `connector-actions.ts` without dragging that state — verified by reading the action bodies. Breaking the cycle needs the UI-state store extraction (Slice 8/RFC). State-label helpers (`connectorStateLabel`/`connectorCardBorderClass`) also stayed (share the file-local exhaustiveness helper). Bundle-shrink claim deferred to Wave-2 `BUNDLE_REPORT=1` measurement. Gates: tsc 0, eslint 0, vitest (4 connector suites +42, panel 37) green.

**Wave 2 — performance, measurement-gated:**
- Slice 4: measure first (`performance-monitor` LoAF + a memo render counter) on a synthetic 500+ entry streaming transcript; ship the cheap `content-visibility:auto` row wrapper (mirrors `virtual-list.ts:242-259`) *before* any windowing; gate on real transcript-length distribution.
- Slice 3 bundle claim: `BUNDLE_REPORT=1 pnpm build` before/after; if Rollup already tree-shakes the panel, record SSOT-only with no bundle assertion.

**Wave 3 — deep refactors (after Wave 1):**
- Slice 5: depends on Slice 1 (done) + media-union typing; boundaries follow import cohesion, verify no new cycles (`madge`), `primitives.test.ts` must stay green unchanged.
- Slice 6: only via store-prev-prop-during-render; the `?? fallback` regresses tab/keyboard/dead-keeper selection in the main monitoring panel.

## 4. RFC / drop callouts

- **Slice 7 → RFC.** The 6 callsites do not answer the same question: `overview.ts:646` reads session status; `runtime-counts.ts:92` reads runtime tokens where `idle`=running is deliberate; `unified-status.ts:53` + `keeper-detail-lifecycle.ts:20` document `'working'` as an intentionally-outside-SSOT UI `PulseState`. Needs a written predicate taxonomy (`isKeeperRunning` vs `isKeeperPresent`) + per-callsite before/after membership snapshot.
- **Slice 8 → RFC / fold into Slice 5.** Children (`ConnectorGateCard`, `BindingRow`, `GateStatusStrip`, `ConnectorsGateGrid`) already exist; the work is pushing `connectorStatusResource.state.value` reads down. Justify with a measured per-subcomponent render counter first.
- **Slice 4 true windowing → RFC.** Only the `content-visibility` step is a direct PR. Windowing must preserve scroll-pin-to-bottom during streaming, unread-divider anchoring, and folding heterogeneous non-bubble units into a flat measured `items[]`.
- **Slice 10 → DROP.** List component type is constant (`ChatBlock`), so index keys update-in-place for append-only streams; highlight/mermaid effects are value-dep-guarded. Content keys would add tail remounts (net regression). Discriminant is `block.t`, not `block.type`.

## 5. Slice 1 — completed record

One compiler-checked home for `KeeperConversationDelivery` (10 variants) classification.

- New `src/lib/keeper-delivery.ts`: `IN_FLIGHT_DELIVERY {queued,sending,streaming}` + `FAILED_DELIVERY {error,timeout,interrupted}` as `const satisfies ReadonlyArray<KeeperConversationDelivery>`, Set-backed `isInFlightDelivery` / `isFailedDelivery` (mirrors `lib/agent-status.ts`).
- Migrated 4 callsites: `keeper-state.ts:1132` (moved the private fn), `keeper-shared.ts:234` (kept the `role==='assistant' && source==='direct_assistant'` guard), `chat/primitives.ts:229` (`bubbleTone`), `chat/primitives.ts:1988` (kept the `&& !!entry.error?.trim()` conjunct). `keeper-stream.ts` untouched (evidence-only; the original "3×" claim was wrong — 2×).
- New `keeper-delivery.test.ts`: `Record<KeeperConversationDelivery, ...>` forces compile-time exhaustive coverage; runtime asserts the 10 variants partition into exactly one of {in-flight, failed, other} and the two sets are disjoint.
- Gates: `tsc --noEmit` 0 errors · `eslint src` 0 errors · vitest 172 pass (keeper-delivery, keeper-state, primitives). Behavior-preserving.
