(** Prometheus metric-name string constants — extracted from [Prometheus]
    to keep the parent file under the Godfile size cap. See
    [Prometheus.ml] § "Metric Name Constants" for the convention.

    This module is [include]d in [Prometheus] so callers reach every
    binding via [Prometheus.metric_X] unchanged. *)

(** {1 Metric Name Constants}

    Exported so registration here and [inc_counter] / [set_gauge]
    call-sites in the keeper modules share a single source of truth.
    Without this, a typo on either side produces a dead series with
    no build error (the counter silently drifts to a new key).

    Convention: constant name drops the Prometheus convention suffix
    ([_total] for counters), full metric name lives on the right-hand
    side. Consumers import [Prometheus.<constant>] so the compiler
    catches typos. *)

(* Keeper turn lifecycle (registered in init, incremented in
   keeper_unified_turn.ml). *)

(** #10530: keeper required-tool-contract violations (passive-only or
    text-only turns rejected by the keeper agent loop).
    Labels: keeper_name, kind \in \{passive,text_only\}. *)

(** #12838: keepers detected as alive-but-stuck — non-Dead, non-paused,
    keepalive_running, but [proactive_rt.last_ts] has been frozen while
    autonomous turns kept advancing.  Per-keeper dedup window
    ([alive_but_stuck_dedup_ttl_sec]) bounds emission rate so a single
    stuck keeper does not flood the counter on every 30s sweep.
    Labels: keeper. *)

(** #12838 follow-up: supervisor recovery requests emitted after an
    alive-but-stuck detection.  Each increment means the supervisor set
    [failure_reason] + [fiber_stop]/[fiber_wakeup] so the existing sweep
    path can force a crash/restart instead of leaving the keeper at
    detection-only.  Labels: keeper. *)

(** #12838 follow-up: bounded recovery wakeups queued by
    [alive_but_stuck_scan].  Labels: keeper, outcome. *)

(* #10047: [append_metrics_snapshot] failures in [keeper_turn.ml] and
   [keeper_unified_turn.ml] used to be log-only, masking state/metric
   divergence. Surface as a counter so dashboards can alert on silent
   metric drops and operators stop trusting metric jsonl as ground
   truth when keepers are running. *)

(* #9953: counter of observed [context_max] values labelled by
   [keeper, model_used, resolved_model_id, context_max_bucket].
   The bucket label collapses raw token counts into a small set
   of strings ("64k" | "128k" | "200k" | "256k" | "1m" | "other"
   | "zero") so the cardinality stays bounded.

   Operators use this counter to detect drift: the same
   ([model_used], [resolved_model_id]) pair should land in ONE
   bucket; observing two buckets means the resolution path
   produced different ceilings on different turns.  The 42% /
   17% / 41% split for [claude_code:auto] reported in #9953 is
   directly visible here as three counter rows. *)

