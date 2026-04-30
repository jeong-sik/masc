# Phase 2 Implementation Gap Audit (2026-04-29)

DS-Drift Phase 2 spec defines 21 zones across 4 tracks (Work / Comms / Observability / Cognition) plus the `I0` IDE backbone. Phase 1/2 (CSS token reconciliation) is closed. This audit measures the gap between the **preview spec** (`dashboard/design-system/preview/cb-group-{c..h}.jsx` consumed by `cb-root.jsx`) and the **production runtime** (`dashboard/src/components/...` mounted from `dashboard/src/config/navigation.ts`) for the **6 zones with at least partial production code**.

Out of scope: 15 zones with **zero production surface** (G3 Accountability, C1/C2/C3 Comms, O2 Audit Ledger, O4 Cost & Latency, O5 Heuristic + Stress, K2 Decisions / Memory, K3 Institution Episodes, the 5 IDE backbone E1–E5 surfaces, plus I0 itself). Those need separate scoping and are not addressed here.

## Methodology

For each in-scope zone:

1. Locate the preview `DCSection` in `cb-root.jsx` (lines 155–246) and its `DCArtboard` variant set.
2. Read the variant component bodies in `cb-group-d.jsx` (G1/G2), `cb-group-f.jsx` (O1/O3), `cb-group-h.jsx` (K1/K4) to record vocabulary, mock-data shape, and layout.
3. Identify production candidates (`rg`-confirmed, exports listed in this audit) and read the entry function plus the surrounding state plumbing.
4. Record the gap as a fixed matrix (variant coverage / vocabulary / data layer / visual / routing).
5. Size the reconciliation effort: **Low** = config or copy fix, ≤1 file. **Mid** = new component or refactor in one module. **High** = new data source / API contract, ≥3 files or backend touch.

`rg` was used for symbol search. `Read` was used for spot reads. Files >300 LOC were read in slices. No production or preview code was modified.

## Summary

| Zone | Preview variants | Production variants | Variant coverage | Data shape match | Effort | Recommendation |
|------|------------------|---------------------|------------------|------------------|--------|----------------|
| G1 Goal Zone | 3 (Horizon / Tree / Snapshot) | 1 (`GoalTree`) + horizon strip in `Planning` | 1 of 3 | partial (no `progress`/`total`) | **High** | needs backend metric fields + 2 new variants |
| G2 Task Zone | 3 (Backlog / StaleAlert / Wall) | 1 (`TaskBacklog` kanban) | 1 of 3 (different layout) | partial (no `claim_age`/`drift`) | **Mid** | one new component each for Stale + Wall |
| O1 Cascade Inspector | 3 (List / DeepDive / Compare) | adjacent (`StrategyTraceTable` rows) inside `CascadeConfigPanel` | 0 of 3 zone-shape | partial — strategy trace ≠ `cascade_audit.jsonl` hop schema | **High** | new surface; deep-dive/compare absent; backend audit-feed needed |
| O3 Safe Autonomy | 3 (Dashboard / ByKeeper / Trend) | 1 (`SafeAutonomyPanel`) | 1.5 of 3 (Dashboard fully, ByKeeper merged into KeeperCard) | mostly aligned | **Low–Mid** | Trend variant missing; Dashboard layout ≈ matches |
| K1 Keeper Inspector v2 | 3 (BDI / ToolAccess / TokenStats) | inline fragments inside `KeeperDetailPage` + `KeeperConfigPanel` | 0.5 of 3 (BDI fields exist, no zone) | matches per-keeper; cross-keeper aggregate absent | **Mid** | BDI is fragments not panel; cross-keeper TokenStats absent |
| K4 Autoresearch | 3 (LoopList / FindingCard / HypothesisFlow) | 1 (`Autoresearch` w/ `LoopSelector`/`LoopDetailView`) | 1 of 3 (different mental model) | **conflict** — production = self-improvement loop (cycles, keep/discard, score), preview = research loop (hypothesis/evidence/conclusion, confidence) | **High** | data-model conflict; not just UI gap |

**Aggregate**: preview spec describes **18 variants** across 6 zones. Production renders an equivalent of **~5.5 variants** with **2 schema mismatches** (G1 metric fields, K4 loop semantics). Reconciliation is not a uniform "build the missing variants" job; one zone (K4) needs an explicit decision before any UI work.

---

## G1 · Goal Zone

### Preview spec — `cb-root.jsx:155-159`, `cb-group-d.jsx:30-191`

| Variant | Slot id | Component | LOC | Vocabulary |
|---------|---------|-----------|-----|------------|
| A · Horizon track (단/중/장) | `gz-hor` | `GoalHorizonTrack` | 49 | `ZoneHeader` + 3 `gz-track` columns (short/mid/long) × `gz-card` per goal with `phase`/`progress`/`total`/`metric`/`target_value`. Shows `single percent` + bar. |
| B · Metric tree (parent → child) | `gz-tree` | `GoalMetricTree` | 59 | `gz-hdr` + flat `gz-tree-row` (level 1 root + level 2 child by `parent` id), columns: `title/metric · progress · phase`. |
| C · Snapshot diff | `gz-snap` | `GoalSnapshotDiff` | 49 | `gz-snap-row` with paired `yesterday → today` blocks; renders `phase shift` indicator. |

