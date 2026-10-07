# Domain E — context occupancy, token/cache waste, drain queues (audit 2026-10-07)

HEAD 7fb34c7172. Live data: `~/me/.masc` UTC day 10-06 (06:00Z–19:23Z for wire-capture, which keeps only ~13 h / 250 MB; costs and system log are full days). Scripts: `scratchpad/auditE/*.py` ran from an uncommitted scratchpad. They are not in this repository, and the inputs stay under the author's `~/me/.masc`. The live counts in this document cannot be regenerated from this PR, so treat them as unverified measurements.

## 1. Change flow 09-30..10-07

- **09-30**: native resumes stop resending unchanged context (#39972). Skill list computed once per published snapshot (#40085).
- **10-01**: recall switches from injecting every fact to on-demand retrieval (#40473). Recall artifacts are kept through history GC and repaired (#40486, #40557).
- **10-02**: recall goes retrieval-first with no bulk fallback (#40782). Librarian work: durable catch-up yields to waiting work, Task context is bound to sources, history is kept through synthesis (#40652, #40681, #40686). Exact-lane backpressure attribution frozen (#40742).
- **10-03**: Librarian keeps measured CLI capacity (#40731). Recall relevance improved for short queries (#40844).
- **10-04**: queue execution, pending inputs and reservations are told apart (#41051). TUI shows runtime history cache (#41113).
- **10-05/06**: `max-prompt-bytes` removed; start ceilings now come from the window (#41224). Antigravity resume logs carried bytes (#41223). Verifier runs one model turn at a time (#41312). Judgment lanes get freed permits before Keeper turns (#41332). Curator resumes pending facts after configuration publication (#40902).
- **10-07**: every turn's workspace memory briefing gets a claims digest of up to 8 KB (#41389).

## 2. Feature matrix

| Feature | Happy path | Edge cases | Observability | Verdict | Evidence |
|---|---|---|---|---|---|
| Keeper request assembly (system + tools + carried range + tail context) | Works. Median request 114.6K tokens, of which 1.7K are uncached on a warm request | When the Librarian front stalls, the range grows to the provider window (E-01) | `carried range` line once per turn; `model input ledger` only at info | Partial | keeper_turn_driver_try_provider.ml:1643-1658 |
| Context marks (high/low water) | Never runs on a turn with a session | — | `marks=` is logged but nothing acts on it: 0 evictions in 8 days | Broken (inert) | keeper_turn_driver_try_provider.ml:2744; keeper_turn_driver.ml:1803-1816 |
| Prompt-cache stability | System prompt changed 1–2×/day per Keeper. Hit rate 89–98% | Tool-list flips from `keeper_tool_search` load/reset: 294/day, with no matching cold spike | cost rows per request | OK | costs/2026-10/06.jsonl |
| Demand recall (replaces the old bulk recall block) | No claim bodies in the prompt | — | — | OK (D2-06/L1-08 fixed) | keeper_memory_os_recall.mli:1-20; #40473 #40782 |
| Tool surface, Agent Core | 47–61 tools, 67–81 KB per request. Only 1 tool had 0 calls fleet-wide in 7 days | — | wire-capture `tools_ref` | OK | keeper_tools_agent_core_bundle.ml:603-671 |
| Tool surface, official client (Claude Code) | 155–244 tools, 155–246 KB offered; 99–164 never called by that Keeper | The CLI defers schemas itself (#36798) | wire-capture `tool_schema_bytes` counts the offered set, not what the model receives | OK for tokens; selection accuracy is open in RFC-0451 (Draft) | docs/rfc/RFC-0451 §0 |
| Librarian passes | Run and commit | Full facts sent on every pass (E-02) | No token usage recorded (E-03) | Partial | keeper_librarian_queue_refresh.ml:558-590 |
| Workspace curator | 27 runs/day. A new fact is never sent twice | 97% of input is neighbor context (E-05) | exact-lane payload | Partial | server_workspace_memory_curator.ml:187 |
| Board attention / verifier / HITL judge | Small inputs (p50 2.2 KB / 37 KB) | — | — | OK | exact-lane-runs-v6 |
| Event queue state | Works | Old rows grow (D5-03) | — | Partial | keeper_event_queue_state.ml:422-451 |
| Occurrence receipts / schedule signals | Works | Nothing ever deletes them (D5-04, D5-06) | — | Partial | keeper_reaction_ledger.ml:168-180; schedule_runner.ml:129-135 |

## 3. Findings

### Baseline status (10-01 ids)

| id | Status at HEAD | Evidence |
|---|---|---|
| D2-06 / L1-08 (recall block resent / 95% of Codex window) | **Fixed** by design: recall is demand-only. No Codex traffic is left (codex cost rows: 28,127 on 10-01, 0 on 10-06) | keeper_memory_os_recall.mli:1-20, #40473, #40782 |
| D2-02 (Codex has no capacity owner) | **Partly fixed**: start ceilings come from the window (#41224). Not re-checked live (no Codex traffic) | — |
| D2-05 (Codex session discard) | **Unknown**: no live Codex traffic to test against | — |
| D3-04 / L1-01 (Librarian resends all facts, up to 3 passes per wake) | **Still open**, measured below as E-02 | keeper_librarian_queue_refresh.ml:564-590 |
| L1-04 (exact lane records no token usage) | **Still open**: 0 of 5,121 completion rows carry usage | exact-lane-runs-v6.jsonl |
| D5-03 (old rows in the queue state) | **Still open, tracked #40074**. code-reviewer queue file is 940,953 B; `projected_dispositions` holds 901 rows / 805,750 B (85.6%) | keeper_event_queue_state.ml:434-438 |
| D5-04 (occurrence receipts) | **Still open**. 722 receipt files for code-reviewer, 360 for sangsu. The only code is the path builder; nothing deletes | keeper_reaction_ledger.ml:168-180,185,220 |
| D5-06 (schedules/signals) | **Still open**. 28 MB, growing 0.75–1.6 MB/day. 2026-08 files are still on disk | schedule_runner.ml:135; reader server_dashboard_schedule_projection.ml:668 |

### NEW

**E-01 (P1). Declared context marks never act on a Keeper turn. When the Librarian stalls, one Keeper ran at 90% of a 1M window for 15 hours.**

- **Where**: `lib/keeper/keeper_turn_driver_try_provider.ml:2744`, guard `if Option.is_none ctx.continuity then evict_at_turn_boundary …`.
- **Why it never runs**: `keeper_turn_driver.ml:1803-1816` builds `Some continuity` for every turn that has a session and no recovery view. That includes `Without_snapshot`, so the guard never passes.
- **Introduced by**: the guard came in #37564 (09-21). #37734 (09-22) added `Without_snapshot`, which made continuity always `Some`. The interface now documents this as intended (`.mli:673-674`): "A turn with a continuity choice, with or without a Librarian point, runs under turn_boundary_resend_sequence". That path moves the front only after a provider refusal (`:2535-2570`).
- **Evidence the marks are inert**:
  - 0 `carried range evicted` lines on every day 09-29..10-06, while 280–1,635 lines per day log `marks=100000/70000`.
  - 95% of fronts (2,008/2,112 on 10-06) start from `origin=librarian_snapshot`.
- **Failure scenario (sangsu)**:
  - The Librarian failed to advance its front (62 Claude Code 429 fallbacks and 34 GLM-slot failures in the log), stuck at atom 987 and then 2077.
  - From 10-05 15:23Z to 10-06 06:15Z, 110 turns carried more than 1 MB, up to 3,435,974 B (2,591 atoms). The provider reported `tokens=948724 context_window=1048576`.
  - Cost: sangsu used 276.7M input tokens on 10-06, which is 19.1% of the fleet's 1,448.4M per-request input. Its 88 cold-cache requests cost 12.1M uncached tokens, a quarter of the fleet's 48.9M.
  - The same pattern on official clients: jazz-developer carried 1,640,625 B, and one turn on 10-06 summed 16.8M tokens.
- **Tick analysis**:
  - Turn 1 carries the atoms after the Librarian front.
  - Each later turn adds that turn's atoms. While Librarian passes keep failing, the front does not move.
  - After N turns the range reaches the window. Nothing between 100K and the window acts, because the marks are skipped and a 1M model does not refuse. Bounded only by the provider window and by when the Librarian recovers: **open**.
- **Second blocker**: `keeper_model_input_ledger.ml:274` discards usage whenever the request carried turn context. 1,005 of 1,895 logged ledger observations had `turn_context:true` and `total_tokens:null`. Lifting the guard alone would often stop at `Total_unknown`.
- **Smallest correct fix**: this needs a decision, so an RFC section rather than a one-liner. Choose one owner of the bound when the Librarian lags:
  - (a) Run `Keeper_carried_range.at_turn_boundary` for Librarian-front turns too, and have `choose_range_start` take the later of the Librarian front and the evicted ledger front. This drops atoms the Librarian has not summarized, which is an operator trade-off.
  - (b) Treat lag as the defect. When the carried total passes high-water, give the Librarian continuity pass the freed-permit priority from #41332.

  Either way, delete `context_marks` from the session path if it stays inert, so the declared value stops claiming a bound it never applies.
- **Confidence**: High for the facts, Medium for the fix direction. **Not tracked** (related: #28612).

**E-02 (P2, = D3-04/L1-01 still open). The Librarian sends all current facts on every pass.**

- **Measured over 24 h**: 2,746 `librarian_exact` runs. Input p50 223 KB, p90 483 KB, total 654 MB.
- **Breakdown of one payload**: `current_memory` is 457 KB of the 511 KB input; the template is 25 KB.
- **By Keeper**: e-masc-the-leader alone has 410 runs and 191 MB.
- **Wasted passes**: 954 log lines say "kept current snapshot … the pass changed no fact", against 508 commits.
- **Why**: `run_with_readers` still runs durable → continuity → context pass, and the context pass reads the whole snapshot (`keeper_librarian_queue_refresh.ml:564-590`).
- **Tick analysis**: every Keeper turn coalesces into at most one waiting unit (`keeper_memory_lane.ml:133-137`). Bounded but linear in turns: **closed** for the queue, but costly.
- **Fix**: per the baseline, one call per wake with a single output schema, and send facts as a revision diff rather than the whole set.
- **Confidence**: High. Not tracked.

**E-03 (P2, = L1-04 still open). Exact-lane runs record no tokens.**

- `complete` rows carry only `outcome/elapsed_s/output/selected_slot`. 0 of 5,121 rows mention usage.
- So the Librarian's ~654 MB/day and the curator's ~24 MB/day of rendered prompt have no token figure anywhere.
- **Fix**: copy the provider usage (input, cache read, output) into `Runs.mark_completed`, with `null` when the provider reports none.
- **Confidence**: High. Not tracked.

**E-04 (P3, new in #41389, HEAD). Per-turn claims digest uses magic byte caps and an arbitrary subset.**

- **Where**: `lib/workspace_memory/workspace_memory_ledger.ml:324-330,349`. Constants `digest_line_max_bytes = 160`, `digest_budget_bytes = 8192`, `digest_id_max_bytes = 96`, with no stated basis.
- **Arbitrary subset**: claims are taken in `claim_id` (hash) order. So once the 8 KB fills, the claims a Keeper sees are a fixed, arbitrary set. The prompt itself says this is "not a relevance selection".
- **Cost**: the digest lands in the dynamic turn context (`keeper_turn.ml:108-110`). Roughly 2K tokens × 14,248 turns/day ≈ 28M tokens/day, mostly cache reads after each turn's first step.
- **Policy conflict**: this is a byte ceiling on prompt content, against the "no byte ceilings" rule.
- **Fix**: either drop the digest (the `keeper_workspace_memory_read` tool already exists) or select by relevance to the turn, with no fixed cap.
- **Confidence**: Medium.

**E-05 (P3). Workspace curator input is 97% neighbor context.**

- **Measured on the latest run**: the 21 new facts are 26 KB; `neighbors + related_claims` are 845 KB, of which only 613 KB is distinct (27% repeated inside the run).
- **Why**: `neighbor_limit = owner_count - 1` (`server_workspace_memory_curator.ml:187`) gives about 30 neighbors per fact, chosen by Keeper count rather than relevance.
- **Payload file**: it stores the input twice (`actual_input` 874 KB + `prompt.rendered` 885 KB = 1.75 MB per run).
- **Cadence is fine**: 27 runs/24h, no new fact repeated across runs, failures do not re-wake (`:236-240`). **Closed**.
- **Fix**: cap neighbors by relevance score instead of Keeper count; store only the rendered prompt plus its sha.
- **Confidence**: Medium.

**E-06 (P3). The `keeper_skill` schema carries the whole skill catalog.**

- The 28-row catalog is 13.7 KB of the tool's 15.1 KB, sent on every Agent Core request (the largest single schema).
- Activations over 6 days: 1,509. The top 3 skills account for 54%; 5 rows were never opened (`diagram-in-chat`, `lane-addon-author`, `hwp5-static-dump`, `qrc-pin-gate-receipt`, `rhwp-static-read`).
- It is cached, so the cost is low. This is a scoping question, not a defect.
- **Confidence**: High (measurement).

**E-07 (P3). Dead export.**

`Keeper_event_queue.drain_board_all` (`keeper_event_queue.ml:516`, `.mli:456`) has callers only in `test/test_keeper_event_queue.ml`. Remove it with its test.

### Drain queues: tick verdicts

| Queue | Filled by → drained by | After N ticks | Verdict |
|---|---|---|---|
| Keeper memory lane (Librarian) | post-turn submit → one in-flight unit + one coalesced "latest" per Keeper (`keeper_memory_lane.ml:133-137`) | Bounded at 2 per Keeper. A failing slot burns one model call per wake and does not spin | Closed (but see E-01: its lag is what grows the context) |
| Workspace curator | commit notifications → daemon `drain` (`server_workspace_memory_curator.ml:288-303`) | Re-wakes only on success with work left; failure parks until the next notification | Closed |
| Runtime event bus (keeper lifecycle) | `drain_reporting_drops` (`server_bootstrap_loops.ml:1430`) | Overflow turns into a full refresh broadcast | Closed |
| Board attention | candidates → exact lane | 111,592 consumed, 689 pending (0.6%), 58 quarantined (D6 baseline was 71% pending) | Closed |
| Candle payout | `drain_with` (`candle_candidates.ml:157-186`) | `Retry_later` re-runs on every pass with no backoff. On 10-06, 35 passes failed reading the ledger | Open (no progress state); belongs to the D8 owner |
| Event queue state / receipts / signals | D5-03 / D5-04 / D5-06 | Grow without pruning | Open |

## 4. Context, token and cache waste (10-06, measured)

**Fleet totals**
- Agent Core per-request input: 1,448.4M tokens, of which 1,379.3M (95.2%) were cache reads.
- Official clients (Claude Code + Muse) turn totals: 1,311.9M tokens over 1,165 turns. 41 turns used more than 5M each, 313M in total.

**A median Agent Core request** (10,315 captured)
- System prompt: p50 18.9 KB, max 34 KB. Its sections: `<system>` 11.8 KB, norms 5.0 KB, role 1.9 KB, workspace 0.5 KB.
- Tool schemas: p50 74.6 KB (52 tools).
- Reserved (system + tools): p50 93 KB. Carried range: p50 39 KB, p90 260 KB.
- Tail turn context: p50 30 KB, p90 43 KB.
- So the fixed prefix is about 70% of a median request's bytes. It is cached: a warm request averages 1,697 uncached tokens out of 114,616.

**Cold requests**: 775/day (input over 20K tokens, under 50% cached) account for 48.9M of the 69M uncached tokens. The biggest single source is E-01 (sangsu, 12.1M).

**Tool flips**: 294 tool-list changes per day come from the `keeper_tool_search` load/reset. They do not drive cold requests (gayo-yoga-leader: 49 flips, 15 cold requests). The providers appear to keep both variants warm. No action.

**Largest tool results**
- p99 is 4 KB. Outliers: `keeper_workspace_memory_read` 242 KB, `keeper_tools_list` 222 KB, `masc_lane_inspect` 133 KB, and `masc_goal_list` with no filter at 93 KB p50 (30 calls).
- These sit in the carried range until the Librarian front passes them, which ties back to E-01.

**Standalone agents (24 h)**

| Agent | Runs | Input |
|---|---|---|
| Librarian | 2,746 | 654 MB |
| Curator | 27 | 24 MB rendered (47 MB stored) |
| Board attention | 1,868 | 5.7 MB |
| Verifier | 103 reviews | p50 37 KB |
| HITL judge | 16 payloads retained | — |

Only the Librarian and the curator routinely exceed 100 KB per run (2,173 and 27 runs). Neither runs when nothing changed (no repeated new facts; the Librarian coalesces). But 954 Librarian passes changed no fact.

**Unmeasured**: Antigravity rows (gayo-yoga-leader, glossary-maniac) report 0 input tokens: 59 `conversation_cumulative` rows plus 48 more. Confidence Low; belongs to the D8 economy owner.

## 5. Coupling

- **Librarian (D3) → Keeper context size (E-01).** The carried front is the Librarian's snapshot in 95% of turns, so Librarian lane health (429s, single exact slots) sets every Keeper's request size. This is necessary as designed, but the bound that should decouple them (the marks) is inert. That makes it a hidden coupling. Either make the marks act or make the lag visible as a typed state.
- **Runtime config (W2) → marks**: `context_marks` are validated against `max_context` (`runtime_config_validation.ml:182`) but act only on session-less turns. The declared config claims a behavior the system does not have.
- **Exact lanes (L1) → economy (D8)**: no usage in run records (E-03), so the Librarian's spend is missing from token accounting.
- **Schedule/queue (D5)**: storage growth only. It does not reach prompt size, so it is separable.
