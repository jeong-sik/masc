(** Otel_metric_store metric-name string constants — extracted from [Otel_metric_store]
    to keep the parent file under the Godfile size cap. See
    [Otel_metric_store.ml] § "Metric Name Constants" for the convention.

    This module is [include]d in [Otel_metric_store] so callers reach every
    binding via [Otel_metric_store.metric_X] unchanged. *)

(** {1 Metric Name Constants}

    Exported so registration here and [inc_counter] / [set_gauge]
    call-sites in the keeper modules share a single source of truth.
    Without this, a typo on either side produces a dead series with
    no build error (the counter silently drifts to a new key).

    Convention: constant name drops the Otel_metric_store convention suffix
    ([_total] for counters), full metric name lives on the right-hand
    side. Consumers import [Otel_metric_store.<constant>] so the compiler
    catches typos. *)

(* Keeper turn lifecycle (registered in init, incremented in
   keeper_unified_turn.ml). *)

(** #10530: keeper completion-contract violations (passive-only or
    text-only turns rejected by the keeper agent loop).
    Labels: keeper_name, kind \in \{passive,text_only\}. *)

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

(* Objective Keeper turn-attempt observations. Each turn start
   bumps [Keeper_metrics.(to_string TurnStarts)]; a re-start of the SAME
   turn id (turn counter did not advance) bumps the dedicated
   [Keeper_metrics.(to_string TurnReattempts)].  Operators alert on
   [rate(masc_keeper_turn_reattempts_total[5m]) > 0] and pick
   up repeated-turn pairs without grepping log lines. See also
   [Keeper_metrics.(to_string TurnRegressions)] when the FSM moves to a
   strictly LOWER turn id (very unusual; indicative of
   write_meta race losing an in-memory counter increment,
   #9733). *)

(* #9943: per-keeper turn-latency bucket counter.  Each completed
   turn lands in exactly one [latency_bucket] label so a Otel_metric_store
   query like
     rate(masc_keeper_turn_latency_bucket_total{bucket="600-1200s"}[5m])
   directly surfaces slow-turn keepers without needing the JSONL
   ledger.  20-minute turns from provider_timeout exhaustion
   (#9933, observed 1,204,542 ms = 20 min on taskmaster
   2026-04-24) appear in the [over_1200s] bucket and operators can
   alert on its rate.  Existing [masc_llm_inference_duration_seconds]
   histogram is labelled by [model] only (per-LLM-call latency); this
   counter labels by [keeper] (per-turn latency) and uses bucket
   strings instead of histogram observations so dashboards can group
   counts directly. *)

(* #9933 follow-up: per-turn latency buckets split by the effective
   provider/model/runtime surface.  [Keeper_metrics.(to_string TurnLatencyBucket)]
   tells operators which keeper is slow; this counter answers the next
   operational question: which provider/runtime/profile is burning the
   timeout budget.  Labels are bounded by fleet size, configured model
   labels, configured runtimes, channel vocabulary, and the five bucket
   names from [Keeper_unified_metrics.turn_latency_bucket]. *)

(* P-DASH-01: provider cooldown skip counter.
   When a runtime's provider is in cooldown and the keeper
   fail-opens to a fallback runtime, increment this counter
   so operators can see how often cooldown is triggering
   runtime switches.  Labels: keeper, from_runtime, to_runtime. *)

(* P-DASH-01: provider cooldown remaining seconds gauge.
   Exposes the current cooldown duration so operators can see
   which runtime is blocked and for how long without log parsing.
   Labels: keeper, runtime. *)

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

(* P-DASH-02: turn queue depth gauge.  The live emission path surfaces queue
   pressure directly so operators do not need to parse debug logs.
   Labels: keeper, channel. *)

(* #10125: keeper supervisor sweep observability.

   The supervisor sweep is a Pulse loop that recovers crashed
   keepers.  When the loop fails to start (or stops), the fleet
   silently dies — keepers exit on runtime exhaustion and nobody
   restarts them.  Observed 2026-04-24: 14 keepers dead, supervisor
   "started" log line missing for 4h+ across a server restart.

   Two metrics surface the sweep liveness directly so dashboards
   can alert on absence instead of relying on a log grep:

   - [Keeper_metrics.(to_string SupervisorSweepStarts)] — increments
     once each time [start_supervisor_sweep] actually creates a
     Pulse (i.e., once per process unless explicitly stopped).
     If the counter does not advance after a server restart, the
     supervisor never came up.
   - [Keeper_metrics.(to_string SupervisorLastSweepUnixtime)] — gauge updated
     on every successful sweep beat.  Operator alert:
     [time() - masc_keeper_supervisor_last_sweep_unixtime > 90]
     means the sweep is stalled (default sweep interval is 30s). *)

(* tool_metrics_persist write queue overflow.
   Counts JSONL records dropped because the bounded write queue is full.
   No labels (single source). Existing in-memory [dropped_full_queue]
   Atomic counter is summarised by sampled WARN (every 1024th drop);
   this Otel_metric_store counter exposes per-drop emission so alerting on
   sustained pressure does not depend on log scraping. *)
let metric_tool_metrics_persist_dropped =
  Otel_metric_store_core.declare_counter "masc_tool_metrics_persist_dropped_total"

let metric_keeper_waiting_count = "masc_keeper_waiting_count"
let metric_keeper_waiting_age_seconds = "masc_keeper_waiting_age_seconds"
let metric_keeper_waiting_keeper_count = "masc_keeper_waiting_keeper_count"

(* Schedule unsupported payload counter. Labels:
   - [phase] in {creation, dispatch}.
   Raw payload kinds are intentionally not labels; they remain in typed
   errors/projections to avoid unbounded metric cardinality. *)
let metric_schedule_payload_unsupported_total =
  Otel_metric_store_core.declare_counter "masc_schedule_payload_unsupported_total"

let metric_tool_bind_required_guard =
  Otel_metric_store_core.declare_counter "masc_tool_bind_required_guard_total"

(* keeper_tool_call_log async append queue overflow.
   Counts full-I/O tool-call records dropped because the bounded
   best-effort queue is full. No labels (single source). *)
let metric_keeper_tool_call_log_queue_dropped =
  Otel_metric_store_core.declare_counter "masc_keeper_tool_call_log_queue_dropped_total"

(* keeper_tool_surface.cached_text_by_key CAS conflicts.
   Incremented once per recursive retry caused by an
   [Atomic.compare_and_set cache_ref] failure in the helper.  Each
   conflict triggers a second [compute ()] call, so sustained non-zero
   rate is a recompute-amplification signal.  No labels: the helper is
   currently used only for keeper_list_cache; add a cache label if a
   second caller is introduced. *)
let metric_tool_keeper_cache_cas_conflicts =
  Otel_metric_store_core.declare_counter "masc_tool_keeper_cache_cas_conflicts_total"

(* File_lock_eio lock-table CAS retries (single shared atomic).
   Bumped from [atomic_update] / [atomic_update_with_result] retry
   branches via [on_cas_retry_fn] callback wired in workspace.ml — the
   masc_process sub-library cannot depend on Otel_metric_store directly. *)
let metric_file_lock_table_cas_retries =
  Otel_metric_store_core.declare_counter "masc_file_lock_table_cas_retries_total"

(* keeper_tool_surface.cache_ttl_seconds env-var parse fallback observability.
   Operator-supplied env var (e.g. MASC_KEEPER_LIST_CACHE_TTL_S) is
   present but the value cannot be parsed as a non-negative float; the
   helper silently coalesces to the per-caller default. Without this
   counter the operator never learns the env var has no effect ("set
   to 5s but cache still 2s" symptom). Closed-vocabulary labels:
     env_var: the env var name (bounded to the handful of callers)
     reason:  invalid_float | negative_or_nan *)
let metric_tool_keeper_cache_ttl_parse_failures =
  Otel_metric_store_core.declare_counter "masc_tool_keeper_cache_ttl_parse_failures_total"

let metric_timeout_policy_overshoot = Otel_metric_store_core.declare_counter "masc_timeout_policy_overshoot_total"

(* Keeper compaction (keeper_compact_policy.ml, keeper_tool_surface.ml). *)

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
   roots list back to the LLM.  Label [kind="out_of_roots"] means the
   symlink-resolved candidate was outside every explicit allowed root. *)

(* Retired RFC-0026 admission-router shadow metric name. Kept only for
   historical Otel_metric_store compatibility; active keeper scheduling uses the
   runtime lane and semaphore path. *)

(* Keeper keepalive (keeper_keepalive.ml). *)
let metric_write_meta_cas_retry_total = Otel_metric_store_core.declare_counter "masc_write_meta_cas_retry_total"

(* #10474: proactive cycle outcome counters.
   [Keeper_metrics.(to_string NoToolProvider)] fires every time a keeper's
   runtime has zero tool-capable providers, labelled by runtime so
   the operator sees which runtime definition needs fixing.
   [Keeper_metrics.(to_string ProactiveOutcome)] classifies every scheduled
   autonomous cycle into tool_called | noop | error, giving a fleet-wide
   health ratio in Grafana. *)
(* PR-B: keeper turn skipped due to ollama saturation pre-check.
   Labelled by [keeper] and [runtime]. *)
let metric_cache_desync_cleared = Otel_metric_store_core.declare_counter "masc_cache_desync_cleared_total"
let metric_persistence_read_drops = Otel_metric_store_core.declare_counter "masc_persistence_read_drops_total"
let metric_persistence_utf8_repair = Otel_metric_store_core.declare_counter "masc_persistence_utf8_repair_total"
let metric_discovery_history_failures = Otel_metric_store_core.declare_counter "masc_discovery_history_failures_total"

(* #18855: per-tool correction_pipeline fix counter.
   Incremented when the OAS agent_tools module reports that
   correction_pipeline fixed input fields for a tool.
   Labels: [tool_name]. *)
let metric_oas_correction_pipeline_fixes_total =
  Otel_metric_store_core.declare_counter "masc_oas_correction_pipeline_fixes_total"