Mock data (`window.MASC_P2.goals`, `goalSnapshots`) shape: `{id, horizon, title, metric, target_value, progress, total, phase, status, parent}` and `{goal, yesterday:{progress,total,phase}, today:{progress,total,phase}}`.

### Production — `dashboard/src/components/goals/`

- `goals.ts` (4 LOC) — barrel: re-exports `Planning`.
- `goals/planning.ts` (309 LOC) — `Planning` (mounted at `workspace?section=planning`). Renders: status summary card, `TaskBacklog`, `KeeperToolActivity`, plus a small "장기 목표" strip that lists short/mid/long counts only. Uses `groupedByHorizon` (`goal-helpers.ts:73`).
- `goals/goal-tree.ts` (1119 LOC) — `GoalTree` component, navigated to via `workspace?section=planning&view=goal-tree`. Renders parent→child tree with verification quorum, horizon labels (`horizonLabel` 단/중/장), and review notes.
- `goals/goal-helpers.ts` (212 LOC) — `groupedByHorizon`, `horizonLabel`, `horizonColor`, `priorityStars`, `goalPhaseLabel`.
- `Goal` type (`dashboard/src/types/core.ts:294-312`): `{id, horizon, title, metric?, target_value?, due_date?, priority, status, phase, verifier_policy?, parent_goal_id?, ...}`. **No `progress`/`total` fields.**

### Gap matrix — G1

| Aspect | Preview | Production | Gap |
|--------|---------|------------|-----|
| Variant A (Horizon track) | dedicated 3-column visual track with progress bars | `Planning` shows pill-counts only ("단기 N · 중기 N · 장기 N") | layout + per-goal cards absent |
| Variant B (Metric tree) | flat 2-level tree, columns `metric/progress/phase` | `GoalTree` renders n-level tree with verification policy and phase | partial — production tree is richer but does not surface `metric`/`target_value` columns |
| Variant C (Snapshot diff) | yesterday vs today comparison rows | absent | full miss; no historical snapshot data source |
| Data layer | `progress`/`total` numeric pair per goal | `Goal` has neither | **schema gap** — needs backend extension or derived computation from tasks |
| Routing | spec links to `components.html#goal-zone` | `workspace?section=planning` → `Planning`; `workspace?section=planning&view=goal-tree` → `GoalTree` | navigation shape differs from preview cards |

### Recommendation — G1

- Variant B: closest match. Add `metric`/`target_value` columns to `GoalTree` if metric data exists (Low).
- Variant A: needs a new component (`GoalHorizonTrack`) plus `progress/total` source. Either derive from task counts under each goal (medium effort) or extend backend `Goal` (High).
- Variant C: requires `goal_snapshots` data source. Defer until product decides whether snapshots are kept.

Effort: **High** — Variant C and the schema decision dominate.

---

## G2 · Task Zone

### Preview spec — `cb-root.jsx:161-165`, `cb-group-d.jsx:197-351`

| Variant | Slot id | Component | LOC | Vocabulary |
|---------|---------|-----------|-----|------------|
| A · Backlog (filter chips) | `tz-bl` | `TaskBacklog` | 64 | `ZoneHeader` + 5-button filter radiogroup (`all/running/queued/fail/done`) + flat `<table>` columns: `id, status, title, branch, keeper, goal, age`. `drift` flag rendered as red pill. |
| B · Stale-claim alert | `tz-st` | `TaskStaleAlert` | 41 | `tz-alert` rows with `who`/`why`/3-button toolbar (`nudge`/`force-release`/`reassign`); filter rule = `claim_age` ends in `h` or `>10` minutes. |
| C · Per-keeper task wall | `tz-wall` | `TaskWall` | 42 | `tz-wall` 8-column grid keyed by keeper id; per-keeper `KeeperBadge` + count + per-task chip with `id` + `title`. |

Mock data (`window.MASC_P2.tasks`) shape: `{id, status, title, branch, keeper, goal, age, drift, claim_age, tools}`.

### Production — `dashboard/src/components/goals/`

- `kanban-components.ts` (359 LOC) exports `TaskBacklog`. Same name, very different shape: kanban with **4 columns** (`할 일`, `진행 중`, `검증 대기`, `완료`), search input, `done` pagination. No flat table view, no filter chips by status, no `branch`/`drift` columns.
- `task-activity-list.ts` (182 LOC) — per-task activity tail (different surface).
- `task-detail-overlay.ts` (502 LOC) — overlay opened on task click; renders activity feed + goal relations.
- No `TaskStaleAlert`, no `TaskWall`. `rg "stale|TaskWall|StaleAlert"` returns zero hits in `goals/`.
- `Task` type (`types/core.ts`): no `drift`, no `claim_age`, no `branch` field surfaced in UI flow today.

### Gap matrix — G2