(* #10121: keeper turn livelock observer.  Each turn-start
   bumps [Keeper_metrics.metric_keeper_turn_starts]; a re-start of the SAME
   turn id (turn counter did not advance) bumps the dedicated
   [Keeper_metrics.metric_keeper_turn_reattempts].  Operators alert on
   [rate(masc_keeper_turn_reattempts_total[5m]) > 0] and pick
   up stuck-turn pairs without grepping log lines.  See also
   [Keeper_metrics.metric_keeper_turn_regressions] when the FSM moves to a
   strictly LOWER turn id (very unusual; indicative of
   write_meta race losing an in-memory counter increment,
   #9733). *)

(* #9943: per-keeper turn-latency bucket counter.  Each completed
   turn lands in exactly one [latency_bucket] label so a Prometheus
   query like
     rate(masc_keeper_turn_latency_bucket_total{bucket="600-1200s"}[5m])
   directly surfaces slow-turn keepers without needing the JSONL
   ledger.  20-minute turns from oas_timeout_budget exhaustion
   (#9933, observed 1,204,542 ms = 20 min on taskmaster
   2026-04-24) appear in the [over_1200s] bucket and operators can
   alert on its rate.  Existing [masc_llm_inference_duration_seconds]
   histogram is labelled by [model] only (per-LLM-call latency); this
   counter labels by [keeper] (per-turn latency) and uses bucket
   strings instead of histogram observations so dashboards can group
   counts directly. *)

(* #9933 follow-up: per-turn latency buckets split by the effective
   provider/model/cascade surface.  [Keeper_metrics.metric_keeper_turn_latency_bucket]
   tells operators which keeper is slow; this counter answers the next
   operational question: which provider/cascade/profile is burning the
   timeout budget.  Labels are bounded by fleet size, configured model
   labels, configured cascades, channel vocabulary, and the five bucket
   names from [Keeper_unified_metrics.turn_latency_bucket]. *)

(* P-DASH-01: provider cooldown skip counter.
   When a cascade's provider is in cooldown and the keeper
   fail-opens to a fallback cascade, increment this counter
   so operators can see how often cooldown is triggering
   cascade switches.  Labels: keeper, from_cascade, to_cascade. *)

(* P-DASH-01: provider cooldown remaining seconds gauge.
   Exposes the current cooldown duration so operators can see
   which cascade is blocked and for how long without log parsing.
   Labels: keeper, cascade. *)

(* P-DASH-13: provider block duration histogram.
   Records the duration (in seconds) for which a provider is placed
   in cooldown each time a cooldown is applied or extended.
   Labels: provider. *)

(* #10569: board persist mutex acquire / held latency.  Recorded by
   [Board_core.with_persist_lock] so operators can distinguish
   queueing from syscall stall when keeper_board_post / comment / vote
   tool calls hit the 60s default tool timeout. *)
let metric_board_persist_lock_acquire_sec = "masc_board_persist_lock_acquire_sec"
let metric_board_persist_lock_held_sec = "masc_board_persist_lock_held_sec"

(* Backend filesystem mutex contention diagnostic.  Recorded by
   [Backend.FileSystem.with_observed_mutex] via
   [Backend.FileSystem.set_mutex_observers] (installed once from the
   main library at startup).  Scoped to writer paths
   (set / delete / set_if_not_exists). Read paths are not measured by
   these histograms. Labels: [op]. *)
let metric_backend_mutex_acquire_sec = "masc_backend_mutex_acquire_sec"
let metric_backend_mutex_held_sec = "masc_backend_mutex_held_sec"

(* P-DASH-02: turn queue depth gauge.  Semaphore waiters are
   observable via [autonomous_waiter_snapshot_for_test] but were
   only emitted as a debug log line.  Surfacing as a gauge lets
   operators alert on queue pressure without log parsing.
   Labels: keeper, channel. *)

(* #10125: keeper supervisor sweep observability.

   The supervisor sweep is a Pulse loop that recovers crashed
   keepers.  When the loop fails to start (or stops), the fleet
   silently dies — keepers exit on cascade exhaustion and nobody
   restarts them.  Observed 2026-04-24: 14 keepers dead, supervisor
   "started" log line missing for 4h+ across a server restart.

   Two metrics surface the sweep liveness directly so dashboards
   can alert on absence instead of relying on a log grep:

   - [Keeper_metrics.metric_keeper_supervisor_sweep_starts_total] — increments
     once each time [start_supervisor_sweep] actually creates a
     Pulse (i.e., once per process unless explicitly stopped).
     If the counter does not advance after a server restart, the
     supervisor never came up.
   - [Keeper_metrics.metric_keeper_supervisor_last_sweep_unixtime] — gauge updated
     on every successful sweep beat.  Operator alert:
     [time() - masc_keeper_supervisor_last_sweep_unixtime > 90]
     means the sweep is stalled (default sweep interval is 30s). *)

(* #9770: counter for the [join_required] guard firing in
   [Mcp_server_eio_execute].  Production observed agents calling
   [masc_claim_next] (and similar) without [masc_join] first; the
   guard returns a polite error message but no fleet-wide signal
   exists for "how often does this happen, and which agent / tool
   pair is most affected".  Labels:
     [tool]: tool name that hit the guard (bounded by tool surface
       size, ~50).
     [agent_name]: agent that called the tool (bounded by fleet
       size, ~10).
     [reason]: ["room_uninitialized" | "agent_not_joined"].
   Cardinality: ~50 × ~10 × 2 = ~1000 series, safe for Prometheus. *)
let metric_tool_join_required_guard = "masc_tool_join_required_guard_total"

(* tool_metrics_persist write queue overflow.
   Counts JSONL records dropped because the bounded write queue is full.
   No labels (single source). Existing in-memory [dropped_full_queue]
   Atomic counter is summarised by sampled WARN (every 1024th drop);
   this Prometheus counter exposes per-drop emission so alerting on
   sustained pressure does not depend on log scraping. *)
let metric_tool_metrics_persist_dropped =
  "masc_tool_metrics_persist_dropped_total"

(* tool_keeper.cached_text_by_key CAS conflicts.
   Incremented once per recursive retry caused by an
   [Atomic.compare_and_set cache_ref] failure in the helper.  Each
   conflict triggers a second [compute ()] call, so sustained non-zero
   rate is a recompute-amplification signal.  No labels: the helper is
   currently used only for keeper_list_cache; add a cache label if a
   second caller is introduced. *)
let metric_tool_keeper_cache_cas_conflicts =
  "masc_tool_keeper_cache_cas_conflicts_total"

(* File_lock_eio lock-table CAS retries (single shared atomic).
   Bumped from [atomic_update] / [atomic_update_with_result] retry
   branches via [on_cas_retry_fn] callback wired in coord.ml — the
   masc_process sub-library cannot depend on Prometheus directly. *)
let metric_file_lock_table_cas_retries =
  "masc_file_lock_table_cas_retries_total"

(* Memory_jsonl.parse_line silent drop counter (V15 / RFC-0109 §5.1
   Option A).  Bumped from a callback wired in coord.ml — the
   masc_mcp_memory_jsonl leaf sub-library cannot depend on Prometheus
   directly (cycle).  Closed-vocabulary [reason] in
   {no_key | not_assoc | json_parse_error}.  Empty lines benign,
   not counted. *)
let metric_memory_jsonl_parse_drops =
  "masc_memory_jsonl_parse_drops_total"

(* tool_keeper.cache_ttl_seconds env-var parse fallback observability.
   Operator-supplied env var (e.g. MASC_KEEPER_LIST_CACHE_TTL_S) is
   present but the value cannot be parsed as a non-negative float; the
   helper silently coalesces to the per-caller default. Without this
   counter the operator never learns the env var has no effect ("set
   to 5s but cache still 2s" symptom). Closed-vocabulary labels:
     env_var: the env var name (bounded to the handful of callers)
     reason:  invalid_float | negative_or_nan *)
let metric_tool_keeper_cache_ttl_parse_failures =
  "masc_tool_keeper_cache_ttl_parse_failures_total"

(* #9771: keeper turn-slot semaphore wait timeout counter.

   Production observed multiple keepers ([sangsu], [janitor],
   [ramarama], [qa-king], [taskmaster]) repeatedly skipping turns
   with [semaphore wait > 60s, peers holding slot] — peers holding
   the slot for a long-running OAS call (276s-963s observed) ran
   past the 60s wait budget, every waiting keeper timed out, and
   the WARN log was the only signal.

   Three observable channels at which the timeout fires:
     - [autonomous_queue_head]: fairness-FIFO head wait exceeded
     - [autonomous]: autonomous-track semaphore acquire timed out
     - [turn]: shared turn semaphore acquire timed out

   Labels: [keeper, channel].  Cardinality = ~10 keepers × 3
   channels = ~30 series, well within Prometheus best practice. *)

(* Goal-loop Observe contract: the Grafana p99 query consumes
   [masc_keeper_semaphore_wait_seconds_bucket] grouped by keeper and cascade.
   The generic [register_histogram] exporter currently exposes summaries, so
   keeper_turn_slot emits the cumulative bucket companion explicitly. *)

let metric_timeout_policy_overshoot = "masc_timeout_policy_overshoot_total"

(* Keeper compaction (keeper_compact_policy.ml, tool_keeper.ml). *)

(* #9943: per-keeper counter of "compaction triggered but
   resulted in no token reduction".  2026-04-24 audit found
   956/972 (98.4%) of recorded compaction snapshots had
   [compaction_before_tokens = compaction_after_tokens > 0],
   meaning a trigger fired but the strategy returned the same
   token budget — a silent failure mode that
   [masc_keeper_compactions_total] hides because that counter
   is incremented on the trigger rather than the savings.  This
   counter labels by [keeper, trigger] so dashboards separate
   "context_overflow_imminent triggered noop" from "manual
   trigger noop" etc. and operators can attribute blame.  Pair
   with [masc_keeper_compaction_saved_tokens_total] (already
   shipping) — that one tracks the bytes saved by the 1.6%
   that DID save anything; this one tracks the 98.4% that
   ran for nothing. *)

(* Tier K5 — observability over the K4c per-keeper tool-emission
   accumulator registry. The registry is process-local; this gauge
   exposes its size so operators can alert on divergence from the
   active keeper count (a leak symptom would be registry size >
   live keeper count without trending down on teardown). *)

(* Tier K6 — per-keeper tagged tool-emission push counter. Increments
   each time [Keeper_tool_emission_hook.push] captures a parsed JSON
   tool result into the keeper's accumulator. Lets operators rank
   keepers by multimodal output volume and detect silent emission
   stalls (a keeper that should be emitting goes flat). Labels:
   [keeper]. *)

(* #13387: keeper tool diversity gauges. The count gauge gives
   dashboard/operator summaries a cheap per-keeper signal; the per-tool
   gauge identifies exactly which allowed tools are available but unused
   or below the diversity threshold. Labels:
   - [keeper] for the count gauge
   - [keeper, tool] for the per-tool gauge *)

(* #10349: keeper FS path rejection counter.  Pre-fix the
   user-facing read-path rejection strings carried the resolver's
   view of allowed sandbox roots (for example [(roots=[<list>])]
   and [(sandbox roots: [<list>])]) to the LLM.  Combined with
   the keeper identity drift documented in the issue (turn 433:
   contract emitted [masc-improver/Docker] while the resolver
   enumerated [analyst]'s sandbox), the error became a
   side-channel oracle for sibling sandboxes.

   The leak lives strictly in the user-visible string; the
   structured side-channel (Eio.traceln + this counter) keeps
   the rejection observable for operators without echoing the
   roots list back to the LLM.  Labels:
   - [kind] = "out_of_roots" (path resolved outside allowed)
              | "not_found_relative" (relative path matched no root) *)

(* Retired RFC-0026 admission-router shadow metric name. Kept only for
   historical Prometheus compatibility; active keeper scheduling uses the
   runtime lane and semaphore path. *)

(* Keeper keepalive (keeper_keepalive.ml). *)
let metric_write_meta_cas_retry_total = "masc_write_meta_cas_retry_total"

(* #10091: [require_tool_use] contract violations labelled by
   [has_current_task] (true = #10091's active-task path that
   [#10031] intentionally left strict, false = the no-task path
   that [#10031] relaxed to [Auto]) and by fine-grained
   [contract_status] ([passive_only], [needs_execution_progress],
   [claim_only_after_owned_task], [tool_surface_mismatch],
   [missing_required_tool_use]).  The fleet histogram of
   (keeper, contract_status) pairs tells the operator which
   keeper tool_presets need reshaping for the current task mix
   without masking the strict gate. *)
(* #10474: no_tool_capable_provider and proactive cycle outcome counters.
   [Keeper_metrics.metric_keeper_no_tool_provider_total] fires every time a keeper's
   cascade has zero tool-capable providers, labelled by cascade so
   the operator sees which cascade definition needs fixing.
   [Keeper_metrics.metric_keeper_proactive_outcome_total] classifies every scheduled
   autonomous cycle into tool_called | noop | error, giving a fleet-wide
   health ratio in Grafana. *)
(* PR-B: keeper turn skipped due to ollama saturation pre-check.
   Labelled by [keeper] and [cascade]. *)
(* Tool-setup and task-load failures during keeper tool surface assembly.
   task_load: Coord.get_tasks_raw exception while loading current task contract.
   tool_selection: TopK_llm or tool discovery exception during per-turn tool set assembly. *)
let metric_tool_policy_unloaded_query = "masc_tool_policy_unloaded_query_total"
let metric_tool_policy_init_failed = "masc_tool_policy_init_failed_total"
let metric_cache_desync_cleared = "masc_cache_desync_cleared_total"
let metric_egress_audit_missing = "masc_egress_audit_missing_total"
let metric_egress_audit_stale_orphan = "masc_egress_audit_stale_orphan_total"
let metric_persistence_read_drops = "masc_persistence_read_drops_total"
let metric_persistence_utf8_repair = "masc_persistence_utf8_repair_total"
let metric_discovery_history_failures = "masc_discovery_history_failures_total"
