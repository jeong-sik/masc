# Domain H — Glossary health and domain coupling (2026-10-07)

Reference: main checkout HEAD `7fb34c7172`. origin/main has since moved 5 commits to `58ebce7f12`; `docs/spec/00-glossary.md` is identical between the two, and the 5 commits touch lib/keeper only (checked with `git diff --quiet`).
Baseline: 2026-10-01 audit D16a (glossary) and D16b (coupling) rows, `docs/audits/2026-10-01-week-audit-findings.md:279-309`.

## 1. Change flow by day (glossary file)

Week growth `e126a20e72..7fb34c7172`: 236,066 B / 2,800 lines / 204 entries -> 297,632 B / 3,384 lines / 236 entries.
`git diff --stat`: +636 / -52 lines, 53 commits touched the file (+61.6 KB, about 8.8 KB per day, 4.6 entries per day; the 10-01 audit measured 6.5 KB per day).

| Day | Commits | What changed (PR) |
|---|---|---|
| 09-30 | 5 | Jev System One adapter #40432, Candle currency/ledger #40281, Keeper Portrait #40166, Agent Core Hook #40082, DOS controller pass #39954 |
| 10-01 | 17 | Stacked PR invariants #40285, Task Archive/GC #40434, Memory OS Recall #40433, ROLL protocol #40431, TUI Home #40318, Chat Queue #40382, Candle equipment #40471, "state only what holds now" #40515, Candle wallet #40024 |
| 10-02 | 2 | Librarian catch-up #40652, TUI Resources/Identity owners #40381 |
| 10-03 | 3 | Memory OS Recall/Jev #40583, Model Context Window/Keeper Item #40607, Lane receipt durability/Play handoff #40616 |
| 10-04 | 9 | MCP sampling #40913/#41071, Memory commit/portrait #40901, exact lane slot #41009, recall/Candle #41024, Memory Category #41076, Candle grading #40848, board audience #41041 |
| 10-05 | 1 (+3 dated 10-05 in log) | Default Route #41233, Fusion Judge Conclusion #41244, max-prompt-bytes removal (#41224 merged 10-06) |
| 10-06 | 16 | Chat Lane #41294, Lane family #41315, Lane application #41334, Lane activity #41352, Keeper Delegate Completion Wake #41317, admission priority #41316/#41332, allowance refusal #41359, Provider Usage Window #41373 |
| 10-07 | 0 | — |

## 2. Baseline status (2026-10-01 D16a / D16b)