| Aspect | Preview | Production | Gap |
|--------|---------|------------|-----|
| Variant A | flat table + status filter chips + drift column | kanban columns + search + pagination | **shape conflict**, both named `TaskBacklog`; not a missing variant, an alternate visualization |
| Variant B | dedicated stale-claim surface with action toolbar | absent | full miss |
| Variant C | per-keeper grid wall | absent (per-keeper visible only inside `KeeperToolActivity` strip) | full miss |
| Data layer | `claim_age`, `drift`, `branch`, `tools` in mock | `Task` exposes status/priority/assignee but no `claim_age`/`drift`; `branch` not surfaced | partial — fields likely exist on backend but not consumed |
| Routing | links to `#task-zone` | TaskBacklog mounted via `Planning` (`workspace?section=planning`); no separate route for stale or wall | nav split needed |

### Recommendation — G2

- Variant A: do not replace the kanban; add the flat-table view as an alternate `view=` parameter on `Planning` (Low–Mid).
- Variants B + C: each ~one new file. `TaskStaleAlert` needs `claim_age`/`drift` fields plumbed (Mid). `TaskWall` is mostly grouping logic over existing tasks (Low–Mid).

Effort: **Mid**.

---

## O1 · Cascade Inspector

### Preview spec — `cb-root.jsx:194-198`, `cb-group-f.jsx:15-89`

| Variant | Slot id | Component | LOC | Vocabulary |
|---------|---------|-----------|-----|------------|
| A · Cascade list (multi-run) | `cs-list` | `CascadeList` (uses `CascadeCard`) | 9 | list of cascade-run cards; each card = header (`id`, `cascade`, `trigger`, `at`, outcome pill) + ordered `hops` (`step/model/status/ms/reason`) + footer (`primary/hops/total/selected`). |
| B · Failed run · deep dive | `cs-deep` | `CascadeDeepDive` | 9 | single-run `CascadeCard` with `showPool`: adds `configured pool` strip with hit/tried highlight. |
| C · Failure vs success compare | `cs-cmp` | `CascadeCompare` | 11 | 2-col grid with one ok + one error card, `compactModel` mode. |

Mock data (`window.MASC_P2.cascadeAudit`): `{id, cascade, trigger, at, outcome, error_category, configured[], primary, selected, total_ms, hops:[{i, model, status, ms, reason?}]}` — i.e. `cascade_audit.jsonl` post-decode.

### Production — `dashboard/src/components/cascade-config-panel.ts` (1385 LOC)

`CascadeConfigPanel` (line 1225) is the only cascade surface, mounted at `monitoring?section=runtime`. It renders:

- `CascadeValidationBanner` + 3-stat header (`profiles / 키퍼 / 드리프트`).
- `ProfileCard` grid (one per cascade profile).
- `OrphanKeeperList`.
- `CascadeRawConfigEditor` (raw TOML).
- `HealthTable` (rolling provider health, search box).
- `ClientCapacityTable`, `ClientCapacityHistoryTable`.
- `SloCard`.
- `StrategyTraceTable` (line 1379) — closest cousin of preview O1: a row-per-event table over `fetchCascadeStrategyTrace` (`limit:50`). Uses `CascadeStrategyTraceEvent` not `cascade_audit.jsonl` hops.

There is no per-run card, no hop visualization, no failure/success compare.

### Gap matrix — O1

| Aspect | Preview | Production | Gap |
|--------|---------|------------|-----|
| Variant A | per-run cards w/ ordered hops | `StrategyTraceTable` flat rows | layout differs; no hop ordering or `step/model/status/ms` per row |
| Variant B | single-card hop trace + configured pool overlay | absent | full miss |
| Variant C | side-by-side ok vs error | absent | full miss |
| Data layer | `cascade_audit.jsonl` hop schema | `CascadeStrategyTraceEvent` (different shape — no `hops[]`) | likely needs new endpoint or schema enrichment |
| Routing | `#cascade` | `monitoring?section=runtime` | OK if reused but not isolated |

### Recommendation — O1

The preview's "Cascade Inspector" is a **separate observation surface** distinct from `CascadeConfigPanel`'s configuration role. They should not be conflated. New zone with a new endpoint (or new endpoint shape on the existing trace) is needed.

Effort: **High**.

---

## O3 · Safe Autonomy

### Preview spec — `cb-root.jsx:206-210`, `cb-group-f.jsx:182-285`

| Variant | Slot id | Component | LOC | Vocabulary |
|---------|---------|-----------|-----|------------|
| A · Score + findings | `sa-dash` | `SafeAutoDashboard` (`SafeAutoHero` + finding list) | 24 | `gauge` (global score + status), `meta` table (`findings_total`, `keeper_count`, `last_run`, `trend −4 vs 24h`), 14-bar `Spark`, then list of `findings[]` rows with `sev/keeper/rule/file:line`. |
| B · Findings rolled up by keeper | `sa-kpr` | `SafeAutoByKeeper` | 30 | grid: `keeper · high · medium · low · rule list`; sorted by weighted severity (`high*9 + medium*3 + low`). |
| C · 15-run trend | `sa-trd` | `SafeAutoTrend` | 27 | bar chart over `history[]` 15 buckets; bad if `< 78`; min/current/max readout. |

