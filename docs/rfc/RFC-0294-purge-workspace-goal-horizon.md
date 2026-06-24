---
rfc: "0294"
title: "Purge the workspace-goal horizon (short/mid/long) — dead cadence cohort + a screen concept the operator says is gone"
status: Draft
created: 2026-06-24
updated: 2026-06-24
author: jeong-sik (vincent)
supersedes: []
superseded_by: null
related: ["0288", "0282", "0067"]
implementation_prs: []
---

# RFC-0294 — Purge the workspace-goal `horizon`

Status: Draft
Author: jeong-sik (vincent)
Date: 2026-06-24
Scope: the `Short | Mid | Long` classification carried by every **workspace goal**
record in `Goal_store` (`lib/goal/goal_store.ml`), its MCP-tool validation
(`lib/workspace_goals.ml`, `lib/tool_schemas/tool_schemas_workspace_extra.ml`), and
its dashboard rendering (`dashboard/src/components/goals/goal-helpers.ts`,
`goal-tree.ts`).
Out of scope: every *other* "horizon" in the tree (Hebbian decay horizon, runtime
deadline horizon, memory-grounding horizon, `horizontal_space_re`) — these are
unrelated concepts and a naive string sweep would corrupt them (§2). Also out of
scope: the keeper-meta `short_goal`/`mid_goal`/`long_goal` horizon, which was
already purged by **RFC-0288** (`#22162`, merged `ed085ab5`); this RFC is the
sibling cleanup on the *other* system that shared the word.

## 1. Problem — the Goal screen still presents 단기/중기/장기, but the concept is gone

The operator's instruction: in the Goal surface, the short/mid/long-term (단기/중기/
장기) concept no longer exists. The live system disagrees with that statement at
every layer:

- Backend record carries it: `lib/goal/goal_store.ml:24` (`type horizon = Short | Mid | Long`),
  persisted as a field at `lib/goal/goal_store.ml:93` and serialized at
  `lib/goal/goal_store.ml:129`.
- MCP validation pins it: `lib/workspace_goals.ml:57` (`goal_horizon_strings = ["short"; "mid"; "long"]`)
  feeds `parse_optional_horizon` (`lib/workspace_goals.ml:89`) and the
  `masc_goal_list` / `masc_goal_upsert` schemas (`lib/tool_schemas/tool_schemas_workspace_extra.ml:6`).
- Dashboard renders it everywhere: `goal-helpers.ts:201` (`horizonLabel` → '단기'/'중기'/
  '장기'), `goal-helpers.ts:210` (`horizonColor`), `goal-helpers.ts:137` (`horizonProgress`
  rollup), `goal-helpers.ts:13` (`HorizonFilter = 'all' | 'short' | 'mid' | 'long'`), and the
  badge at `goal-tree.ts:1022` / `goal-tree.ts:1405`.

So "the concept is gone" is an instruction to *make it gone*, not a description of
the current code. RFC-0288 removed the keeper-meta horizon and explicitly recorded
that the `Goal_store` horizon "survived as a separate system." This RFC retires that
survivor. Its largest control consumer (the refresh cadence) is dead, but — unlike
RFC-0288's keeper-meta horizon — it is **not entirely dead**: one small live path
(the dashboard stagnation threshold) re-bases off horizon and must be redesigned,
not merely deleted (§3).

## 2. Two different "horizon"s — what this RFC must NOT touch

`grep horizon` across `lib/` returns code from four unrelated subsystems. A
string-driven purge ("no string match" is a hard constraint here) would silently
break them. They stay untouched:

| site | meaning | verdict |
|---|---|---|
| `lib/level2_config.ml:38`, `:41` | Hebbian **decay** horizon (synapse consolidation cadence) | keep |
| `lib/tool_misc_web_fetch.ml:244` | `horizont`**`al`**`_space_re` — substring false positive | keep |
| `lib/runtime/runtime_deadline.mli:1` | wall-clock **time** horizon for per-attempt deadlines | keep |
| `lib/server/server_bootstrap_maintenance.ml:218` | memory-OS **grounding** horizon (seconds) | keep |
| `lib/keeper_metrics/keeper_measurement.mli:51` | doc-comment phrase "(or goal horizon)" | reword only (not code) |
| `lib/server/server_routes_http_runtime_fleet_scan.ml:638` | string `"add_goal_or_goal_horizon_to_keeper_toml"` — keeper-meta (RFC-0288) | separate follow-up |

