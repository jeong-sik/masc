# Domain B — one Keeper's context lifecycle and turn cycle

Judged at HEAD `7fb34c7172` (main checkout). `origin/main` has since moved to `d527cb0249`, but those 4 commits are TUI tests only and do not touch this domain. Baseline: `docs/audits/2026-10-01-week-audit-findings.md` rows D2-01..D2-09 and L1-08. Live evidence comes from reading `~/me/.masc/logs/masc-start-1007-0137.log` (01:37–04:31 KST 10-07) and `masc-server-8935.log`.

## 1. Change flow by day (domain files only)

- **09-30**: #39972 stops resending unchanged context on native (Codex) resumes. #40019 lets the Librarian read atoms that have no end line, up to the next turn's start. #40006 withdraws pending wakes. #40265/#40267 remove size gates. Codex effort admission landed.
- **10-01**: #40454 logs checkpoint save timing and size. #40473 makes recall on-demand, so the whole recall block is no longer injected. #40486/#40557 keep the recall artifacts. #40472/#40554 apply the Codex declared window and separate requested from reported capacity. #40500/#40496/#40474 harden Codex timeout, handoff and steer. #40482/#40524/#40530/#40537/#40544 scope observations, previews and intake to their attempt. #40119/#40139/#40213 are refactors.
- **10-02**: #40782 makes recall retrieval-first. #40739/#40716/#40672 fix Librarian recall and boundary task context. #40647 observes transmitted official-client failures. #40547 delivers Codex tool results before the turn ends.
- **10-03**: no domain change (#40233 is a rebase).
- **10-04**: #40897 keeps connector messages when their source is unreadable. #41111 adds metrics retention.
- **10-05**: max-prompt-bytes removed, start-prompt ceilings derived from the window (part of #41224).
- **10-06**: #41224 merged. #41234 seeds cross-cycle repetition from the call ledger. #41223 logs Antigravity resume bytes. The Codex history reservation was dropped. #41271.
- **10-07**: #41383, #41387 and #41400 settle the spend of cancelled runs. #41389 adds a claims digest to the workspace-memory briefing.

## 2. Feature matrix

| Feature | Happy path | Edge cases | Observability | Verdict | Evidence |
|---|---|---|---|---|---|
| Turn end line (boundary) | Written at finalize, and for errored official-client turns | Agent-Core error and cancellation write no line (by design). Dead-turn atoms are carried until the next completed turn | `turn boundary not recorded` + counter | Partial | `keeper_agent_run.ml:2157-2178`, `keeper_agent_run_finalize_response.ml:32-112` |
| Carried range / overflow (Agent Core) | Front starts at the Librarian position. On refusal it resends once at the turn start, then demotes the current turn's results | The turn-start front is the last *completed* boundary, so N interrupted turns ride along | per-attempt `front_reported` log | Partial (tracked #41378) | `keeper_turn_driver_try_provider.ml:2535-2579, 2738-2885` |
| Overflow (official clients) | Halves capacity on a typed ContextOverflow | Byte ceilings derived from the window still in place | shrink log | Partial (tracked #41351/#41369) | `keeper_turn_driver_try_provider.ml:2284-2366` |
| Checkpoint persistence | Saves at every stage, with an encoding memo | Writes the whole canonical file 3× per round, and the file only grows | `checkpoint_save … canonical_bytes` | Partial (heavy; tracked #36690) | `keeper_agent_run.ml:1620-1700`, `keeper_checkpoint_store.ml:164-191` |
| Recall injection | Demand notice when search is available | Inline only when the surface has no retrieval tool | `MemoryOsRecallUnavailable` | OK | `keeper_memory_os_recall.ml:199-216`, `keeper_run_tools_hooks.ml:1007-1018` |
| Repetition guard (in-turn) | 3 identical in+out fingerprints → yield | Receipts that change every call evade it | stop label | Partial (tracked #41393/#41398) | `keeper_agent_run.ml:218-256` |
| Repetition guard (cross-cycle) | Seeded from history plus 200 ledger rows | The judged-count arithmetic is wrong for the ledger (**B-01**) | warn on unreadable seed | Broken after first yield | `keeper_run_tools_setup.ml:330-399, 626-651` |
| Tool-round cap | — | `keeper.turn.max_tool_rounds` default 0 = unbounded, and live runtime.toml does not set it | — | By design | `keeper_config.ml:253-263` |
| Turn exits | Closed variants: `Runtime_agent.stop_reason` (6), `Keeper_turn_outcome.t` (5), `cycle_outcome` (6), `recovery_failure` (12) with exhaustive disposition | Cancellation writes no receipt or boundary; spend is settled next run | cycle log `stop=` | OK | `keeper_turn_outcome.ml:4-60`, `keeper_heartbeat_loop_cycle.ml:38-190`, `keeper_official_client_session_store.ml:26-61` |
| Wake / admission | One owner command loop. `child_active`/`turn_in_flight` admit one turn | Failure streak only counts, never stops waking | deferral-debt log | OK | `keeper_owner.ml:1293-1330, 1985-2138`, `keeper_heartbeat_loop.ml:1764-1776` |
| Unsettled spend | Scans down to the newest resolved row and resolves rows that carry `spend_observation` | Pre-#41387 rows: hard cut | info/warn per run | OK | `keeper_unsettled_spend.ml:153-248`, `keeper_agent_run.ml:1126` |
| Workspace briefing digest | Claims digest in the briefing | New byte budget, prefix in lexicographic id order (**B-02**) | `claims_digest_truncated` | Partial | `workspace_memory_ledger.ml:324-360` |

## 3. Baseline status

| Id | Status at HEAD | Evidence |
|---|---|---|
| D2-01 continuity snapshot rejected | **Fixed**: `capture_range` asks `B.witness_line` | `librarian_continuity_snapshot.ml:195-250`, `keeper_turn_boundaries.ml:479` |
| D2-02 no owner of Codex context size | **Superseded** by the 10-06 operator rule (provider counts the window). The derived byte ceilings left over are being removed by #41369 | — |
| D2-03 Codex item identity mismatch | **Partial**: the cause was reduced by #40364 (sub-agents disabled). `Protocol_error` still carries `{stage; detail:string}` with no expected/received ids | `runtime_codex_app_server.ml:322,523` |
| D2-04 host stop discards held context | **Still open, untracked**. `settle_holding ~held_context:[]` and the stale comment are unchanged, although `settled_held_context` is maintained right below | `keeper_codex_runtime.ml:1244-1250` vs `:979,1310-1316,1483` |
| D2-05 Codex drops the vendor session on most failures | **Still open**. `Timeout`/`Process_exited` with `turn_accepted=false` map to `Transport_interrupted` (Ambiguous → automatic supersede → full Start). `Rpc_error` maps to `Protocol_failed` | `keeper_codex_runtime.ml:629-660`, `keeper_official_client_session_store.ml:51-61`. Nearest tracker is issue #35362 |
| D2-06 / L1-08 whole recall block resent | **Fixed** for search-capable surfaces (#40473, #40782): only a demand notice is injected | `keeper_memory_os_recall.ml:199-216` |
| D2-07 stage save rewrites the whole checkpoint | **Still open, worse when measured** (§4). Tracked by issue #36690 | `keeper_agent_run.ml:1620-1700` |
| D2-08 `?recovery_view` never produced | **Still open, untracked**. The only producer is a test (`test/test_keeper_recovery_transmission.ml:331`). The `Some` arms are dead | `keeper_turn_driver.ml:1663,1702,2225-2272,2411,2958`, `keeper_turn_driver_try_provider.ml:2050,2856` |
| D2-09 `transmitted_bytes` on resume = range bytes | **Still open** (naming) | `keeper_official_client_host.ml:845-884` |

## 4. New findings

### B-01 (P2) Cross-cycle repetition seed breaks the "judged" count after the first yield
- **Where**: `keeper_run_tools_setup.ml:330` (`ledger_seed_row_limit = 200`), `:345-399`, `:644-651`; `keeper_repetition_judged.ml:64-68` (`seed_beyond`) and the `restore` comment "Pairs are only appended"; `keeper_agent_run.ml:1561-1567` (record).
- **Introduced by**: #41234 (10-06).
- **Mechanism**: `judged` is a *count* that assumes one append-only, newest-first list. #41234 appends `ledger_pairs` to it. Those pairs come from a sliding window of 200 rows in **oldest-first** order (`keeper_tool_call_index.ml:442-443` reverses the DESC query back to oldest-first). Meanwhile `history_pairs` are newest-first (`keeper_run_tools_setup.ml:254-262`). `history_pairs_at_setup = List.length pairs` includes the ledger rows. On the official-client lane the history is empty, so the count covers only ledger rows.
- **Scenario (official-client keeper)**:
  - Cycle c: the seed holds 200 fingerprinted rows. A 3rd identical `masc_board_post_get` yields, and `judged = 200 + k`.
  - Cycle c+1: `total ≤ 200`, so `keep = max 0 (total − judged) = 0` and the seed is empty.
  - `restore` takes `max`, and no later setup lowers `judged` below 200. The cross-cycle guard is therefore off for the life of the process, until a server restart. That brings back #26088.
  - While the window is below 200 (the case right after the 10-06 deploy, when every keeper had 0 fingerprinted rows), `List.filteri (< keep)` keeps the **oldest** ledger rows. Those are exactly the already-judged ones. The newest, unjudged rows are dropped. So an old repeat can yield again, while a new repeat across cycles is missed.
- **Tick**: tick 1 yields correctly. Tick 2 has an empty or wrong seed. Tick N stays that way, so the loop is **open** (it never re-arms within the process).
- **Live**: 5 repetition yields in the 2.9 h log. One of them is `ocaml-refactor-woman … tokens=0 … yielded_after_repeated_tool_call(40,masc_board_post_get,4)` at 03:04:27, a count of 4, so the seed was live. I did not observe the post-yield behaviour directly.
- **Fix**: do not count the ledger. Persist a ledger watermark next to the history count:
  ```ocaml
  type judged = { history_pairs : int; ledger_after : (float * string) option (* ts, execution_id *) }
  ```
  `seed_tool_calls_from_ledger ~after` keeps only rows newer than the watermark. `seed_beyond` applies to `history_pairs` alone. `history_pairs_at_setup` counts history only. The record writes the newest ledger row's `(ts, execution_id)` seen at the yield.
- **Confidence**: High for the arithmetic, Medium for how often it bites in production.
- **Tracked**: no (#41393/#41398 change the fingerprint, not the seed).

### B-02 (P2) #41389 adds new byte ceilings to briefing assembly a day after the "no byte ceilings" rule
- **Where**: `lib/workspace_memory/workspace_memory_ledger.ml:324` (`digest_line_max_bytes = 160`), `:325` (`digest_budget_bytes = 8192`), `:330` (`digest_id_max_bytes = 96`), `:352` (`take_budget`). Rendered at `keeper_unified_prompt.ml:1454-1472`.
- **Introduced by**: #41389 (merged 10-07, HEAD).
- **Scenario**: once a workspace ledger's claims pass 8 KB, every Keeper turn sees the same first-N claims in **lexicographic claim_id order**. A new claim whose id sorts late never appears in the briefing.
- **Conflict**: the operator rule of 10-06 forbids new byte ceilings ("바이트 숫자로 자르거나 막지 않고, 그런 기준을 새로 만들지도 않는다"). Open #41351 is deleting the briefing byte budgets at the same moment.
- **Tick**: the ledger grows, the digest stays frozen at the first 8 KB, and the briefing stays stale. The loop is **open**.
- **Fix**: send one line per claim with no budget (the provider refusal path owns size), or send no digest and leave the read tool. Drop the three constants.
- **Confidence**: High. **Tracked**: no.

### B-03 (P3) Ledger-seed flush swallows Eio cancellation
- **Where**: `keeper_run_tools_setup.ml:356-357`: `try Ok (Keeper_tool_call_log.flush_now ()) with | exn -> Error …`. A turn cancelled during this flush logs "repetition ledger seed flush unavailable: Cancelled" and carries on. `keeper_tool_call_log.ml:397,412,481` re-raise correctly.
- **Introduced by**: #41234.
- **Fix**: add `| Eio.Cancel.Cancelled _ as e -> raise e` before `| exn`.
- **Confidence**: High. **Tracked**: no.

### B-04 (P3) Stale size-cap prose in the overflow paths
- `keeper_turn_driver_try_provider.ml:2274-2281` still says the official-client "seed history is cut against a declared prompt byte cap", but max-prompt-bytes is gone (#41224).
- `keeper_codex_runtime.ml:1245-1247` (D2-04) claims a tool boundary cannot see compaction, yet `settled_held_context` tracks it.
- Fix both together with D2-04. Confidence: High.

### Turn-boundary tick analysis (memory claim re-checked; not re-reported, tracked #41378)
- The claim still holds at HEAD. Agent-Core errors and cancellations write no line (`keeper_agent_run.ml:2157-2178`).
- On a size refusal with Librarian continuity, the resend front is `ctx.turn_boundary` = the last *completed* `end_atom` (`try_provider.ml:2769-2782`). That front still carries every interrupted turn's atoms.
- After that, the refused-request **demotion** (`try_provider.ml:2856-2883`) turns their tool results into markers. Carried context is therefore bounded by the window and demotion, not unbounded. It converges at the first turn that completes, whose `Continued_history_from` line lets the Librarian absorb the gap.
- The cost stays open until then: each of the N turns re-sends a window-sized request. `refused_carried_front` lives per turn only (`keeper_turn_driver.ml:1818`).

## 5. Context / token / cache waste (measured)

- **Checkpoint writes** (`checkpoint_save … outcome=saved`, `masc-start-1007-0137.log`, 2.9 h): **7,655 saves, 272 GB written, about 94 GB/h**.
  - code-reviewer: 2,371 saves × 28.4 MB = 65.8 GB.
  - jazz-developer: 629 × 80.6 MB = 49.5 GB.
  - indie-geek-blue: 1,024 × 45.9 MB = 45.9 GB.
  - polisher: 393 × 79.5 MB.
  - The three stage saves per round are near-identical sizes (`after_context_injection` / `after_assistant_collected` / `after_tool_results_appended`).
- The canonical checkpoint holds all history and shrinks only through the manual purge API. Atoms behind the Librarian front are rewritten on every save without ever being sent again. That loop is **open** (it grows with the keeper's lifetime). Tracked by #36690.
- **Carried dead-turn atoms**: the sangsu case (about 507M tokens inherited, from the 10-06 memory) and its root are covered by #41378.
- **Recall**: the 140–460 KB block per fact change (D2-06) is gone for search-capable surfaces.

## 6. Coupling

- **Librarian**: `Keeper_turn_boundaries`, `Keeper_carried_front`, `Librarian_continuity_snapshot`. Necessary, and the boundary line is the contract.
- **Economy**: cost ledger plus `Keeper_unsettled_spend`. Necessary, but settlement relies on `Keeper_owner` running one turn at a time.
- **Official-client session stores** (Codex/Claude Code/agy/Muse): necessary.
- **MCP call-ledger index → repetition guard** (#41234): the turn guard now depends on an async-flushed, SQLite-indexed, cross-scope ledger. That is separable: the turn could persist its own fingerprints in the loop-lived context or the checkpoint, and B-01 comes from this coupling.
- **Workspace memory → briefing** (#41389): separable. It is a presentation concern, but it imports a size policy.
