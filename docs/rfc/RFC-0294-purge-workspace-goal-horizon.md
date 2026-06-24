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
survivor, on new evidence (§3) that its single piece of control logic is dead.

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

## 3. Justification — horizon's only control logic is dead code

`horizon` looks load-bearing because it drives a periodic re-prioritization
scheduler, but that scheduler is never wired:

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

This mirrors RFC-0288's finding on the keeper-meta horizon ("스케줄러 0"). Once the
dead cadence is removed, `horizon`'s remaining roles are all non-logic:

1. a persisted field (migration concern, §5);
2. the primary sort key — `lib/goal/goal_store.ml:531` `horizon_rank` in the
   `(horizon, priority, updated_at desc)` comparator (`:538`–`:542`);
3. an optional list filter — `lib/goal/goal_store.ml:551`;
4. a count rollup — `lib/goal/goal_store.ml:741`–`:743` (`short_count`/`mid_count`/`long_count`);
5. display (badge/filter/group/progress) on the dashboard.

None of these *decide* anything; they classify, sort, and display. Removing
`horizon` collapses the sort key to `(priority, updated_at desc)` and deletes the
dead scheduler outright.

## 4. Proposal

Remove `Goal_store.horizon` and everything that exists only to serve it, in four
phases (§7), each independently compilable and tested:

1. **Backend type + dead cadence**: delete `type horizon`, `horizon_to_yojson`,
   `horizon_of_yojson`, `parse_horizon`, the `horizon` record field, `horizon_rank`,
   `should_refresh_goal`, `reprioritize`, `refresh`, and the `short/mid/long`
   counts in `rollup`. Collapse the `list_goals` comparator to
   `(priority, updated_at desc)`. Drop the `?horizon` parameter from `list_goals`
   and `upsert_goal` and from `goal_store.mli`.
2. **MCP boundary**: delete `goal_horizon_strings` / `parse_optional_horizon`
   (`lib/workspace_goals.ml`) and the `horizon` enum + schema fields
   (`lib/tool_schemas/tool_schemas_workspace_extra.ml`). `masc_goal_list` /
   `masc_goal_upsert` lose the `horizon` arg; an explicit `horizon` arg now returns
   an `unknown field` validation error (parse-don't-validate — no silent ignore).
3. **Dashboard**: delete `HorizonFilter`, the `short/mid/long` grouping
   (`goal-helpers.ts:76`), `horizonProgress`, `horizonLabel`, `horizonColor`, and
   the badge spans in `goal-tree.ts`. The Goal screen's primary organization becomes
   the existing goal tree (parent/child, sorted by priority); the kanban view, KPI
   strip, claimable-backlog, task drawer, and operator aside are unchanged (§6).
4. **Persistence migration** (§5): legacy goal JSON on disk still has a `"horizon"`
   key; the reader drops it explicitly and writes records without it.

## 5. Migration & no-silent-failure

Persisted records at `Goal_store.goals_path` carry `"horizon"`
(`lib/goal/goal_store.ml:129`, read back at `:173`). After the field is removed from
`type goal`, the loader must handle the legacy key **explicitly**, not by accident:

- The deserializer ignores a present-but-unknown `"horizon"` member and logs at
  `info` once per load when it is dropped (visible, not silent). This is a
  read-time tolerance, not a write-time default.
- New writes omit the key. A one-pass `update_state` rewrite (already the mechanism
  at `lib/goal/goal_store.ml:828`'s `update_state`) drops it from every record on
  the next mutation; no separate migration binary is needed.
- MCP `masc_goal_upsert` with an explicit `horizon` arg returns a validation error
  (not a no-op) so callers learn the field is gone rather than having it absorbed.

This satisfies "no silent failure": a legacy field is logged when dropped, and a
caller still sending `horizon` is told, not ignored.

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