The purge is therefore scoped by *type identity* (`Goal_store.horizon` and its
transitive references), not by the word "horizon".

## 3. Justification — one dead control path, one live one to re-base

`horizon` has a full census of consumers (origin/main `3086e33d99`):

| # | consumer | role | verdict |
|---|---|---|---|
| 1 | `should_refresh_goal`/`reprioritize`/`refresh` (`goal_store.ml:806`–`853`) | re-prioritization cadence | **dead** (delete) |
| 2 | `sort_goals` `horizon_rank` (`goal_store.ml:531`–`542`) | primary sort key | collapse to `(priority, updated_at desc)` |
| 3 | `compute_rollup` `short/mid/long_count` (`goal_store.ml:741`–`743`) | count rollup | delete (no external consumer — `rg short_count` hits only `test_keeper_tool_affinity`, an unrelated tool stat) |
| 4 | `list_goals ?horizon` (`goal_store.ml:551`) + MCP schema | filter | delete (P2) |
| 5 | `Dashboard_goals_types.stagnation_threshold_seconds` (`dashboard_goals_types_accessor.ml:215`) | **live** stalled-goal threshold (Short 6h / Mid 1d / Long 3d), used at `dashboard_goals_types_builder.ml:396` → `stagnation_status` JSON + health badge | **re-base** (§4) |
| 6 | keeper prompt context (`keeper_turn_up_create.ml:282`, `keeper_run_context.ml:130`) | injects `horizon_str` into `active_goals` tuple | drop the field from the tuple |
| 7 | dashboard JSON (`dashboard_goals.ml:204`, `dashboard_http_keeper_snapshot.ml:36`) | serializes horizon | drop the key |

Consumer **#1 is the dead scheduler** — the original premise for the purge:

```ocaml
(* lib/goal/goal_store.ml:806 — the cohort selector *)
let should_refresh_goal mode goal =
  match mode with
  | Daily   -> goal.horizon = Short && goal.phase = Goal_phase.Executing
  | Weekly  -> goal.horizon = Mid   && goal.phase = Goal_phase.Executing
  | Monthly -> goal.horizon = Long  && goal.phase = Goal_phase.Executing

(* lib/goal/goal_store.ml:828 — the only consumer of should_refresh_goal *)
let refresh config ~mode = (* ... reprioritize goals in the matching cohort ... *)
```

Grounding (origin/main `3086e33d99`):

- `should_refresh_goal` and `reprioritize` (`lib/goal/goal_store.ml:812`) are private
  (absent from `lib/goal/goal_store.mli`); their only caller is `refresh`
  (`lib/goal/goal_store.ml:836`, `:838`).
- `refresh` has **zero non-test callers** in `lib/` and `bin/`. The similarly named
  `Server_dashboard_http_goal_loop_broadcast.start_goal_loop_refresh_loop`
  (`lib/server/server_dashboard_http_goal_loop_broadcast.ml:93`) is the dashboard
  goal-**loop** OODA status broadcast — it calls `Proactive_refresh.start` with
  `compute = goal_loop_status_for_state`, never `Goal_store.refresh`.
- No test locks `refresh` / `should_refresh_goal` / `reprioritize`.

Consumer #1 mirrors RFC-0288's keeper-meta finding ("스케줄러 0"): private, no
non-test caller, no test lock — deleting it is safe. Consumers #2/#3/#4/#6/#7 only
sort, count, display, or inject text; none *decide* anything, so they collapse or
drop cleanly.

The one consumer that **does decide** is #5: the dashboard marks a goal `stalled`
when `stagnation_seconds >= stagnation_threshold_seconds goal.horizon`, and the
threshold is per-horizon (Short 6h / Mid 1d / Long 3d). Removing `horizon` does not
remove the need for *a* threshold — stagnation detection is a live, surfaced feature
(`stagnation_status` is serialized at `dashboard_goals.ml:275` and rendered as a
health badge at `dashboard_goals_types_health.ml:61`). So #5 must be **re-based onto
a surviving axis**, not deleted. That choice (single constant vs priority-derived)
is §4's open decision; it is the only behavior-visible change in this purge and the
reason the RFC's earlier "only dead logic" framing was wrong.