Mock data: `safeAutonomy = {global_score, status, findings_total, findings:[{sev, keeper, rule, file, line}], keeper_count, last_run, history:[15 numbers]}`.

### Production — `dashboard/src/components/safe-autonomy.ts` (409 LOC)

`SafeAutonomyPanel` (line 337) mounted at `monitoring?section=safe-autonomy` (`navigation.ts:165-168`).

Renders:

- Hero card: `Advisory Truth Layer` label + `global_score` + `StatusPill` + `KpiStrip` (6 cells: `keepers/active goals/findings/human queue/with task/approval depth`). `formatTimeAgo(generated_at)`.
- `DomainCard` grid (xl:2 cols) over `domains[]` (`label/status/score/summary/weight`).
- "키퍼 매트릭스" `Card` with `KeeperCard` per `per_keeper[]` — large card with `KpiStrip` (score/approvals/turns/activity/history/task) + blocker.
- "발견" `FindingsList` (`reason_code/severity/keeper/summary/suggested_next_action/human_action_required`).
- "타임라인" `TimelineList` (`ts_iso/kind/keeper_name/summary`).
- `JsonViewerCard` for `artifacts`.

Data source: `GET /api/v1/dashboard/safe-autonomy` parsed into `SafeAutonomyData`.

### Gap matrix — O3

| Aspect | Preview | Production | Gap |
|--------|---------|------------|-----|
| Variant A (Dashboard) | hero gauge + findings list | hero w/ KPIs + `DomainCard` grid + findings + timeline | **denser than spec**; matches semantics; spec's `Spark` mini-trend not rendered |
| Variant B (ByKeeper) | flat sortable grid | merged into `KeeperCard` per-keeper | **functionally present, layout differs** |
| Variant C (Trend) | 15-run bar chart | absent | full miss; `history[]` not in `SafeAutonomyData` |
| Data layer | `findings[].rule/file:line` | `findings[].reason_code/domain_id/suggested_next_action` | partial — labels differ but both are findings; richer in production |
| Routing | `#safe-auto` | `monitoring?section=safe-autonomy` | aligned |

### Recommendation — O3

This is the closest-to-aligned of the 6 zones. Two follow-ups:

- Add a small trend chart to the hero (Variant C). Needs backend `history[]` field — Low if backend already has, Mid if not.
- Optional: extract a sortable `SafeAutoByKeeper` table from `KeeperCard` data (Low).

Effort: **Low–Mid**.

---

## K1 · Keeper Inspector v2

### Preview spec — `cb-root.jsx:226-230`, `cb-group-h.jsx:7-135`

| Variant | Slot id | Component | LOC | Vocabulary |
|---------|---------|-----------|-----|------------|
| A · BDI panel (will / needs / desires / goals) | `ki-bdi` | `KeeperBDIPanel` | 30 | `KeeperTabs` selector + `<dl class="ki-bdi">` rows: `will`, `needs`, `desires`, then horizon block (`short/mid/long` goals); header shows `role`, `social_model`. |
| B · Tool access + cascade config | `ki-acc` | `KeeperToolAccess` | 30 | `<dl>` of `cascade`, `tools_preset`, `sandbox`, `network`, `auto_handoff`, `handoff_threshold`, `proactive_idle`, `mention targets`. |
| C · Token / handoff stats (all keepers) | `ki-stats` | `KeeperTokenStats` | 42 | aggregate: `<table>` rows per keeper with `in tok / out tok / in distribution bar`; bottom 3-cell totals (`Total In / Total Out / Keepers`). |

Mock data (`window.MASC_P2.keepersFull`): `{id, role, social_model, will, needs, desires, short_goal, mid_goal, long_goal, cascade, tools_preset, sandbox, network, auto_handoff, handoff_threshold, proactive_idle_sec, mention[], tokens:{in,out}}`.

### Production — `dashboard/src/components/keeper-detail*.ts` + `keeper-config-panel.ts`

