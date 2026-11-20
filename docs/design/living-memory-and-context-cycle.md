# Living Memory, Librarian & Clockwork Context Cycle Design

- **Branch**: `feat/librarian-l6g-and-amendments` (stacked atop RFC `#53148` L1–L5/L6)
- **Status**: Constitution-Aligned Architecture & Split-Track Design Blueprint
- **Contract**: Strictly binds to `docs/constitution.xml` (`magic_number`, `string_matching`, `closed_sum_over_string`, `budget_gate`, `no_wall_clock_death`, `strict_parse_no_default`, `authoritative_read_only`).
- **Companion Specs**:
  - `docs/rfc/RFC-librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line.md` (`#53148`)
  - `docs/rfc/RFC-amendment-librarian-multi-category-facets-and-temporal-scope.md`
  - `docs/research/2026-11-17-librarian-failure-history.md` (`#53538`, `#53543`, `#53548`)

---

## 1. Diagnosis of Prior System Failures

Live log telemetry (`system_log_2026-11-19.jsonl`), repository postmortems (`#32875`, `#37079`, `#51281`, `#53148`, `#53300`, `#53475`, `#53504`, `#53512`), and the `2026-11-16` dated-record audit identified seven systemic breakpoints:

1. **Multi-File Contention, Whole-Answer Discards & Lineage Fragmentation**
   - In the legacy Librarian path, a single pass held locks across eight files while waiting on model calls; 42% of sampled GLM calls (`8/19`) were discarded wholesale when concurrent Keeper writes bumped `memory-current.json` revision (`RFC #53148 §1.1`).
   - Folding old memories into a synthesized claim stamped `first_seen = at`, erasing historical age (`#53538`, now merged on `main`), and reconfirming an existing memory by retyping prose forked near-duplicate copies differing by 1–19 chars (`18/27` absent claims in `2026-11-16 §0`; addressed by `seen` in `#53543`, excluding Keeper self-echoes of existing Memory/`working_state` to prevent `Mem0 #4573`-style 97.8% feedback pollution). Single-op flaws rejected entire answers instead of screening per-op (`Librarian_plan`), while untargeted contradiction search caused 41% collateral drops (`Graphiti #1728`).
   - Decode rejections risked quarantine/truncation paths instead of halting cleanly in a typed `Stopped` state.
2. **Stuck Librarian Cycle & Premature Erasure of Dated Usable-Until Records**
   - Add-on wake requests were refused `978` times in a day while durable validation burned `5,877` runs over unconsumed slices (`82` unconsumed runs, `#51281`).
   - Working-context synthesis withheld by `Board` source pollution froze prune (`#53475`), while unverified `Checking`/`Failed`/`Invalid_answer` reviews could pass publication (`keeper_librarian_context_review.ml`).
   - Without closed-unit reference timestamps (`§5.5`), relative-date resolution, or explicit rules separating scheduled usable-until notes from transient queue state, baseline runs prematurely dropped upcoming usable-until memories `24/76` times (`2026-11-16` study; GLM baseline `21/38`), while naive merging flattened progressive aspect (`210/381` pairs in `arXiv 2609.36457`) and lost temporal cues (`3.05%` retention in `arXiv 2608.11775`). Compaction (`arXiv 2608.22752` losing `47%–90%` of rules) and rare Keeper memory recall (`code-reviewer 0/925`, `pr-updater 0/551`) further required keeping constraints in both Memory and literal `working_state` prose.
3. **Asymmetric Context Budgeting (`#53504`, `#53512`)**
   - Provider pre-flight reserved `reserved_output_tokens`, while `Keeper_turn_driver_try_provider` compared `next_turn_peak > max_context` without reserving output, causing `246` `Context_window_exceeded` failures (`286785 + 128000 > 400000`).
4. **Cross-Provider Replay & Tool-ID Wire Breakage**
   - Switching providers mid-conversation rejected foreign `Thinking`/`Redacted_thinking` blocks on closed prior turns (`Exclude_unselected`), and local `call_agent_core_*` IDs exceeded downstream limits (OpenAI 40-char cap) or lacked wire-deterministic sanitization.
   - `Official_client` (Claude Code, Codex, Antigravity) ↔ `Agent_core` switches overwrote a single `session.json` and triggered canonical-source amnesia.
5. **World Memory Stall & Unsynchronized Curation**
   - `workspace-memory/briefing.json` stalled from Nov 11 (`#1` shared Curator deadlocked behind Add-on), and multi-Keeper shared claim reconciliation dropped shared truth whenever a single Keeper updated its wording.
6. **Multi-Keeper / Multi-Lane / Runtime Scheduler Coupling**
   - Shared `Runtime_candidate_backpressure_state` timeouts poisoned unrelated Keepers; `Slot_scheduler` starved interactive `Priority` turns behind `Background` consolidation; `Eio.Mutex` hold-across-yield / unguarded `lock`/`unlock` / `Unix.realpath` on Eio domains risked cross-Keeper deadlock; SQLite `Sqlite3.db_close` crossed domains and trigram search missed `<3`-char identifiers.