## 4. Proposal

`Goal_store.horizon` is the type identity; every consumer in the §3 census is in a
single OCaml compilation graph (`masc_goal` → `workspace_goals` / `dashboard` /
`keeper`), so the OCaml side **cannot** be split into independently-green commits —
removing the field breaks all consumers at once (the compiler enforces totality, no
silent gap). The phases group by file, but P1–P3-OCaml land in one buildable unit:

1. **`goal_store.ml(i)`**: delete `type horizon`, `horizon_to/of_yojson`,
   `parse_horizon`, the `horizon` record field, `horizon_rank`, the dead cadence
   (`should_refresh_goal`/`reprioritize`/`refresh`) and its now-orphaned scaffolding
   (`refresh_mode`/`snapshot_mode`/`snapshot`/`refresh_result` types,
   `parse_refresh_mode`/`parse_snapshot_mode`/`snapshot_mode_of_refresh_mode`,
   `snapshots_dir`/`scheduler_state_path`/`has_scheduler_state`/`parse_yyyy_mm_dd`/
   `days_until`), and the `short/mid/long` `rollup` counts. Collapse the comparator
   to `(priority, updated_at desc)`. Drop `?horizon` from `list_goals`/`upsert_goal`.
   `ensure_dirs` stops creating `snapshots_dir`.
2. **OCaml consumers** (same build): drop `horizon_str` from the keeper
   `active_goals` tuple (`keeper_turn_up_create.ml`, `keeper_run_context.ml`); drop
   the `"horizon"` key from `dashboard_goals.ml:204` and `dashboard_http_keeper_snapshot.ml`;
   **re-base stagnation** (see decision below) in `dashboard_goals_types_accessor.ml`
   + its `.mli`/`dashboard_goals_types.mli` signatures and the `..._builder.ml:396`
   call site.