| id | Status at 7fb34c7172 | Evidence |
|---|---|---|
| D16a-13 glossary grows ~6.5 KB/day, half the entries carry code paths / PR numbers | **Regressed** | 246,223 B / 208 entries (10-01) -> 297,632 B / 236 entries. Rate is now ~8.8 KB/day. 59 entries carry PR numbers (124 refs, was 50 / 97). Median entry 992 B, p90 2,466 B, 38 entries over 2 KB (was 31). Exact-output route still 7,252 B (`00-glossary.md:1542-1617`). No size decision recorded. |
| D16a-11 TUI first screen has three names | Still open (known from other audits this week) | Glossary entry is `Home` at `00-glossary.md:133`; code constructor `Overview`; screen label "Dashboard". |
| D16a-14 undefined terms (Keeper Owner, Workspace Curator, Access Control, Worker) | Still open | `rg -c 'Workspace Curator'` = 1 line, no entry; no `Keeper Owner` entry. `Workspace_curator` is a `Standalone_lane.t` constructor used in 13 files. |
| D16a-08 "we removed X" sentences | Partly fixed by #40515 (10-01); new dead identifiers appeared (section 4) | — |
| D16a-09 'lane' has 8+ meanings | Still open and **worse**: 15 entries now have "Lane" in the title; 4 added on 10-06 (#41294, #41315, #41334, #41352). | `00-glossary.md:37,1055,1077,1089,1132,1179,1251,1361,1367,1397,1416,1446,1462,1484,1508` |
| D16b-02 keeper in the `masc` library | Still open (section 8) | — |
| D16b-03 schedule consumers call Keeper internals | Still open | section 8 |
| D16b-05 Librarian reads Keeper meta / checkpoint store | Still open | section 8 |
| D16b-07/08 provider runtimes duplicate an 850-line function; run_named size | Not re-derived (owned by Domain A) | — |

## 3. Duplicate concepts (same thing under two names, or two things under one name)

Checked in code for each cluster. "Merge" = same value under two names. "Split" = two values under one name.

| # | Cluster | Code fact | Kind | One name |
|---|---|---|---|---|
| DC1 | Runtime Attempt / provider attempt | `00-glossary.md:755-757` admits both. Modules: lib/keeper/keeper_runtime_attempt.ml:1 ("provider attempts"), lib/runtime/runtime_attempt_fsm.mli:1, keeper_provider_attempt_effect(.mli, _core), keeper_turn_driver_provider_attempt. `runtime_attempt` 69 files, `provider_attempt` 30. | Merge | **Runtime Attempt**; rename the `*provider_attempt*` modules. |
| DC2 | Lane (15 titled entries) | `Standalone_lane.t`, `Runtime_lane.t` (= Runtime Candidate Order), `Keeper_lane` (per-Keeper turn fiber), `Keeper_memory_lane` (= Memory queue), `Lane_id.family`, Official Client / Chat / DOS / MSX / Browser / Quiz Lane. The `Lane` entry lists four unrelated meanings itself (`00-glossary.md:1067-1072`). | Split | **Lane** = a `Lane_id.t` row only. `Runtime_lane` -> Runtime Order, `Keeper_lane` -> Keeper Turn Loop, `Keeper_memory_lane` -> Memory Queue, Chat Lane -> Keeper Chat. TOML key renames are a separate operator decision. |
| DC3 | Lane Activity / Lane activity | `00-glossary.md:1397` = `Lane_activity`, a 20-row in-memory DOS feed (lib/lane_activity/lane_activity.mli:1-12). `00-glossary.md:1416` = the `enabled` flag, `Machine_configuration.activity` (lib/machine_configuration/machine_configuration.mli:6), TUI "Exact activity" (bin/masc_tui_keys.ml:1915). Names differ only by case; #41352 (10-06). | Split | Flag keeps **Lane activity**; feed -> **Machine Action Feed** (`Machine_action_feed`, DOS only). |
| DC4 | Working Context (3 values) | Glossary = Librarian pockets (`Keeper_librarian_context`), also prompt block `Librarian_working_context` (lib/types/prompt_block_id.ml:6) and route `/working-context`. `Keeper_types.working_context = { checkpoint : Agent_core.Checkpoint.t }` (lib/keeper_types/keeper_types.mli:36-38), a one-field wrapper. `Agent_core.Checkpoint.working_context : Yojson.Safe.t option` (packages/agent_core/lib/checkpoint.mli:41), filled from `config.checkpoint_sidecar` (lib/runtime/runtime_agent.ml:1392). Glossary admits "이름만 같다" (2677). | Split | Glossary -> **Librarian Pocket** (code says `pocket`); delete the wrapper; rename the JSON field `sidecar`. |
| DC5 | Claim (3 values) | Task transition (`00-glossary.md:2164`, `Claimed` lib/types/types_core.mli:110); Fact text field `claim` (3130); workspace ledger rows keyed by `claim_id` (lib/workspace_memory/workspace_memory_ledger.mli:26,37), now in the shared briefing digest (#41389, HEAD). | Split | Task keeps **Claim**; Fact text -> `statement`; ledger row -> **Shared Fact**. |
| DC6 | Jev twice | `00-glossary.md:542` "Jev" and 3356 "JEV / Noul": same model, two spellings, each lists different callers. | Merge | One **JEV** entry, one bullet per caller. |
| DC7 | Hearth / Sub-board | Hearth = free string on a post; Sub-board = typed record with access policy (lib/board_types/board_types.mli:240-253). Joined by `post.hearth = slug` (lib/board/board_core.ml:280-284, 941-946). 5 MCP tools (lib/tool/tool_name.ml:93-97). No `board_sub_boards.jsonl` in `~/me/.masc`. | Merge | **Hearth** with an optional access policy; parse `hearth` once into a slug type; drop the Sub-board name and tools. |
| DC8 | Curator / World Curator | Code has `Workspace_curator` (13 files) only; "World Curator" 0 lib/bin files. No glossary entry (D16a-14). | Gap | Add **Workspace Curator**; never write "World Curator". |
| DC9 | Verifier / Auto Judge / Appraiser / Fusion Judge | Distinct jobs: `Standalone_lane` `Verifier`, `Hitl_auto_judge`, `Candle_appraiser`, `Board_attention`; Fusion judge is a role in a run (1934). | Distinct | Keep names; one "Exact-output lanes" table replaces five prose entries. |
| DC10 | Librarian Round / Librarian Pass | 3059 "Round (회차)" and 3327 "Pass End (회차 종결)" are the same unit; code says `pass` (3 files), `round` 0. Turn / Cycle / Run are distinct and the `Turn` umbrella (572) works. | Merge | **Librarian Pass**. |
| DC11 | Checkpoint / Machine Checkpoint / Slot | Keeper `Checkpoint` (2572), emulator save (1319), save slot (1330), `Exact Lane Slot` (1132), portrait item slot. | Split | Machine Save / Save Slot / Order Position; Checkpoint stays Keeper's. |
| DC12 | Assignee / Producer / worker | One submitter, three names (`00-glossary.md:2153-2163`). | Merge | **Submitter** while awaiting a verdict. |

## 4. Dead concepts and dead identifiers

Method: `h_idents.py` (rerun at HEAD) pulled 1,566 backticked identifiers from the glossary and searched lib, bin, packages, dashboard/src, config, scripts and other source trees; 19 had no hit. I re-checked each with `rg -w` against src and test and with `fd` for file names. No markdown link in the glossary points at a missing file (every `](../../…)` resolves).

Truly dead at HEAD (no source, no test). Operator rule: delete the sentence, no "deprecated" note.

| Glossary line | Dead identifier | What is real now |
|---|---|---|
| 559 (Jev) | `Requeued_pending` | no constructor anywhere; delete the "재큐 후보 우선 판정" bullet or name the real requeue state |
| 697 (Chat Queue) | `local_waiting_next_preview` | no such value; delete the parenthetical |
| 1819, 1841, 1861 (Candle) | `HalfLifeSet` | code spells it `Candle_event.Half_life_set` (lib/candle/candle_event.mli:43) |
| 1819 (Candle) | "9종" event list | code has **10** body constructors: `Granted` (lib/candle/candle_event.mli:93, written by lib/candle_runtime/candle_grant.ml:66) is missing from the glossary list and from its balance rule ("Paid adds, Purchased subtracts") |
| 2959-2960 (Memory OS Recall) | `Invalid_capacity_policy`, `Budget_overrun`, `Recall_withdrawn`, `Recall_snapshot_bundle` | none exist; the four bullets at 2956-2960 describe an RFC design, not `Keeper_memory_os_recall`. Delete them or replace with the real `.mli` names. |

Not dead (false positives): `no_wall_clock_death` is an invariant id at docs/constitution.xml:220; `keeper_own_recent_actions`, `dashboard_http_tool_quality`, `keeper_tool_call_file_change` are file names; `*_keeper_count/names` is shorthand for two fields that exist; `requests_are_navigation` / `assert_no_decision_posts` (`00-glossary.md:144`) exist only in test/ — a glossary should not cite test helpers, delete them from the Home entry.

Baseline dead-concept rows:

| id | Status | Evidence |
|---|---|---|
| D16a-01 removed Keeper handoff in dashboard | Still open | `MASC_DASHBOARD_CTX_HANDOFF_IMMINENT` still read at lib/config/env_config_runtime.ml:438, dashboard/src/components/settings-surface.ts:1738 |
| D16a-02 `Context_measured` has no producer | Still open | constructed only in test/ (3 files); production only matches it (lib/keeper_registry/keeper_state_machine.ml:89, lib/keeper/keeper_registry_types.ml:242) |
| D16a-03 handoff rate defaults to 100% | Still open | lib/metrics_store_eio.ml:270 `else 1.0 (* No handoffs = perfect handoff rate *)` |
| D16a-04 Overview Team block leftovers | **Fixed** | `ov_keeper_rows`, `overview_keeper_rows_of_briefs`, `keeper_phase_band`: 0 hits |
| D16a-05 RFC-0362 goal owner | Still open | docs/rfc/RFC-0362-goal-owner-and-intake-contract.md exists |
| D16a-07 agent_core Handoff unused | Still open (needs operator decision) | packages/agent_core/lib/handoff.ml exists |
| (code comment) "제거됨" text | New P3 | lib/keeper/keeper_unified_turn.mli:52 "(단일 runtime 에서 죽은 코드였으므로 제거됨)" — a removal note in an interface comment; delete the sentence |

## 5. Translationese — 15 worst phrasings (plain word a colleague gets on first read)

Counts are `rg -c` lines in `00-glossary.md`. 원장 appears on 57 lines, 51 of them without "ledger" on the same line; 투영 on 29 lines, 25 without "projection". Code names stay English (rule 8 of phrasing-vocabulary).

| # | Line(s) | Now | Plain |
|---|---|---|---|
| T1 | 789-818, 475, 505, 523 | `Candidate Fault (후보 사정 판정)`, "이 바인딩의 사정", "계정 사정으로 거절" (사정 13 lines) | **후보 실패 원인** / "이 바인딩 때문", "계정 한도 때문에 거절" — 사정 needs its own disclaimer at 818 ("사정은 탓이 아니다"). |
| T2 | 791-811, 1341, 1354, 1580-1583, 2362 | "exact 걸음", "Keeper 걸음", "걸음 전체의 영수증" (12 lines) | **후보 순회** / "후보를 차례로 시도하는 과정" |
| T3 | 2747 | `Seed (씨앗)` | **시작 위치 근거** (code `Keeper_carried_front.seed`) — glossary-maniac's own instructions name Seed -> 씨앗 as the example of what not to do. |
| T4 | 2770 | `Carried Front (실어 보낼 이력의 시작 위치)` | **요청에 넣을 기록의 첫 위치** |
| T5 | 3297 | `Librarian Gap (Librarian 틈)` | **빠진 구간** (요청에도 기억에도 없는 Atom 범위) |
| T6 | 2651 | `Transcript Tail Recovery (전사 꼬리 복구)` | **끊긴 도구 호출 마무리** |
| T7 | 994 (+8 lines) | `Recorded Call Outcome (기록된 호출 결말)`, "종단 결말" (1578) | **기록된 호출 결과** |
| T8 | 1158-1174, 734, 765, 1050, 2875-2879 | `Attempt Dispatch (시도 파견 여부)`, "모델에 파견" (9 lines) | **실제로 보냈는지** / "모델에 보내기 전" |
| T9 | 1201 | `Keeper Health Reading (Keeper 건강 판독)` | **Keeper 상태 표시** |
| T10 | 2541-2542 | `Shutdown Admission Fence (종료 진입 차단막)`, "원장 정합성을 지키는 진입 차단 술어" | **종료 중 재부팅 막기**, "종료 기록이 어긋나지 않게 재부팅을 막는 검사" |
| T11 | 442-443 | `Latched Reason (durable latch 까닭)` | **멈춰 둔 이유** |
| T12 | 3101 | `Continuity Width (연속성 회차의 폭)` | **요약 한 번에 읽는 양** (atom 수 상한) |
| T13 | 3207-3208 | `Reverse Copy Judgment (역방향 사본 판정)` | **남은 기억에 이미 들어 있는지 확인** |
| T14 | 1213-1236 | `Reasoning Effort (추론 노력)`, `Effort Ladder (노력 사다리)`, `받는 노력 집합`, `노력 거절` | **추론 강도**, **강도 단계**, **허용 강도 목록**, **강도 거절** |
| T15 | 1516, 1580 | "**저장 시 조상 동기화와 판독 시 내구성 재검증**", "**생성 발송 관측 권위**" | "저장할 때 상위 폴더까지 fsync 하고, 읽을 때 다시 확인", "어느 후보든 생성 요청을 보냈는지 기록" |

Same pass: 방출 (2079, 2951) -> 내보낸다; 후계 (3183-3201) -> 대신하는 기록; 종단 확정 (548, 561) -> 최종 확정; 레인 가족 (1077) -> Lane 종류; 승인 생애 단계 (2105) -> 승인 진행 단계.
Known from other audits (not re-derived): the user-facing label says "fiber"; a label says "admitted slots" over refused slots.

## 6. Is the glossary too big for an AI reader? (context/token waste)

Measured: 297,633 B, 3,384 lines, 236 entries, 189,389 chars of which 53,217 are Hangul and 134,771 ASCII.
Token estimate (no tokenizer run; ranges from ~1-1.5 Hangul chars/token and ~3.5-4 ASCII chars/token): **about 70k-95k tokens** for one full read. Confidence Medium.
- A full read costs more than a third of a 200k window. Nothing loads it automatically (`rg 00-glossary lib bin config` = 0 hits), so the cost lands on whoever reads it: Claude/Codex sessions, and glossary-maniac (109 decision-log lines name the file, `~/me/.masc/keepers/glossary-maniac.decisions.jsonl`).
- Section balance is broken: `## Core` is 144,299 B (48%) and holds DOS Play Pad, Quiz Lane, Board attention, Provider Usage Window and TUI Home. `## Continuity` is 80,255 B. `## Task Lifecycle` is 7,731 B.
- The definitions themselves are small: the first `: ` line of each entry averages 110 B (25,984 B for all 236). The other ~270 KB is invariants, PR history, wire values and route names that already live in `.mli` comments and RFCs.
- At the current rate (+8.8 KB/day this week) the file passes 350 KB around 10-13 (estimate).

Proposed structure (hard cut, no compatibility notes):
1. `docs/spec/glossary/README.md` — an index, one row per term: `| Term | 한 줄 정의 | Code identifier | Lives in |`. 236 rows × ~170 B ≈ 40 KB ≈ 12k tokens.
2. One file per domain, same row format plus at most 3 lines of boundary notes: `runtime-and-lanes.md`, `keeper-turn.md`, `board.md`, `task-goal-hitl.md`, `candle-and-items.md`, `memory-librarian.md`, `machines-play.md`, `tui-dashboard.md`, `skills.md`, `repo-exec.md`. A reader loads the index (12k) plus one domain file (~3-5k) instead of 80k.
3. Move invariants, PR numbers, wire values and route names into the `.mli` the row points to. Rule for glossary-maniac: an entry may not contain a PR number or a `#` route; if a fact needs a PR number it belongs in the RFC.
4. One term, one row. The "경계: 이름만 같다" paragraphs (Lane, Working Context, Claim, Turn) disappear once section 3's renames land.

Example row (Exact-output route, now 7,252 B at `00-glossary.md:1542-1617`):
`| Exact-output route | Keeper 대신 모델 한 번으로 정해진 답을 받는 lane 의 후보 순서 | Runtime_exact_output_registry | lib/runtime/runtime_exact_output_registry.mli |` (~180 B).

## 7. Coupling map from dune (Part 2)

Graph rebuilt at HEAD with `h_dune.py` -> `H-dune-head.json`: 379 libraries (was 357 on 10-01), 167 under lib/. No cycles (dune would refuse them). The `masc` library (lib/dune, `include_subdirs unqualified`) still compiles 851 `.ml` files / 328,510 lines; `lib/keeper` alone is 557 files / 232,697 lines (10-01: 541 / 229,995). `lib/keeper`, `lib/play`, `lib/world_constitution`, `lib/fusion`, `lib/lane_addon`, `lib/lane_registry`, `lib/workspace_memory`, `lib/typesafeai` still have no `dune` (D16b-02 still open).

Core-domain edges (project libs only):

| Edge | Verdict | Detail |
|---|---|---|
| `masc_candle` -> masc_core, keeper_portrait, zarith | OK | pure |
| `masc_candle_store` -> **masc_workspace** | Violation, confirmed | one helper call; H-04 |
| `masc_candle_runtime` -> goal, workspace, keeper_registry, keeper_identity | OK | integration layer |
| `masc_goal` -> keeper_registry | Acceptable | only `Keeper_id.Keeper_name.of_string` (2 refs) |
| `masc_schedule`, `board_handlers` -> masc_workspace | OK | file lock, paths |
| `task_handlers` -> agent_core | Watch | task handlers link the agent runtime |
| `masc.auth` -> masc_tool_dispatch | By design | `Tool_catalog.registered_metadata` (lib/auth/auth.ml:286,340) |
| `masc.runtime` -> keeper_runtime (`Keeper_runtime_failure_route`) | Placement violation, confirmed | H-06 |
| server -> `Keeper_turn_driver.assignment_walk_order` | Confirmed | H-05 |
| repetition guard -> SQLite tool-call index | Confirmed | H-07 |
| `masc_tui` (client) -> whole `masc` | New | H-08 |
| keeper registry -> Librarian signal, dashboard broadcast | New, inside keeper | H-09 |

Baseline D16b-03 (schedule consumers): still open — lib/server/server_schedule_consumers.ml (1,370 lines) references 14 Keeper modules on 134 lines; no `Keeper_schedule_wake` exists. D16b-05 (Librarian reads meta/checkpoint store): still open — 19 direct `Keeper_meta_store`/`Keeper_checkpoint_store` calls in lib/keeper/keeper_librarian_durable_consumer.ml.

## 8. lib/keeper sub-domains that could be their own library (ranked by benefit/cost)

Method: `h2/keeper_groups.py` groups the 557 modules by name prefix and counts, per group, lines, other Keeper modules it calls (fan-out = what must move down with it) and its modules called by other groups (interface width). Prefix grouping is coarse (203 modules stay "other"), so read the numbers as order-of-magnitude. Confidence Medium.

| Rank | Sub-domain | Files / lines | Interface (modules used by others) | Fan-out (Keeper modules it needs) |
| --- | --- | --- | --- | --- |
| 0 (prerequisite) | **Keeper base**: `keeper_meta_contract`, `keeper_types_profile*`, `keeper_meta_store`, `keeper_config`, `keeper_registry_types` | 30 / 9,319 | 153 + 105 + 79 + 47 inbound refs | 30 modules, incl. lifecycle, shutdown, microvm, librarian queue signal |
| 1 | **Board attention** (`keeper_board_attention_*`, 10 files) + **exact-lane kit** (`keeper_lane_cli_oneshot`, `keeper_exact_flow_detail`, `keeper_exact_lane_preference`, `keeper_structured_output_schema`) | 10 / 9,304 (+ kit) | 4 modules: `_worker_wake` 3, `_worker` 2, `_candidate` 2, `_judgment` 1 | 15, of which 8 are base |
| 2 | **Official-client runtimes** (`keeper_official_client_*`, codex / claude_code / antigravity / muse runtimes) | 9 / 11,057 | 6 (`_session_store` 9 refs) | 23 (turn driver try_provider, owner, carried front, tools) |
| 3 | **Librarian + Memory OS** (`keeper_librarian_*`, `keeper_memory_*`, `keeper_continuity_*`, `keeper_carried_front`) | 33 / 15,034 | 8 + 15 | 29 (chat_store, checkpoint_store, meta_store, turn_boundaries) |
| 4 | **HITL / Gate / Approval** (`keeper_gate*`, `keeper_approval*`, `keeper_hitl*`) | 18 / 10,763 | 12 | 25, 7 of them tool runtime |
| 5 | Schedule / heartbeat (`keeper_heartbeat_*`, `keeper_schedule*`, `keeper_event_queue*`) | 15 / 5,396 | 5 | 46 |
| — | Tool runtime (57 / 30,826), turn driver (67 / 27,555) |  | 34 / 38 | 114 / 175 |

Rank 0 must come first: nothing can leave `masc` until the base sits below it, so cut the two upward edges (H-09, and `keeper_registry.ml` -> `Keeper_lane`/lifecycle admission, 10+12 refs). Rank 1 has the narrowest interface for its size, and its exact-lane kit (`keeper_lane_cli_oneshot`, `keeper_exact_flow_detail`, `keeper_exact_lane_preference`, `keeper_structured_output_schema`) also serves Librarian. Rank 2 pairs with D16b-07. Rank 3 needs D16b-05 first. Tool runtime (57 files / 30,826 lines, fan-out 114) and turn driver (67 / 27,555, fan-out 175) are hubs; leave them.

## 9. Feature matrix

| Feature | Happy path | Edge cases | Observability | Verdict | Evidence |
|---|---|---|---|---|---|
| Glossary as one-term-one-meaning SSOT | Partial: 236 entries, all 0 links dead | 12 duplicate/split clusters (section 3); same English name twice (Lane Activity / Lane activity) | none — no check that a term is defined once | Partial | `00-glossary.md:1397,1416,542,3356` |
| Glossary tracks code | Mostly: 1,559 of 1,566 backticked identifiers live | 7 dead identifiers; Candle event list 9 vs 10 | none | Partial | section 4; lib/candle/candle_event.mli:43,93 |
| Glossary fits an AI reader | No: ~70-95k tokens one read, +8.8 KB/day | open PR #41376 adds more | — | Broken (size) | section 6 |
| Plain Korean | Partial | 원장 51 lines without "ledger", 사정 13, 걸음 12 | — | Partial | section 5 |
| Library boundaries for core domains | OK for candle, board, schedule, goal | candle_store -> workspace; runtime -> keeper failure route; server -> turn driver walk order; registry -> librarian signal | dune catches cycles only | Partial | section 7 |
| Keeper as separable sub-domains | No: 557 files / 232,697 lines in `masc` | registry base reaches lifecycle/librarian | — | Broken (structure) | lib/dune:1, section 8 |
| TUI client independence | No: `masc_tui` links `masc` | decoders import Keeper runtime modules for wire constants | — | Partial | bin/dune:1909; lib/tui_decode.ml:75,3954,6064 |

## 10. Findings (P0..P3)

No P0/P1: nothing here breaks a happy path at runtime. Glossary and coupling defects cost context, mislead readers, and block library splits.

**H-01 P2 — Glossary size keeps growing; one read is ~70-95k tokens** (Regressed D16a-13)
- Where: `docs/spec/00-glossary.md` (297,632 B; `## Core` 144,299 B). Introduced by 53 commits this week (section 1); open #41376 adds more.
- Failure: an agent asked to "check the glossary" loads ~1/3 of a 200k window; glossary-maniac reads it repeatedly. Each new term adds ~1.2 KB and nothing removes text.
- Tick: per docs(glossary) PR +1 entry, 0 deletions -> open, linear growth (+8.8 KB/day).
- Fix: section 6 structure (index of one-line rows + per-domain files; invariants and PR numbers move to `.mli`/RFC). Not an OCaml change. Confidence High (sizes measured), Medium (token range). Not tracked.

**H-02 P2 — "Lane activity" names two different things; "Lane" names six** (D16a-09 worse)
- Where: `00-glossary.md:1397` (DOS feed, `Lane_activity`, lib/lane_activity/lane_activity.mli:1-12) and `00-glossary.md:1416` (enabled flag, `Machine_configuration.activity`, lib/machine_configuration/machine_configuration.mli:6). Introduced by #41352 (10-06) next to the older feed entry.
- Failure: operator or Keeper reads "Lane activity: off" -> cannot tell whether new work is blocked or the DOS feed is empty; glossary-maniac teaches both.
- Fix (smallest): rename the feed module `Lane_activity` -> `Machine_action_feed` (callers: lib/dos_lane/dos_lane.ml, bin/masc_tui.ml, bin/masc_tui_machine_live.ml/.mli) and retitle 1397. Then the Lane renames in section 3 DC2. Confidence High. Not tracked.

**H-03 P2 — Glossary Candle entry describes 9 ledger events and a balance rule without `Granted`**
- Where: `00-glossary.md:1819` ("9종", `HalfLifeSet`), 1820 (balance = `Paid` adds, `Purchased` subtracts). Code: 10 kinds, `Granted` credits the balance (lib/candle/candle_balance.ml:250-251). Introduced by #41371 (10-06, operator grants) which did not touch the entry; `HalfLifeSet` misspells `Half_life_set` (lib/candle/candle_event.mli:43).
- Failure: an agent reconciling a wallet from the glossary rule finds balance != replay(Paid - Purchased) after any operator grant and reports a ledger bug that is not there.
- Fix: list the 10 constructors by their code names and state `Granted` adds. Same pass: delete `Requeued_pending` (559), `local_waiting_next_preview` (697), the four `Recall_*` bullets (2956-2960), test helpers at 144. Confidence High. Not tracked.

**H-04 P3 — `masc_candle_store` links `masc_workspace` for one path helper**
- Where: lib/candle_store/dune (`masc_workspace`), lib/candle_store/candle_ledger.ml:7. Introduced by #39919 (09-29).
- Fix: `Common.masc_dir_from_base_path ~base_path` (lib/core/common.ml:90; identical result for cluster "default", lib/workspace/workspace_utils_paths_backend.ml:9-16) and replace `masc_workspace` with `masc_core` in the dune. Confidence High. Not tracked.

**H-05 P3 — Lane Add-on host sampling asks the Keeper turn driver for a route's order**
- Where: lib/server/server_lane_addon_sampling.ml:41-46 -> lib/keeper/keeper_turn_driver.ml:403-428. Introduced by #40239 / #40269 (10-03).
- Fix: move `walk_order`, `assignment_refusal`, `assignment_walk_order`, `quota_ordered_runtime_ids` to `lib/runtime/runtime_walk_order.ml` (they read only `Runtime`, `Runtime_lane`, `Runtime_instance`, quota/backpressure); update the three callers (keeper_turn_driver, keeper_next_request_forecast.ml:508, server_lane_addon_sampling). Confidence Medium (helper deps checked for `quota_ordered_runtime_ids` only). Not tracked.

**H-06 P3 — Runtime layer imports the Keeper failure-route taxonomy**
- Where: lib/runtime/runtime_candidate_backpressure_state.ml:32, runtime_exact_lane_backpressure.ml:49-51; module lib/keeper_runtime/keeper_runtime_failure_route.ml (728 lines). #36845 or earlier.
- Fix: move `retry_class`, `usable_retry_after`, `path_rest_sec` into `lib/runtime_model/runtime_retry_class.ml`; keep Keeper routing in keeper_runtime and have it use the new type. Confidence Medium. Related #36942 (failure-route mixes admission timeout with provider timeout), not the same defect.

**H-07 P3 — Cross-turn repetition guard depends on a deletable SQLite read index**
- Where: lib/keeper/keeper_run_tools_setup.ml:356-380 -> lib/keeper_tool_call_log.ml:1190-1199 -> `Keeper_tool_call_index.recent_rows`. Also `store = None -> Ok []` (keeper_tool_call_log.ml:1194-1195) returns "no history" when the store is not initialised.
- Tick: index unavailable on turn N -> seed `[]` + WARN -> only run-local counter; index header says the next read rebuilds -> turn N+1 normal. Closed, but a store never initialised stays `Ok []` forever with no WARN (open).
- Fix: return `Error Index_unavailable "store not initialised"` for the `None` case so the existing WARN path fires; longer term keep the last N `(tool, input_fp, output_fp)` per Keeper in `Keeper_owner` memory and seed it once from the ledger tail. Confidence Medium. Not tracked.

**H-08 P3 — TUI client links the whole server library; decoders import Keeper runtime modules**
- Where: bin/dune:1909+ (`masc`), lib/tui_decode.ml:75-93, 391, 3954-4001, 6064-6200. #36845 or earlier; D16b-04 accepted disk reads by design but not this link closure.
- Fix: move the wire codecs (`keeper_health_*`, `keeper_next_action_path_*`, `gate_operation`, `Keeper_fleet_blocker` wire names) into a `keeper_wire` library; give lib/tui_decode*.ml its own dune. Confidence High on the edge, Medium on effort. Not tracked.

**H-09 P3 — Keeper registry calls Librarian and dashboard broadcast directly**
- Where: lib/keeper/keeper_registry_event_queue.ml:10-18. #36845 or earlier.
- Fix: `publish_pending` returns or emits one `Event_queue_changed` value; Librarian and the waiting-inventory broadcast subscribe at boot. Unblocks rank 0 in section 8. Confidence Medium.

**H-10 P3 — Same value, two names (rename only)**: Runtime Attempt / provider attempt (DC1); Librarian Round / Pass (DC10); Assignee / Producer / worker (DC12); Jev twice (DC6). One PR per cluster, hard-cut rename, no alias. Confidence High.

**H-11 P3 — One name, several values (split)**: Working Context x3 incl. the one-field wrapper `Keeper_types.working_context` (lib/keeper_types/keeper_types.mli:36-38) — delete the wrapper (DC4); Claim x3 (DC5); Hearth joined to Sub-board by string equality, 5 MCP tools, no live sub-board file (DC7). Confidence High on code facts, Low on "nobody uses sub-boards" (checked only `~/me/.masc` to depth 4).

**H-12 P3 — interface comment keeps a removal note**: lib/keeper/keeper_unified_turn.mli:52 "(단일 runtime 에서 죽은 코드였으므로 제거됨)". Delete the sentence.

## 11. Context/token waste in this domain (summary)
- Glossary full read ~70-95k tokens (estimate, section 6); a one-line index would be ~12k.
- 124 PR references across 59 entries and 38 entries over 2 KB carry history, not definitions.
- Five `sub_board_*` tool definitions exist for a feature with no live data (lib/tool/tool_name.ml:93-97; catalog lib/tool/tool_catalog.ml:403-414). Whether they reach Keeper tool lists was not measured.

## 12. Coupling — which domains this one reaches into
Glossary text reaches into every domain, and that is the problem: each entry repeats wire values and routes the `.mli` already owns, so code changes (#41371 Granted) leave it stale. Separable: yes, through section 6 (index row points at the `.mli`, the `.mli` carries the detail).
