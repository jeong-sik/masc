# Domain C — Librarian, Memory lifecycle, Skills (audit 2026-10-07, HEAD 7fb34c7172)

Sources: code at HEAD (the running server reports commit 7fb34c7172 on /health), plus live read-only stats from `~/me/.masc/config/keepers/*.memory-{journal,absorbed,current}.json[l]`, `~/me/.masc/exact-lane-run-payloads/`, `~/me/.masc/workspace-memory/ledger.json` and `~/me/.masc/logs/system_log_2026-10-0*.jsonl`. Scripts: `scratchpad/audit/c2/*.py` and `scratchpad/audit/c/*.py` ran from an uncommitted scratchpad. They are not in this repository, and the inputs stay under the author's `~/me/.masc`. The live counts in this document cannot be regenerated from this PR, so treat them as unverified measurements. The code citations (`file:line`) can be checked at the stated HEAD. Days are KST.

## 0. Live counts (memory journal, all keepers)

| day | committed | no fact change | failed | librarian | explicit_write | explicit_retract | absorbed rows |
|---|---|---|---|---|---|---|---|
| 09-27 | 3244 | 1775 | 21 | 3080 | 163 | 1 | 589 |
| 09-29 | 3962 | 2348 | 99 | 3456 | 387 | 119 | 405 |
| 09-30 | 3038 | 2408 | 2480 | 2898 | 125 | 15 | 54 |
| 10-01 | 3232 | 2268 | 2003 | 2925 | 306 | 1 | 56 |
| 10-02 | 937 | 409 | 4806 | 727 | 210 | 0 | 116 |
| 10-03 | 904 | 536 | 41 | 856 | 47 | 1 | 103 |
| 10-04 | 471 | 146 | 90 | 458 | 13 | 0 | 111 |
| 10-05 | 1915 | 796 | 899 | 1097 | 729 | 89 | 74 |
| 10-06 | 4772 | 1232 | 1768 | 1686 | 2830 | 256 | 98 |
| 10-07 (to ~05h) | 553 | 293 | 10 | 460 | 93 | 0 | 75 |

The failed rows come from lanes and providers, not from memory code. 10-02 had 4,350 `ollama-cloud-deepseek… rate_limited`. 10-05 and 10-06 had 1,269 `official-client fallback exhausted … claude_code.claude-sonnet`. 10-06 also had 1,016 `ollama-cloud-glm` timeouts or rate_limited, plus 101 `lane_cancelled`.

## 1. Change flow by day