3. **MCP boundary** (same build): delete `goal_horizon_strings` /
   `parse_optional_horizon` (`lib/workspace_goals.ml`) and the `horizon` enum +
   schema fields (`lib/tool_schemas/tool_schemas_workspace_extra.ml`). An explicit
   `horizon` arg to `masc_goal_upsert` returns an `unknown field` validation error
   (parse-don't-validate — no silent ignore).
4. **TS dashboard** (separate build): delete `HorizonFilter`, the `short/mid/long`
   grouping (`goal-helpers.ts:76`), `horizonProgress`, `horizonLabel`, `horizonColor`,
   and the badge spans in `goal-tree.ts`. Primary view becomes the goal tree (§6).
5. **Persistence migration** (§5): legacy goal JSON still has a `"horizon"` key; the
   reader stops reading it (documented intentional drop) and writes omit it.

### Resolved — stagnation threshold re-base (consumer #5)

Operator selected **(a)**: `stagnation_threshold_seconds` becomes a single constant
`= Masc_time_constants.day_int` (1 day, the former Mid bucket). Options considered:

- **(a) single named constant** `default_stagnation_threshold_seconds` (no per-goal
  variation). Most surgical; introduces no new axis. Question: which value — the Mid
  bucket (1 day) preserves the median behavior but makes Short goals alert later and
  Long goals earlier.
- **(b) priority-derived** `f : priority -> int` (priority survives the purge and is a
  better "how-urgent" signal). Changes semantics; needs its own justification.
- **(c) drop stagnation entirely** — rejected: it is a live, surfaced health feature.

This is the only behavior-visible change in the purge. (a) keeps the value a named
policy constant — not a magic number and not a priority→time heuristic table —
which is why it was chosen under the "no heuristic / justification-first"
constraint. Short goals now alert later (24h vs 6h) and Long goals earlier (24h vs
72h); priority-derived stagnation (b) remains a possible future refinement.

## 5. Migration & no-silent-failure

Persisted goal records still carry a `"horizon"` key on disk. After the field is
removed from `type goal`, removal is handled as **standard schema evolution**, not
an ad-hoc patch:

- `goal_of_yojson` simply stops reading the `"horizon"` member (it is no longer
  part of the match). A `(* RFC-0294 *)` comment documents that the legacy key is
  intentionally ignored, so a future reader does not mistake the omission for a
  bug. There is no per-load info log: dropping a retired optional field is not a
  failure, and `read_state` runs often enough that a log line would be pure noise.
- `goal_to_yojson` no longer emits the key, so it disappears from each record on
  its next write through the existing `update_state` read-modify-write path. No
  separate migration binary is needed.
- MCP rejection of an explicit `horizon` arg is **declarative**: the
  `masc_goal_list` / `masc_goal_upsert` schemas carry `"additionalProperties":
  false`, so once `horizon` is no longer an advertised property the validation
  layer rejects it as an unknown property. A hand-written `if horizon present then
  error` guard is deliberately avoided — that would be the forbidden string-match
  pattern and a maintenance wart.

This satisfies "no silent failure": the on-disk drop is intentional and documented
(no error to swallow), and a caller still sending `horizon` is rejected by the
schema, not silently absorbed. The legacy-load path is covered by the existing
`test_goal_store` fixture whose goal JSON includes a `"horizon"` key and still
loads.

## 6. To-Be — the Goal/Task screen without horizon

The standalone prototype (`Downloads/v2 (24)/keeper-v2/work.jsx`) organizes the Goal
view *by horizon* (`view = 'horizon' | 'kanban'`, `byHorizon(hz)` at `work.jsx:564`),
so the prototype's primary view is exactly the concept being removed and cannot be
copied verbatim. The live `goal-tree.ts` already uses a parent/child **tree** (not
horizon buckets), so the To-Be is the live structure minus the badge:

- Replace the `호라이즌 | 칸반` toggle with `트리 | 칸반` (tree is the live default).
- KPI strip (활성 목표 / 전체 Task / 진행 중 / 검증 대기 / 백로그), claimable backlog,
  kanban columns, task drawer, and the operator "운영 상태" aside are preserved
  one-to-one from the prototype — none depend on horizon.
- Goal ordering within the tree follows the new `(priority, updated_at)` sort.

Pixel-perfect work proceeds against the prototype for everything *except* the
horizon grouping, which this RFC retires.

## 7. Phases & verification

| Phase | Change | Verification |
|---|---|---|
| P1 | `goal_store.ml(i)` type + dead cadence + sort collapse | `dune build --root .`; existing `goal_store` tests green; add a test that `list_goals` sorts by `(priority, updated_at desc)` and that a legacy `"horizon"` JSON loads + drops the key |
| P2 | `workspace_goals.ml` + `tool_schemas_workspace_extra.ml` | tool-schema snapshot tests; `masc_goal_upsert {horizon:"short"}` → validation error |
| P3 | dashboard `goal-helpers.ts` + `goal-tree.ts` | `vitest`; `tsc` clean; remove horizon assertions, add tree-default assertion |
| P4 | migration log + prototype-aligned tree/kanban toggle | load a fixture with legacy horizon, assert single info log + no `"horizon"` on re-write |

Each phase is a separate commit; P1–P2 are backend-only (no RFC-gated subsystem —
`workspace_goals` / `goal_store` are not in the credential/operator/hooks list), P3–P4
are dashboard-only.

## 8. Trade-offs

- **Loss**: the `horizon` filter/sort and the (dead) cadence cohort. Anyone who
  built a mental model of goals as short/mid/long loses that axis. Mitigation:
  `priority` already expresses urgency; the cadence was never live.
- **Migration risk**: a legacy `"horizon"` key on disk. Mitigation: explicit
  read-time drop + info log (§5), covered by a fixture test.
- **Prototype divergence**: the prototype's primary Goal view is removed.
  Mitigation: §6 maps every non-horizon prototype element to the live tree.

## 9. Relation to RFC-0288 / RFC-0282

RFC-0282 §3 decided to *keep* the `Goal_store` horizon. RFC-0288 purged the
keeper-meta horizon and recorded the `Goal_store` one as a surviving separate
system. This RFC supersedes the "keep" decision with the new evidence that the
survivor's only control path (`should_refresh_goal`/`refresh`) is dead code (§3),
completing the two-system horizon retirement.
