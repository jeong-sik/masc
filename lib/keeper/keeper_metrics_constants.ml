(** Keeper_metrics_constants — Literal Prometheus metric name constants (part 1).

    Extracted from [Keeper_metrics] during godfile decomposition.
    These are backward-compatible string constants; new code should use the
    [Keeper_metrics.t] variant directly.

    @since God file decomposition *)

let metric_keeper_turns = "masc_keeper_turns_total"
let metric_keeper_input_tokens = "masc_keeper_input_tokens_total"
let metric_keeper_output_tokens = "masc_keeper_output_tokens_total"
let metric_keeper_cache_creation_tokens = "masc_keeper_cache_creation_tokens_total"
let metric_keeper_cache_read_tokens = "masc_keeper_cache_read_tokens_total"
let metric_keeper_usage_anomalies = "masc_keeper_usage_anomalies_total"
let metric_keeper_total_cost_usd = "masc_keeper_total_cost_usd"
let metric_keeper_turn_scheduled = "masc_keeper_turn_scheduled_total"
let metric_keeper_turn_completed = "masc_keeper_turn_completed_total"
let metric_keeper_idle_seconds = "masc_keeper_idle_seconds"
let metric_keeper_contract_violations = "masc_keeper_contract_violations_total"
let metric_keeper_alive_but_stuck = "masc_keeper_alive_but_stuck_total"
let metric_keeper_alive_but_stuck_seconds = "masc_keeper_alive_but_stuck_seconds"

let metric_keeper_alive_but_stuck_threshold_seconds =
  "masc_keeper_alive_but_stuck_threshold_seconds"
;;

let metric_keeper_alive_but_stuck_recovery_requests =
  "masc_keeper_alive_but_stuck_recovery_requests_total"
;;

let metric_keeper_alive_but_stuck_recovery = "masc_keeper_alive_but_stuck_recovery_total"
let metric_keeper_metric_emit_dropped = "masc_keeper_metric_emit_dropped_total"
let metric_keeper_context_max_observed = "masc_keeper_context_max_observed_total"
let metric_keeper_turn_starts = "masc_keeper_turn_starts_total"
let metric_keeper_turn_reattempts = "masc_keeper_turn_reattempts_total"
let metric_keeper_turn_regressions = "masc_keeper_turn_regressions_total"
let metric_keeper_turn_livelock_blocks = "masc_keeper_turn_livelock_blocks_total"

(* Per-(keeper, gate_kind) repeat-block counter. Bumped on every
   [`Repeated] outcome from [Keeper_livelock_state.record_block].
   Used by the dashboard to surface how many DEBUG-demoted blocks
   are being absorbed behind a single ERROR line — gives an upper
   bound on "noise absorbed". See lib/keeper/keeper_unified_turn.ml
   livelock branch + RFC-0088 (Counter-as-Fix policy). *)
let metric_keeper_turn_livelock_blocks_repeated =
  "masc_keeper_turn_livelock_blocks_repeated_total"
;;

(* Per-(keeper, gate_kind) threshold-park counter. Bumped exactly
   once per [(keeper, gate_kind)] entry per process lifetime: when
   [Keeper_livelock_state.record_block] crosses the configured
   park threshold. Pair with the durable ERROR log line at the same
   call site for dashboarding. *)
let metric_keeper_turn_livelock_blocks_threshold_park =
  "masc_keeper_turn_livelock_blocks_threshold_park_total"
;;
let metric_keeper_turn_latency_bucket = "masc_keeper_turn_latency_bucket_total"

let metric_keeper_turn_latency_by_model_bucket =
  "masc_keeper_turn_latency_by_model_bucket_total"
;;

let metric_keeper_provider_cooldown_skip = "masc_keeper_provider_cooldown_skip_total"

let metric_keeper_provider_cooldown_remaining_sec =
  "masc_keeper_provider_cooldown_remaining_sec"
;;

let metric_keeper_provider_block_duration_sec = "masc_keeper_provider_block_duration_sec"
let metric_keeper_turn_queue_depth = "masc_keeper_turn_queue_depth"
let metric_keeper_supervisor_sweep_starts = "masc_keeper_supervisor_sweep_starts_total"

let metric_keeper_supervisor_last_sweep_unixtime =
  "masc_keeper_supervisor_last_sweep_unixtime"
;;

(* RFC-0059 PR-7 soak observability.  Each per-keeper supervised launch
   emits at least one increment of this counter, tagged with one of:
   - "pool"            flag ON + [Domain_pool_ref] returned a pool,
                       body submitted to a worker Domain.
   - "inline_no_pool"  flag ON but [Domain_pool_ref] was [None]
                       (boot-order or misconfig); body ran inline.
   - "inline_disabled" flag OFF (default); body ran inline on [ctx.sw].
   - "body_failed"     worker body returned [Error _]; exception was logged
                       and re-raised on the supervisor fiber.
   - "submit_failed"   pool submit raised a non-cancellation exception;
                       body ran inline via the fallback path.

   The launch path is **not** mutually exclusive over a single launch:
   when an [outcome=pool] increment is followed by a worker-Domain
   submit failure, the fallback path emits an additional
   [outcome=submit_failed] increment for the same launch.  Aggregation
   queries that count "supervised launches" should therefore sum only
   over the launch-attempt outcomes [pool | inline_no_pool |
   inline_disabled] and treat [submit_failed] as a failure-ratio
   numerator over [outcome=pool] only. *)