- **09-30**: #40001 makes a no-change Librarian pass keep the stored snapshot. #40019 lets an atom stored without an end line be read up to the next turn. #39972 stops resending unchanged context on native resumes. #40085 computes the skill list once per snapshot.
- **10-01**: #40473 changes recall to demand retrieval: no claim bodies in the prompt. #40373 records a continuity-only pass whose snapshot was rejected as failed (D3-02). #40481, #40486 and #40557 change how working-context recall artifacts are kept and repaired.
- **10-02**: #40782 makes recall retrieval-first and removes the bulk-memory fallback. #40784 validates only the source candidates a query selects. #40709 persists the absorb evaluation before dispatch. #40652 lets durable catch-up yield to waiting work. #40681 and #40686 bind historical Task context. #40739 recovers recall artifacts. #40741 and #40742 change lane capacity and backpressure.
- **10-03**: nothing in this domain (only the stack rebase #40233).
- **10-04**: #40744 lets the Librarian create memory categories. #40758 adds the opt-in Jev no-change preflight. #40944 journals cancellations.
- **10-05**: nothing in this domain. A live explicit-write burst started (sangsu).
- **10-06**: #40902 and #41178 resume the curator after a configuration change. #41162 keeps the Exact configuration while new work is disabled. #41297 fixes preflight eligibility. #41332 adds judgment-lane admission. The curator lane went live on glm at 15:16Z after a live config edit. #40982 rewords the skill-publish guidance.
- **10-07**: #41389 puts a claim digest into the per-turn workspace-memory briefing. The server running it was deployed at 01:36.

## 2. Feature matrix

| Feature | Happy path | Edge cases | Observability | Verdict | Evidence |
|---|---|---|---|---|---|
| Produce (explicit write + Librarian new claims) | Live: 13-2,830 explicit writes/day, 458-3,456 Librarian commits/day | Identical rewrite = remove+add+new revision (F-01, tracked) | Journal per commit | Partial | keeper_tool_memory_runtime.ml:1608-1680; keeper_memory_os_current.ml:2750-2822 |
| Synthesize / absorb | Live: 54-116 rows/day; 6-24% of Librarian commits since 10-02 | No replay harness | Gate log line per pass | Partial (was "0") | keeper_memory_os_current.ml:2600-2690; keeper_librarian_absorb_gate.mli:1-27 |
| Evict (drop, retract, absorb) | Live: 170-1,418 drops/day, 0-256 retracts/day | Budget refusal is a string error (D3-05) | Journal `dropped` | OK | keeper_memory_os_current.ml:2859-2907; keeper_memory_os_render.ml:40-51 |
| Decay / reinforce / half-life | Not present, by design (RFC-0418, re-observation counts nothing) | — | — | N/A (design) | keeper_memory_os_current.ml:2758-2764 |
| Store convergence | Top 3 keepers have stayed flat since 09-30; max 77% of 512 KiB | Journal is append-only and unbounded | — | OK | env_config_keeper.ml:333 |
| Librarian passes | Run; no-change passes keep the revision (3,008/3,008) | 66% of passes change nothing and still ship ~170 KB of facts | Run registry | Partial | keeper_librarian_queue_refresh.ml:537-575 |
| Jev preflight | Skips generation in 21 of 1,914 runs (1.1%) | 76% of eligible passes refused with `max_tokens_exceeded` | `jev_preflight` in run output | Broken (tracked #41365) | keeper_librarian_runtime.ml:1257-1446 |
| Recall per turn | About 0.7 KB demand notice; bodies through `keeper_memory_search` | No memory at all when search and artifact read are both off the surface | `MemoryOsRecallUnavailable` | OK | keeper_memory_os_recall.ml:104-123,199-217; keeper_run_tools_hooks.ml:1003-1015 |
| Working-context recall | Live; artifact repaired from the authoritative snapshot | Duplicate retention rows each turn (53%) | WARN on unavailable (0 live) | OK | keeper_librarian_context_recall.ml:85-148; keeper_recall_artifact.ml:3-35 |
| Workspace Curator | Live since 10-06 15:16Z on glm; 23 of 28 runs ok on 10-07 | CLI slots refused (tracked #41391); idle wake re-reads everything (F-03) | Run registry + ERROR log | Partial | server_workspace_memory_curator.ml:157-158,169-177,271-273 |
| Shared-memory briefing digest (#41389) | Renders every turn | Shows a hash-ordered 7% of claims (F-02) | none | Partial | workspace_memory_ledger.ml:320-360,513 (claims_digest :349) |
| `keeper_workspace_memory_read` | Works | `{}` is unbounded (W1-07) | — | Partial | config/tools/keeper_workspace_memory_read.toml |
| Skills publish | Live: 5 keeper publishes this week into `~/me/.agents/skills` | No publication evidence record (D4-07) | Tool log | Partial | server_keeper_skill_publish.ml |
| Skills regeneration loop | No code; only a prompt paragraph and the publish tool | — | — | Unimplemented | config/prompts/keeper.md:54 |
| Skills load-back | Available list resident in the schema (36 rows, ≈18.8 KB); bodies on demand (64 calls on 10-06) | 2 builtins stale (D4-04) | Activation ledger | Partial | config/tools/keeper_skill.toml:4-6; keeper_tool_composition_surface.ml:89 |

## 3. Findings

### Baseline (10-01) status

| id | status at HEAD | evidence |
|---|---|---|
| D3-03 absorb = 0 | **Partially recovered.** Absorbed rows/day: 54 → 116 → 103 → 111 → 74 → 98. Per Librarian commit: 1.9% on 09-30 and 10-01, 12-24% on 10-02..04 and 10-07, 6% on 10-05..06. On 10-06 the gate let 173 through and kept 62 (09-29: 276 and 244), so the gate is not the bottleneck. The absolute drop follows the drop in passes. There is still no replay harness. | absorbed.jsonl; gate log lines |
| D3-02 continuity counted as success | **Fixed** by #40373. 0 `continuity_not_committed` lines on 10-02, 10-04 and 10-06. | keeper_librarian_runtime.ml:1172-1176,1505-1539 |
| D2-01 / L2-01 | **Fixed** by #40359. 0 `working context recall unavailable` lines. | logs |
| D2-06 / L1-07 / L1-08 recall block 140-450 KB | **Fixed (design change).** The demand notice is about 0.7 KB and has no bodies. | keeper_memory_os_recall.ml:104-123 (#40473, #40782) |
| D3-04 / L1-01 Librarian ships all facts each pass | **Still open.** `current_memory` p50 164-179 KB (p90 ≈445 KB) against new material p50 1.3 KB (memory pass) or 6.3 KB (continuity). About 190 runs/h; 482 MB of input in about 10 h. | payload sample (600 + 1,914 runs) |
| D3-05 budget error is a string | **Still open, not reached.** The largest store is 402 KB (77%). | keeper_memory_os_render.ml:40-51 |
| D1-01 Librarian re-calls resting slots | **Still open** (lane domain). A failed range is retried on every wake with the full payload. e-masc-the-leader failure gap p50 is 15.8 s. There is no backoff on the Librarian side. | tracked under #39190 / #41425 |
| RT-A2 curator refuses CLI slots | **Still open**, worked around by putting a glm HTTP slot and lane `max_output_tokens` in the config. 273 refusals on 10-06 before the change. | curator.ml:157-158; tracked #41391 |
| X2-04 no neighbour-recall harness | **Still open (designed).** | curator.ml:187 |
| W1-07 / D15-04 "bounded" summary | **Still open.** | keeper_workspace_memory_read.toml |
| D4-04 stale builtin skills | **Partially fixed.** Four were refreshed on 10-04. `dos-play` (missing the `masc_dos_save`/`masc_dos_restore` paragraph from #39043) and `sangokushi-3` (21 lines behind #40170) are still stale. | sha256 repo vs live |
| D4-07 publish evidence lost | **Still open.** 0 `publication.json` files. | find |
| D4-03 / D4-05 | Not changed this week (no commits to those files). | git log |
| D16b-05 Librarian → Keeper coupling | **Still open.** 195 references to non-Librarian Keeper modules; it still reads meta and checkpoint directly. | keeper_librarian_durable_consumer.ml ~734-746 |

### New findings

**F-01 (P2, tracked #41377 / PR #41390): an identical explicit rewrite commits as remove+add with a new revision.**
- **Where:** `insert_or_reobserve` refreshes `last_seen` (keeper_memory_os_current.ml:2750-2776). `compute_change` compares `fact_payload`, the full JSON including `last_seen` (:659, :1157-1190).
- **Live:** on 10-06 sangsu wrote 2,521 explicit rows for 660 distinct claims, all under one trace. One claim was removed and re-added 157 times, about every 45 s; the revision went 2663→2735 in 5 minutes. Most of the fleet's "added 3,332 / removed 3,377" that day is this echo. Each commit also wakes the curator.
- **Ticks:** the fact count stays the same. The journal grows by 2× the claim size per echo, and the revision grows without bound.
- **Status:** #41390 turns a same-trace echo into a no-op. An echo from another trace still commits, by design.

**F-02 (P2, new, not tracked): the #41389 claim digest is a hash-ordered 7% of claims, pushed to every Keeper on every turn.**
- **What it shows:** `claims_digest` walks `String_map.bindings`, which is claim_id order (workspace_memory_ledger.ml:68, :349-360). A claim_id is `"claim-" ^ sha256(text)` (:513). The budget is 8,192 B (:325).
- **Live:** 34 of 492 claims fit (8,079 B). They are the claims whose hashes sort lowest. That has nothing to do with the reading Keeper, its Task, or how recent the claim is. A new claim with a lower hash silently pushes the last line out.
- **Cost:** about 9 KB per wake in world-frame layer 5 (keeper_unified_prompt.ml:1449-1473; keeper_context_layers.ml:33-52). On native-resume runtimes the world frame is the cycle's user message, so the unchanged digest is re-appended to the vendor thread every cycle. It is not a `Prompt_block_id` (lib/types/prompt_block_id.ml:1-20), so the #39972 held-context skip does not cover it.
- **Overlap:** no duplication with recall, which no longer carries bodies.
- **Ticks:** wakes 1..N repeat the same 34 lines. Each curator run (every 5-10 min) changes the ledger sha and the whole layer text.
- **Fix:** `claims_digest ~owner ledger` keeps the claims whose member dispositions include a fact owned by the reading keeper (ledger facts→dispositions, :70-80), ordered by member count. Pass `meta.name` from keeper_turn.ml:697 and keeper_unified_turn.ml:870. Claims from other Keepers stay behind the tool.
- **Confidence:** High on the mechanism and the numbers. Medium on harm, since the value of a random 7% has not been measured.

**F-03 (P3, new): every memory commit makes an idle Curator re-read the whole workspace.**
- **Path:** the commit subscriber (server_workspace_memory_curator.ml:271-273) wakes the curator. `run` calls `Context.collect`, which reads every keeper's memory-current and source-current (5.7 MB on disk; workspace_memory_context.ml:61-96) plus the 521 KB ledger. It reconciles, then returns when `new_facts = []` (curator.ml:169-177).
- **When it costs:** wakes coalesce through `pending` (:109-117, drain loop :288-300), so this costs nothing while a batch runs. After the backlog drains, each commit (471-4,772 per day, including F-01 echoes) is one ~6.2 MB read and parse.
- **Ticks:** bounded, but the I/O is commits × workspace size.
- **Fix:** carry `keeper_id` in `Keeper_memory_commit_notifications` events and reconcile only that keeper. Do the full collect only at start and on configuration publication.
- **Confidence:** Medium. The cost comes from file sizes, not a profile. Related to #40895.

**F-04 (P3, new): working-context recall appends a durable retention row on every turn even when nothing changed.**
- **Path:** `render_with` → `Keeper_recall_artifact.retain` does an fsync append plus an atomic rewrite of the current pin each first-round assembly (keeper_librarian_context_recall.ml:72,128; keeper_recall_artifact.ml:13-35).
- **Live (10-06):** 4,167 rows across the fleet, only 1,961 distinct (53% repeats). The largest directory is 732 KB.
- **Fix:** skip the append when the current pin already holds the same sha and today's dated file already has it.
- **Confidence:** Medium. The repeated pin is intended as a GC root, but a second pin within the same day adds nothing.

**F-05 (P3, design debt): curator neighbour depth = `owner_count - 1` (curator.ml:187).**
- **What happens:** fleet size sets the BM25 depth. Neighbours are 97% of each batch row (42 KB of about 50 KB per fact).
- **Live numbers:** a batch is 21 facts and 874 KB sent. The "1.75 MB" on disk is the input file holding both the JSON and the rendered prompt copy.
- **Backlog:** 4,874 → 4,439 in 4 h. That is about 180 runs and roughly 160 MB of input to glm before it drains (about 1.5-2 days, if the lane stays up).
- **Status:** the same root as the open X2-04, so nothing new to file. The depth should be a declared, measured constant.

**Tracked, measured only:**
- **#41365 Jev preflight**, in the about-10 h payload window. Memory passes: 744. Of those, 211 were ineligible and 406 were refused (`max_tokens_exceeded`). 126 were judged: 21 keep_current and 105 needs_generation. All 1,166 working_context and continuity runs were ineligible by design.

## 4. Context, token and cache waste

- **Librarian:** about 190 runs/h. Each sends the full facts (p50 ~170 KB). 66% of memory commits change nothing. About 482 MB of input per 10 h; most answers come from glm, ollama or CLI slots.
- **Workspace briefing digest (#41389):** about 9 KB per Keeper wake, re-appended per cycle on native resume. The 34 claims shown are a fixed hash sample.
- **Curator:** about 0.87 MB per run, of which 97% is neighbours. About 160 MB to drain the current backlog, then about 25-50 runs per day.
- **Recall:** down from 140-450 KB to about 0.7 KB per turn (fixed). `keeper_memory_search` rebuilds an in-memory FTS5 trigram index per call over the keeper's own facts (keeper_memory_search_index.ml:130-160). That is cheap at about 400 facts.
- **Skills:** the Available list is about 18.8 KB per request, in the cached tool prefix. It is invalidated once per publish (5 this week).
- **Journal echo (F-01):** sangsu's 10-06 explicit rows added about 4.4 MB of journal for 660 claims.

## 5. Coupling

- **Librarian → Keeper:** 195 references, including checkpoint store, meta store, chat store and cli oneshot. This is still D16b-05 and is separable: a read API "trace_id → messages + 4 meta fields".
- **Curator (server) → Keeper memory files:** it reads `keepers_dir` directly and subscribes to Keeper commit notifications. The notification is necessary. The full re-read is separable (F-03).
- **Keeper turn → Workspace memory ledger:** the ledger is parsed (521 KB) on every turn for the digest and its sha. A cached observation keyed on file mtime/sha would be enough.
- **Librarian → Runtime lanes:** all failure volume (D1-01) lives here. Rest-awareness has to be fixed in the lane, not the Librarian.
- **Skills:** publish writes into `~/me/.agents/skills` (project-agents source), which every Keeper's schema reads. This is necessary.