- `keeper-detail.ts` (1194 LOC) — `KeeperDetailPage` (mounted via overlay or detail route). Renders identity strip with `will / needs / desires` (lines 1080-1085) — labels: `의지`, `필요`, `열망`. Plus `social_model_recognized` / `configured_social_model` / `social_model_fallback` (lines 950-967). Goals rendered separately under `active_goal_ids`.
- `keeper-detail-panels.ts` (1264 LOC) — `KpiGrid`, `ContextChart`, `TokenTrendChart`, `PromptTelemetryPanel`, `CtxCompositionPanel`, `InferenceTelemetryPanel`, `MetricsCharts`, `RawDataDebug`, `EquipmentList`, `RelationshipList`, `TraitsList`. Per-turn token trend (`TokenTrendChart` line 560).
- `keeper-detail-runtime.ts` (682 LOC) — runtime stats: `auto_handoff_rate` (line 399), `mention_reactive_turn_count` (line 401).
- `keeper-config-panel.ts` (1186 LOC) — editable config: `sandbox_profile`, `network_mode`, `proactive_idle_sec`, `auto_handoff`, `handoff_threshold`, `cascade_name` (lines 144-198). Mounted within keeper detail tabs.
- `keeper-chat-panel.ts` (270 LOC) — keeper chat surface.
- `keeper-badge.ts` (211 LOC) — `KEEPER_REGISTRY`, `kSlot`, `kSigil`, `KeeperBadge`, `KeeperStack` (preview's `cb-shared.jsx` has the JSX twin).

### Gap matrix — K1

| Aspect | Preview | Production | Gap |
|--------|---------|------------|-----|
| Variant A (BDI panel) | dedicated panel with `will/needs/desires` + horizon goals as one zone | inline fragments inside `KeeperDetailPage` (lines 1080-1085) | content present but **not packaged as a "BDI panel"**; horizon-goal triple (short/mid/long) absent |
| Variant B (Tool access) | read-only summary panel | spread across `KeeperConfigPanel` (editable) and `keeper-detail-runtime.ts` | functionally present but not a single panel |
| Variant C (Token stats — all keepers) | cross-keeper aggregate table | only **per-keeper** `TokenTrendChart`; no cross-keeper aggregate | full miss for cross-keeper view |
| Data layer | flat `keepersFull` array with everything inline | distributed across `Keeper`, `KeeperConfig`, `keeper-runtime` types | shape is fine; consolidation needed for cross-keeper aggregate |
| Routing | `#keeper-v2` zone with 3 artboards | one detail page per keeper, accessed via overlay/detail route | preview implies an inspector "fleet" view that production does not have |

### Recommendation — K1

- A: extract a `BDI` sub-panel from `KeeperDetailPage` and add `short/mid/long` goal rendering (Low).
- B: extract a read-only `ToolAccessSummary` from `KeeperConfigPanel` (Low).
- C: build a fleet-wide token table; data source likely `/api/v1/keepers/...` aggregate or sum of per-keeper data already loaded (Mid).

Effort: **Mid**.

---

## K4 · Autoresearch

### Preview spec — `cb-root.jsx:242-246`, `cb-group-h.jsx:290-397`

| Variant | Slot id | Component | LOC | Vocabulary |
|---------|---------|-----------|-----|------------|
| A · Loop list (6 loops, open / closed) | `ar-list` | `ARLoopList` | 28 | row per loop: `id (truncated 11ch)`, `topic`, `owner`, `branch?`, `H/E/C` counts, status pill, `confidence%`. |
| B · Finding card (select f-001/002/003) | `ar-find` | `ARFindingCard` | 39 | tab strip selecting finding id, then `hypothesis / evidence(list) / conclusion` panels with confidence header. |
| C · Hypothesis → evidence → conclusion flow | `ar-flow` | `ARHypothesisFlow` | 40 | 3-step ordered flow with connectors (`↓`); reads `findings[].hypothesis/evidence/conclusion` for one loop. |

Mock data: `arLoops:[{id, topic, owner, branch?, hypotheses, evidences, conclusions, status, confidence}]`, `findings:[{id, loop, at, hypothesis, evidence:[], conclusion, confidence}]`.

### Production — `dashboard/src/components/autoresearch*.ts`

- `autoresearch.ts` (603 LOC) — `Autoresearch` (mounted at `lab?section=autoresearch`). Sub-components include `OutcomeVsHarnessCallout`, `LoopSelector`, `LoopDetailView`, `ResearchBrief`, `LoopOverview`, `CycleHistoryTable`, `InsightsList`.
- `autoresearch-state.ts` (189 LOC) — async resource, selected-loop state, author filter.
- `autoresearch-form.ts` (264 LOC) — `StartAutoresearchForm` to launch a new loop.
- `api/schemas/autoresearch.ts` (169 LOC) — valibot schema with `AutoresearchLoopSummary`, `AutoresearchCycleRecord`.

`AutoresearchLoopSummary` shape: `{loop_id, author, goal, metric_fn, model_model, target_file, status: 'running'|'completed'|'stopped'|'error', current_cycle, max_cycles, baseline, best_score, best_cycle, total_keeps, total_discards, elapsed_s, live, workdir, source_workdir, program_note, warnings[], insights[], recent_cycles[], error, session_id, operation_id, linked_at, queued_hypothesis}`.

`AutoresearchCycleRecord` shape: `{cycle, hypothesis, score_before, score_after, delta, decision: 'keep'|'discard', commit_hash, elapsed_ms, model_used, timestamp}`.

### Gap matrix — K4

| Aspect | Preview | Production | Gap |
|--------|---------|------------|-----|
| Mental model | "research loop" — collects hypotheses, evidences, conclusions, with confidence | "self-improvement loop" — generates code mutation hypotheses, scores them via `metric_fn`, keeps or discards each cycle | **fundamental schema conflict**; not just UI |
| Variant A (Loop list) | sidebar-style list with `H/E/C` counts and `confidence` | `LoopSelector` (sidebar) + `LoopOverview` showing cycles/keeps/discards/best_score | functionally analogous, **vocabulary differs entirely** |
| Variant B (Finding card) | tabbed `f-001/002/003` over hypothesis/evidence/conclusion text | absent — closest is `CycleHistoryTable` which is a per-cycle row | full miss in spec terms |
| Variant C (Flow) | 3-step `hypothesis → evidence → conclusion` with connectors | absent — production's `LoopDetailView` shows `recent_cycles` table | full miss |
| Data layer | `findings.jsonl` with `f-*` ids per loop | no `findings` concept; each loop has `recent_cycles` | **conflict** |
| Routing | `#autoresearch` | `lab?section=autoresearch` | aligned |

### Recommendation — K4

This is the only zone with a **product-level disagreement**. Either:

- (a) the preview spec is aspirational (Karpathy autoresearch was always cycle/keep/discard, not hypothesis/evidence/conclusion). In that case the spec card needs rewriting and reconciliation effort drops to **Low** (just relabel preview).
- (b) the spec describes a *different* feature — a hypothesis/evidence/conclusion log on top of (or beside) the existing self-improvement loop. In that case this is a **new product surface**, not a UI gap.

A decision is required before any UI work. **Effort blocked on product decision**; if (a) it is **Low**, if (b) **High**.

---

## Phase F (Reconciliation) sizing

| Bucket | Zones | Effort | Action |
|--------|-------|--------|--------|
| Small fix (≤1 PR) | O3 (Trend variant only) | Low | one new component + minor schema check |
| Medium (2–3 PRs) | G2 (Stale + Wall), K1 (BDI extract + ToolAccess extract + cross-keeper TokenStats) | Mid | several extractions + 1–2 new aggregates |
| Large / blocked | G1 (data shape decision needed), O1 (new surface + endpoint), K4 (product decision needed) | High | not safe to start without scope confirmation |

**Recommended PR sequence** for Phase F (Reconciliation):

1. **F1 (Low)** — O3 Trend variant: add `SafeAutonomyTrend` if `history[]` already present in `/api/v1/dashboard/safe-autonomy`; otherwise schema check first.
2. **F2 (Mid)** — K1 BDI panel extraction: pull `will/needs/desires` + horizon goals out of `KeeperDetailPage` into `KeeperBDIPanel`. Pure refactor + add 3 fields.
3. **F3 (Mid)** — G2 Stale + Wall: 2 new components in `goals/`. Backend may need to surface `claim_age`/`drift`.
4. **F4 (Decision)** — K4: product call (a) vs (b). No code until resolved.
5. **F5 (Decision)** — G1 metric source: add `progress`/`total` to `Goal` or derive from tasks. No code until resolved.
6. **F6 (Large, defer)** — O1 Cascade Inspector as a new surface separate from `CascadeConfigPanel`. Likely Phase 3 territory.

15 zones not covered here (G3, C1-C3, O2, O4, O5, K2, K3, I0, E1-E5) need an independent inventory before Phase F sizing is complete.

## Evidence — file references

Preview:

- `dashboard/design-system/preview/cb-root.jsx:155-246` — Phase 2 `DCSection` block.
- `dashboard/design-system/preview/cb-group-d.jsx:31-351` — G1, G2 components.
- `dashboard/design-system/preview/cb-group-f.jsx:55-285` — O1, O3 components.
- `dashboard/design-system/preview/cb-group-h.jsx:27-397` — K1, K4 components.

Production:

- `dashboard/src/components/goals/planning.ts:193-309` — `Planning`.
- `dashboard/src/components/goals/goal-tree.ts:945` — `GoalTree`.
- `dashboard/src/components/goals/kanban-components.ts:211` — `TaskBacklog` (kanban).
- `dashboard/src/components/cascade-config-panel.ts:1225` — `CascadeConfigPanel`.
- `dashboard/src/components/safe-autonomy.ts:337` — `SafeAutonomyPanel`.
- `dashboard/src/components/keeper-detail.ts:726`, `:1080-1085` — `KeeperDetailPage` + BDI fragment.
- `dashboard/src/components/keeper-config-panel.ts:577` — `KeeperConfigPanel`.
- `dashboard/src/components/autoresearch.ts:526` — `Autoresearch`.
- `dashboard/src/api/schemas/autoresearch.ts:48-92` — loop/cycle valibot schemas.
- `dashboard/src/types/core.ts:294-312` — `Goal` type (no `progress`/`total`).
- `dashboard/src/config/navigation.ts:165-168, 251-254` — `safe-autonomy` and `autoresearch` route registration.

---

## Appendix — 15-Zone Independent Inventory

These zones have **zero dedicated production surface** or a **misaligned partial implementation**. They were scoped out of the main 6-zone audit because no production component was mounted from `navigation.ts` under the preview's zone identity. This appendix records a rapid inventory so Phase F sizing can be completed.

### Methodology

1. Read `cb-root.jsx` section headers (lines 108–246) to record preview variant count and slot IDs.
2. `rg`-search production `src/components/` and `src/api/` for matching component names, data shapes, or API endpoints.
3. Check `navigation.ts` for section registration under the zone's canonical tab.
4. Classify gap: **Zero** = no production code; **Partial** = production code exists but under a different zone identity or with a different data model; **Misaligned** = production and preview share a name but render different shapes.

### Inventory summary

| Zone | Track | Preview variants | Production files | Gap | Effort |
|------|-------|------------------|------------------|-----|--------|
| G3 Accountability | Work | 2 (ledger, matrix) | None | Zero | High |
| C1 Board Zone | Comms | 3 (feed, thread, hot/auto) | None | Zero | Mid |
| C2 Messages / Broadcast | Comms | 3 (room, inbox, state block) | None | Zero | High |
| C3 Composer v2 | Comms | 3 (broadcast, mention, state) | None | Zero | High |
| O2 Audit Ledger | Observability | 3 (ledger, by actor, summary) | None | Zero | High |
| O4 Cost & Latency | Observability | 3 (per-agent, heatmap, latency) | `cost-dashboard.ts` (per-**model**, not per-agent) | Misaligned | Mid |
| O5 Heuristic + Stress | Observability | 3 (log, board, by module) | None | Zero | High |
| K2 Decisions / Memory | Cognition | 2 (stream, entries) | `memory-subsystems.ts` (memory only; no decisions stream) | Partial | Mid |
| K3 Institution Episodes | Cognition | 2 (cards, learnings) | None | Zero | High |
| I0 IDE Backbone | IDE | 3 (branch, keeper, nudge) | None | Zero | High |
| E1 File Tree Explorer | IDE | 4 (tree, filter, tabs, diff) | None | Zero | High |
| E2 Editor Surfaces | IDE | 5 (attrib, split, merge, review, blame) | None | Zero | High |
| E3 PR Inspector | IDE | 4 (header, files, thread, checks) | None | Zero | High |
| E4 Branch / Git Graph | IDE | 4 (DAG, commits, worktree, stash) | `git-graph-panel.ts` (read-only graph; no keeper attribution) | Partial | Mid |
| E5 Terminal / Search | IDE | 3 (terminal, search, find/replace) | None | Zero | High |

**Aggregate**: 15 zones, **36 preview variants**, **~1.5 production equivalents** (cost-dashboard + memory-subsystems + git-graph-panel). The IDE track (I0 + E1–E5) is entirely unimplemented.

---

### G3 · Accountability

**Preview** (`cb-root.jsx:167-170`): Daily verdict ledger + keeper × scope responsibility matrix. Mock data: accountability ledger with daily entries.

**Production search**: `rg -i "accountability|responsibility.*matrix|daily.*ledger|verdict.*ledger" src/` returned zero hits. `attribution-panel.ts` is a **different surface** (Layer 4 gate-chain observation, per-gate pass/fail counts).

**Gap**: Zero. No ledger data source, no matrix component.

**Effort**: **High** — needs new backend data model (daily accountability records) + 2 new components.

---

### C1 · Board Zone

**Preview** (`cb-root.jsx:174-178`): Feed (hearth-grouped), single post + thread, direct vs automation toggle. Part of **Comms** track.

**Production search**: Zero hits for a dedicated Comms-track board surface. `workspace?section=board` exists under the **Workspace** tab, which is a different organizational plane.

**Gap**: Zero — no Comms-track board zone.

**Effort**: **Mid** — if product keeps Board under Workspace, effort is config-only. If realigned to Comms, new routing + possible component split.

---

### C2 · Messages / Broadcast

**Preview** (`cb-root.jsx:180-184`): Room timeline, mention inbox (@keeper), [STATE] block focus.

**Production search**: `rg -i "broadcast|message.*room|mention.*inbox|state.*block" src/components/` returned zero hits. The `masc_broadcast` MCP tool exists but no dashboard surface consumes it.

**Gap**: Zero.

**Effort**: **High** — needs SSE or polling endpoint for room messages + 3 new components.

---

### C3 · Composer v2

**Preview** (`cb-root.jsx:186-190`): Broadcast compose, mention autocomplete, structured [STATE] payload.

**Production search**: Zero hits for Composer v2. The existing `Composer` component (lines 82–86 in cb-root.jsx) is a Phase 1 prompt composer, not the v2 broadcast/mention/state composer.

**Gap**: Zero.

**Effort**: **High** — new compose surface with mention autocomplete and structured payload validation.

---

### O2 · Audit Ledger

**Preview** (`cb-root.jsx:200-204`): Streaming ledger, filtered by actor, event-kind summary. Append-only audit log.

**Production search**: Zero hits for `audit ledger`, `streaming ledger`, or `event-kind summary`. No `audit.jsonl` consumer in dashboard.

**Gap**: Zero.

**Effort**: **High** — needs audit log data source + streaming component + filter UI.

---

### O4 · Cost & Latency

**Preview** (`cb-root.jsx:212-216`): Per-agent token spend, provider × model heatmap, latency histogram.

**Production**: `cost-dashboard.ts` exists and is mounted at `monitoring?section=cost`. It renders per-**model** metrics (`fetchRuntimeModelMetrics`), not per-**agent** spend. The preview explicitly asks for per-agent attribution.

**Gap**: Misaligned — same tab, wrong granularity.

**Effort**: **Mid** — either re-label the preview to per-model (Low) or add per-agent aggregation to backend + new table variant (Mid).

---

### O5 · Heuristic + Stress

**Preview** (`cb-root.jsx:218-222`): Heuristic firing log, stress board (per-agent), firing rate by module. Mock data: `keeper_hooks_oas` + `agent_stress.jsonl`.

**Production search**: Zero hits for `heuristic log`, `stress board`, `agent_stress`. No stress/heuristic surface in dashboard.

**Gap**: Zero.

**Effort**: **High** — needs stress data source + 3 new components.

---

### K2 · Decisions / Memory

**Preview** (`cb-root.jsx:232-235`): Decisions stream (all keepers, filterable), memory entries (verified / learned / plan). Mock: `decisions.jsonl` + `memory.jsonl`.

**Production**: `memory-subsystems.ts` exists (mounted at `monitoring?section=memory-subsystems`). It renders Hebbian synapse graph + episode records. **No decisions stream**. No `decisions.jsonl` consumer.

**Gap**: Partial — memory half present; decisions half absent.

**Effort**: **Mid** — decisions stream likely needs new endpoint or reuse of keeper telemetry.

---

### K3 · Institution Episodes

**Preview** (`cb-root.jsx:237-240`): Turn cards (click to expand learnings), learnings extraction grouped. Mock: `institution_episodes.jsonl`.

**Production search**: Zero hits for `institution_episodes`, `episode cards`, `learnings extraction`.

**Gap**: Zero.

**Effort**: **High** — needs episodes data source + 2 new components.

---

### I0 · IDE Backbone

**Preview** (`cb-root.jsx:110-114`): Branch selector, keeper multi-select (chip filter), operator nudge log + compose.

**Production search**: Zero hits for `branch selector`, `keeper multi-select`, `nudge log`. No IDE backbone surface exists.

**Gap**: Zero.

**Effort**: **High** — foundation surface for IDE track. Needs branch API + keeper filter + nudge store.

---

### E1 · File Tree Explorer

**Preview** (`cb-root.jsx:118-123`): Tree + allowed_paths overlay, filter bar, recent/pinned/changed tabs, diff-annotated tree.

**Production search**: Zero hits.

**Gap**: Zero.

**Effort**: **High** — 4 variants, needs file tree API + diff annotations.

---

### E2 · Editor Surfaces

**Preview** (`cb-root.jsx:125-130`): Attribution gutter, split 2-pane, 3-way merge, inline review, blame gutter.

**Production search**: Zero hits for editor surfaces. No code editor component in dashboard.

**Gap**: Zero.

**Effort**: **High** — 5 variants; requires Monaco/CodeMirror integration or custom editor.

---

### E3 · PR Inspector

**Preview** (`cb-root.jsx:133-138`): PR header, files changed, comment thread, CI checks with SafeAuto.

**Production search**: Zero hits for `pr inspector`, `files changed`, `comment thread`.

**Gap**: Zero.

**Effort**: **High** — needs GitHub API integration + 4 new components.

---

### E4 · Branch / Git Graph

**Preview** (`cb-root.jsx:140-145`): Branch DAG (SVG), commit list with keeper attribution, worktree picker, stash list.

**Production**: `git-graph-panel.ts` exists (mounted at `monitoring?section=git-graph`). It renders a read-only Git graph. **No keeper attribution**, no worktree picker, no stash list.

**Gap**: Partial — graph exists but lacks preview variants B/C/D.

**Effort**: **Mid** — enhance existing graph or add new variants.

---

### E5 · Terminal / Search

**Preview** (`cb-root.jsx:147-151`): Cascade-aware terminal pane, project search (rg-style), find/replace in file.

**Production search**: Zero hits for terminal or search surfaces in dashboard.

**Gap**: Zero.

**Effort**: **High** — terminal emulation + search backend integration.

---

### Phase F sizing (updated)

Including the 6 zones from the main audit + these 15 zones:

| Bucket | Zones | Effort |
|--------|-------|--------|
| Small fix (≤1 PR) | O3 (trend), O4 (relabel or per-agent table), C1 (routing decision) | Low–Mid |
| Medium (2–3 PRs) | G2 (stale + wall), K1 (BDI + tool + token), K2 (decisions stream), E4 (git graph enrichment) | Mid |
| Large / blocked | G1 (schema), G3 (new backend), O1 (new surface), O2 (audit backend), O5 (stress backend), K3 (episodes backend), K4 (product decision), C2/C3 (comms backend), I0 + E1–E5 (IDE track) | High |

**Recommended sequence update**:

1. **F1 (Low)** — O3 trend.
2. **F2 (Mid)** — K1 BDI extraction.
3. **F3 (Mid)** — G2 stale + wall.
4. **F4 (Decision)** — K4 product call.
5. **F5 (Decision)** — G1 metric source.
6. **F6 (Large)** — O1 Cascade Inspector surface (Phase 3 territory).
7. **F7 (Decision)** — O4: per-agent vs per-model scope call.
8. **F8 (Mid)** — K2 decisions stream or defer.
9. **F9–F15 (High)** — IDE track (I0 + E1–E5) is a separate epic, not Phase F.
10. **F16–F19 (High)** — Comms track (C2, C3) + Accountability (G3) + Audit (O2) + Stress (O5) + Episodes (K3) need backend-first scoping.
