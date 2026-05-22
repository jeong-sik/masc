(** Keeper cycle execution under slot control with error-class
    handling, extracted from [keeper_heartbeat_loop.ml] (godfile
    decomp).

    [run_keeper_cycle_with_slot] wraps a single keeper-cycle execution
    in an [in_turn_liveness_pulse] heartbeat fiber, then triages the
    result. The function is the canonical error-classification layer
    for the keepalive loop:

    - Fatal environment errors (Eio switch/net unavailable) → ERROR
      log + [metric_keeper_heartbeat_failures] tick (phase=
      fatal_environment) + [Keeper_registry.set_failure_reason
      Exception] + raises [Keeper_registry.Keeper_fiber_crash] for
      the supervisor to handle.

    - Legacy timeout-budget errors → provider-timeout strike-counter bump (seeded from
      [prior_oas_timeout_budget_strikes]) + persistent failure
      reason + observation recording + [Keeper_failure_policy.decide]
      kill/keep decision + [metric_keeper_provider_timeout_strike]
      tick with policy-derived outcome label.

    - Any other [Error err] → DEBUG log + re-read meta (with
      [metric_keeper_meta_read_failures] on read failure +
      Site=none_after_failure or error_after_failure label).

    - [Ok updated] → reset budget exhaustion + clear OAS timeout
      budget failure reason + return updated meta.

    Pure helper move — no callback injection, all references reach
    external modules (Keeper_unified_turn, Agent_sdk, Log, Prometheus,
    Keeper_metrics, Keeper_registry, Keeper_turn_slot,
    Keeper_failure_policy) or other siblings
    ([Keeper_heartbeat_loop_in_turn_pulse], [Observations]). *)

open Keeper_types
module In_turn_pulse = Keeper_heartbeat_loop_in_turn_pulse
module Observations = Keeper_heartbeat_loop_observations

let run_keeper_cycle_with_slot
      ~ctx
      ~meta_after_cursor_persist
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ~semaphore_wait_ms
      ~slot_control
      ?selected_item
      ()
  =
  match
    In_turn_pulse.with_in_turn_liveness_pulse ~ctx ~meta:meta_after_cursor_persist ~stop (fun () ->
      Keeper_unified_turn.run_keeper_cycle
        ~config:ctx.config
        ~meta:meta_after_cursor_persist
        ~observation:obs
        ~generation:meta_after_cursor_persist.runtime.generation
        ~channel:turn_decision.channel
        ~semaphore_wait_ms
        ~turn_slot_control:slot_control
        ~shared_context
        ?selected_item
        ())
  with
  | Error err ->
    let e_str = Agent_sdk.Error.to_string err in
    Log.Keeper.debug "%s: keeper cycle failed: %s" meta_after_cursor_persist.name e_str;
    if
      String_util.contains_substring e_str "Eio switch not available"
      || String_util.contains_substring e_str "Eio net not available"
    then (
      Log.Keeper.error
        "%s: fatal environment error — promoting to Keeper_fiber_crash: %s"
        meta_after_cursor_persist.name
        e_str;
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_heartbeat_failures
        ~labels:[ "keeper", meta_after_cursor_persist.name; "phase", "fatal_environment" ]
        ();
      Keeper_registry.set_failure_reason
        ~base_path:ctx.config.base_path
        meta_after_cursor_persist.name
        (Some
           (Keeper_registry.Exception (Printf.sprintf "fatal environment error: %s" e_str)));
      raise Keeper_registry.Keeper_fiber_crash);
    if Observations.is_oas_timeout_budget_error err
    then (
      let keeper_name = meta_after_cursor_persist.name in
      Keeper_turn_slot.reset_budget_exhaustion ~keeper_name;
      Log.Keeper.warn
        "%s: legacy oas_timeout_budget observed; preserving original turn \
         failure without Provider_timeout_loop latch"
        keeper_name);
    (match read_meta ctx.config meta_after_cursor_persist.name with
     | Ok (Some latest) -> latest
     | Ok None ->
       Log.Keeper.error
         "keeper:%s read_meta returned None after turn failure, using stale meta"
         meta_after_cursor_persist.name;
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_meta_read_failures
         ~labels:
           [ "keeper", meta_after_cursor_persist.name; "site", "none_after_failure" ]
         ();
       meta_after_cursor_persist
     | Error e ->
       Log.Keeper.error
         "keeper:%s read_meta failed after turn failure (%s), using stale meta"
         meta_after_cursor_persist.name
         e;
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_meta_read_failures
         ~labels:
           [ "keeper", meta_after_cursor_persist.name; "site", "error_after_failure" ]
         ();
       meta_after_cursor_persist)
  | Ok updated ->
    Keeper_turn_slot.reset_budget_exhaustion ~keeper_name:meta_after_cursor_persist.name;
    Observations.clear_oas_timeout_budget_failure_reason
      ~base_path:ctx.config.base_path
      ~keeper_name:meta_after_cursor_persist.name;
    updated
;;