7. **Single-Category Compression Loss on Cross-Category Merges**
   - Collapsing e.g. `Constraint` + `Preference` or `Goal` + `Fact` into one `category` without structured `facets` or prompt-level essence preservation loses facet metadata during retrieval and synthesis.

---

## 2. 8-Axis Orthogonal Matrix

| Axis | Guarantee | Core Mechanism |
|---|---|---|
| **1. Keeper Autonomy** | Per-Keeper failure or overload never stalls peers | One single-writer fiber (`<k>.memory.lock`, `<k>.memory-log.jsonl` + `<k>.memory-current.json`) per Keeper per `RFC #53148`; Keeper-scoped candidate timeout (`recorded_by`) |
| **2. Provider Rotation** | Turn-by-turn provider switches preserve history & tools | Unified `Input_budget`; prior-turn foreign reasoning exclusion; `Tool_call_id_wire` bijection |
| **3. Connector & Surface** | Bounded ingress without starving interactive turns | `Connector_ingress_lane` `Fun.protect` + wakeup barrier; explicit `Priority > Standard > Background` scheduling |
| **4. Turn Kind (Proactive/Reactive)** | Reactive user turns never sit behind cold maintenance | `Heartbeat_loop` reactive wakeup bypass; `Immediate/Normal/Low` bounded alternation in event queue |
| **5. Lane Isolation** | Background Librarian / Curator / CLI never starve chat | Standalone lane priority mapping; `Runtime_exact_lane_backpressure` ordering; dedicated `[runtime.exact_output_lanes.librarian_memory]` separate from `librarian_exact` |
| **6. Split-Track L5/L6 Memory Lifecycle** | Zero-magic-number continuity & lossless lineage atop existing schema | Canonical `Keeper_memory_os_types.fact`, `Librarian_answer`/`Librarian_plan`/`Librarian_scoring`, `#53538` earliest `first_seen` inheritance (`main`), `#53543` `seen` reconfirmation (`last_seen` + unit `sources`, no count/score threshold, self-echo excluded), functional prompt (`config/prompts/librarian.ask.md`, delivered in `#53583`), and deferred RFC Amendments (`facets` + causal `temporal_scope`) |
| **7. Knowledge Fabric (World/Wiki/MCP)** | Multi-Keeper shared truth + live subscriber push | `Workspace_memory_ledger` 2-phase `log.jsonl`, partial-member tolerant reconcile, MCP Resources + `notifications/resources/updated` |
| **8. Clockwork Time & Replay** | Prefix-immutable prompt spine + monotonic causal log | RFC `#53148 §6.1` fixed question prefix (`librarian.ask.md` → `question:` → `memory` → `working_state` → `units` → `question-end:`), writer `view = { covers_through; covered; working_state }`, monotonic causal `<keepers_dir>/<k>/turns.jsonl` + `<config keepers>/<k>.memory-log.jsonl` |

---

## 3. Split-Track Memory Architecture (L5/L6 Base + Deferred RFC Amendments)

MASC preserves a single canonical Memory OS schema (`Keeper_memory_os_types.fact`) across two coordinated tracks, strictly upholding `docs/constitution.xml` with zero parallel shadow schemas, zero count/time promotion gates, and zero wall-clock expiry sweeps:

```text
  config/prompts/librarian.md       <── Legacy path (untouched during L6 transition)

  turns.jsonl (RFC §5.5 closed units w/ timestamps)
        │
        ▼
  config/prompts/librarian.ask.md + RFC §6.1 prefix spine
        │  (proposes only; pure question function, "now" = latest closed unit)
        ▼
  Librarian_answer (add | drop | merge | revise | seen (#53543), basis = Observed, working_state)
        │
        ▼
  Librarian_plan.of_answer (per-op screening + Support_lost fixpoint + #53538 earliest first_seen)
        │
        ▼
  Single-Writer Fiber (<k>.memory-log.jsonl fsync ──► <k>.memory-current.json atomic rename)
        │  lossless `effects.removed` (`Dropped | Merged_into | Revised_into | Superseded_by | Retracted | Support_lost`)
        └──► Halt in explicit `Stopped (Log_diverged _ | Memory_unreadable | Log_unreadable | Store_unwritable)` on mismatch/corruption
```

### 3.1 Delivered Foundation (L1–L6g)

- **Canonical Fact Schema (`Keeper_memory_os_types.fact`)**: Preserves `claim`, `category`, `first_seen`, `last_seen`, `origin` (`Authored | Injected`), and `basis` (`Observed _ | Derived _`) with `memory_id = sha256(claim)` and zero silent fallback (`strict_parse_no_default`).
- **Pure Answer, Plan & Fixed Scorer (`lib/librarian/`)**:
  - `Librarian_answer`: Exact-field decoder for `question`, `question_end`, `working_state`, and `ops` (`add`, `drop`, `merge`, `revise`, plus `seen` in `#53543` requiring non-empty `"from"` and no `"claim"` retyping), rejecting malformed wire shapes (`Not_json`, `Schema_violation`, `Echo_mismatch`, `Empty_or_partial`).
  - `Librarian_plan`: Screens each op independently (`Not_valid_alone`, `Unknown_ref`, `Removed_during_flight`, `Ref_used_twice`, `Source_outside_question`), settles derived-premise closure (`Support_lost` / `Successor_unsupported`), inherits the earliest `first_seen` of replaced facts on `Merge`/`Revise` (`#53538` on `main`), and moves `last_seen` + records unit `sources` on `Seen` (`#53543`) without any score/count threshold.
  - `Librarian_scoring`: Deterministic token-recovery and `must_keep` merge-retention scorer (`test_librarian_scoring`, `test_librarian_l6g_scoring`).
- **Functional L6g Ask Prompt (`config/prompts/librarian.ask.md`, owned by PR `#53583`)**:
  - Uses a functional filename free of layer numbers (for clean L10 cutover) while leaving `config/prompts/librarian.md` untouched for the legacy path.
  - Binds strictly to RFC `#53148 §6.1` input ordering and `Librarian_answer` wire keys (`mN`, `uN`, empty `ops: []` explicitly permitted on no-change turns, `#53543` `{"op":"seen","ref":"m5","from":["u1"]}` with mandatory non-empty `"from"` excluding Keeper self-echoes of Memory/`working_state`, `basis: { kind: "observed" }`).
  - Uses RFC `§5.5` closed unit timestamps (`"now"` = latest closed unit timestamp, relative-to-absolute date resolution, `no_wall_clock_death`) to keep upcoming dated usable-until records while dropping causally completed scheduled items and recoverable point-in-time snapshots, targets only directly conflicting same-subject facts on `revise`, preserves cross-category essence and progressive tense/numbers/dates/qualifiers on `merge`, and bridges literal `claim` prose + dual-stored constraints via `working_state`.
- **Constitution Invariants**:
  - **Single canonical schema**: All L5/L6 modules operate directly on `Keeper_memory_os_types.fact` (`legacy_residue`).
  - **No numeric promotion or budget gates**: Retention and updates follow causal evidence and explicit Librarian proposals (`magic_number`, `budget_gate`).
  - **No automatic wall-clock deletion**: Elapsed time never expires a memory state (`no_wall_clock_death`).

### 3.2 Deferred Amendments Stacked Atop L6 (`docs/rfc/RFC-amendment-librarian-multi-category-facets-and-temporal-scope.md`)

Schema changes are explicitly deferred to stack cleanly on top of L6 (`feat/librarian-l6*`):

1. **Amendment 1 — Multi-Category `facets` on `Merge` & `Synthesize`**:
   - Extends RFC `#53148 §6.2` `Merge.into` (and persisted `fact`) beyond single `category` with optional `facets : category list` atop `Keeper_memory_os_types.category`, so cross-category merges (e.g., `Constraint` + `Preference`, `Goal` + `Fact`) retain their full multi-faceted spectrum without breaking existing single-`category` callers.
2. **Amendment 2 — Causal `temporal_scope` Without `no_wall_clock_death`**:
   - Adds closed-sum `temporal_scope = Standing | Point_in_time | Bounded of { valid_until_label : string }` evaluated causally by the Librarian against RFC `§5.5` closed unit timestamps and explicit completion/cancellation evidence—never via automatic wall-clock sweeps or TTL erasure.

---

## 4. Cross-Provider & Multi-Runtime Continuity

1. **`Llm_provider.Input_budget`**: Computes `max_input_tokens = max_context - reserved_output` identically for pre-flight admission (`Prepared_completion_request`) and turn-boundary compaction (`Keeper_turn_driver_try_provider`).
2. **`Reasoning_history_projection`**: Under `Exclude_unselected` at `Provider_dispatch`, foreign reasoning artifacts belonging strictly to closed prior turns (`message_index < latest_user_message_index`) are cleanly stripped instead of raising `Required_reasoning_unreadable`, while open-exchange turns remain strict.
3. **`Tool_call_id_wire`**: Deterministic length-bounded wire ID mapping across OpenAI Chat (`<=40` chars), OpenAI Responses, and Anthropic without breaking internal round-trip correlation.
4. **Multi-Runtime `session.json` + `Keeper_turn_bridge`**: Retains per-runtime native session bindings keyed by runtime family while projecting causal turns uniformly across `Official_client` and `Agent_core`.

---

## 5. Clockwork World Memory, Wiki & MCP 2026-07-28 Resources

- **`Workspace_memory_ledger` & `Workspace_memory_delta`**: Locked atomic updates via `File_lock_eio`; partial Keeper fact updates trigger corroboration recalculation rather than dropping shared multi-Keeper claims; direct Curator fiber publishes `Committed` batches into `log.jsonl` for O(delta) per-Keeper consumption (`Context_overflow` bisecting `Half -> Reference_only`).
- **`Tool_wiki` Header Memoization**: 8 KiB frontmatter reads + `(path, mtime, size)` cache eliminate whole-body disk scans per turn.
- **MCP Resources & Live Notifications**: Exposes `masc://world-memory/claims`, `masc://world-memory/log`, `masc://keepers/{keeper}/memory`, and `masc://keepers/{keeper}/memory/health`, emitting `notifications/resources/updated` through `Mcp_subscriptions.deliver` on every memory or curator commit.
