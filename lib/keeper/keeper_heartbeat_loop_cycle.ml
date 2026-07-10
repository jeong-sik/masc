(** Keeper cycle execution with error-class
    handling, extracted from [keeper_heartbeat_loop.ml] (godfile
    decomp).

    [run_keeper_cycle] wraps a single keeper-cycle execution
    in an [in_turn_liveness_pulse] heartbeat fiber, then triages the
    result. The function is the canonical error-classification layer
    for the keepalive loop:

    - Fatal environment errors (Eio switch/net unavailable) → ERROR
      log + [metric_keeper_heartbeat_failures] tick (phase=
      fatal_environment) + [Keeper_registry.set_failure_reason
      Exception] + raises [Keeper_registry.Keeper_fiber_crash] for
      the supervisor to handle.

    - Provider-timeout errors → provider-timeout strike-counter bump (seeded from
      [prior_provider_timeout_strikes]) + persistent failure
      reason + observation recording + [Keeper_failure_policy.decide]
      kill/keep decision + [metric_keeper_provider_timeout_strike]
      tick with policy-derived outcome label.

    - Any other [Error err] → DEBUG log + re-read meta (with
      [metric_keeper_meta_read_failures] on read failure +
      Site=none_after_failure or error_after_failure label).

    - [Ok updated] → reset budget exhaustion + clear provider-timeout
      failure reason + return updated meta.

    Pure helper move — no callback injection, all references reach
    external modules (Keeper_unified_turn, Agent_sdk, Log, Otel_metric_store,
    Keeper_metrics, Keeper_registry, Keeper_turn_holders,
    Keeper_failure_policy) or other siblings
    ([Keeper_heartbeat_loop_in_turn_pulse], [Observations]). *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
module In_turn_pulse = Keeper_heartbeat_loop_in_turn_pulse
module Observations = Keeper_heartbeat_loop_observations

(* Body of [run_keeper_cycle], runnable only while holding the keeper's
   turn slot ([Keeper_turn_admission]). The post-failure meta re-reads stay
   inside the slot for the same reason as the chat lane: a concurrent turn
   must not interleave with this lane's meta writes (RFC-0225 §1). *)
let run_keeper_cycle_admitted
      ?event_bus
      ?hitl_delivery_channel
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ()
  =
  match
    In_turn_pulse.with_in_turn_liveness_pulse ~ctx ~meta:meta_after_triage ~stop (fun () ->
      Keeper_unified_turn.run_keeper_cycle
        ~config:ctx.config
        ~meta:meta_after_triage
        ~observation:obs
        ~generation:meta_after_triage.runtime.generation
        ~channel:turn_decision.channel
        ?hitl_delivery_channel
        (* RFC-0315: pass the whole decision, not just its channel — the
           prompt renders the verdict reasons so the turn knows why it woke. *)
        ~turn_decision
        ~shared_context
        ?event_bus
        ())
  with
  | Error err ->
    let e_str = Agent_sdk.Error.to_string err in
    Log.Keeper.debug "%s: keeper cycle failed: %s" meta_after_triage.name e_str;
    (* Classify on the typed [Config (InvalidConfig { field = "eio_context" })]
       tag via [Runtime_oas_runner.is_eio_context_error], not by substring-
       scanning [e_str]: an Eio wording change must not silently drop this
       fatal-environment promotion. [e_str] is kept for the log/failure-reason
       message only. *)
    if Runtime_oas_runner.is_eio_context_error err then (
      Log.Keeper.error
        "%s: fatal environment error — promoting to Keeper_fiber_crash: %s"
        meta_after_triage.name
        e_str;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string HeartbeatFailures)
        ~labels:[ "keeper", meta_after_triage.name; "phase", "fatal_environment" ]
        ();
      Keeper_registry.set_failure_reason
        ~base_path:ctx.config.base_path
        meta_after_triage.name
        (Some
           (Keeper_registry.Exception (Printf.sprintf "fatal environment error: %s" e_str)));
      raise Keeper_registry.Keeper_fiber_crash);
    if Observations.is_provider_timeout_error err
    then (
      let keeper_name = meta_after_triage.name in
      Keeper_turn_holders.reset_budget_exhaustion ~keeper_name;
      Log.Keeper.warn
        "%s: provider_timeout observed; preserving original turn \
         failure without Provider_timeout_loop latch"
        keeper_name);
    (match read_effective_meta ctx.config meta_after_triage.name with
     | Ok (Some latest) -> latest
     | Ok None ->
       Log.Keeper.error
         "keeper:%s read_effective_meta returned None after turn failure, using stale meta"
         meta_after_triage.name;
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string MetaReadFailures)
         ~labels:
           [ "keeper", meta_after_triage.name; "site", "none_after_failure" ]
         ();
       meta_after_triage
     | Error e ->
       Log.Keeper.error
         "keeper:%s read_effective_meta failed after turn failure (%s), using stale meta"
         meta_after_triage.name
         e;
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string MetaReadFailures)
         ~labels:
           [ "keeper", meta_after_triage.name; "site", "error_after_failure" ]
         ();
       meta_after_triage)
  | Ok updated ->
    Keeper_turn_holders.reset_budget_exhaustion ~keeper_name:meta_after_triage.name;
    Observations.clear_provider_timeout_failure_reason
      ~base_path:ctx.config.base_path
      ~keeper_name:meta_after_triage.name;
    updated
;;

let run_keeper_cycle
      ?event_bus
      ?hitl_delivery_channel
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ()
  =
  match
    Keeper_turn_admission.run_if_free
      ~base_path:ctx.config.base_path
      ~keeper_name:meta_after_triage.name
      (run_keeper_cycle_admitted
         ~ctx
         ~meta_after_triage
         ~stop
         ~obs
         ~turn_decision
         ~shared_context
         ?event_bus
         ?hitl_delivery_channel)
  with
  | `Ran updated -> updated
  | `Busy in_flight ->
    (* Another lane holds this keeper's turn slot (RFC-0225 §3.1): skip the
       cycle and return the pre-cycle meta unchanged. The next heartbeat
       retries naturally — same shape as the pre-existing skip decisions. *)
    let holder =
      match in_flight with
      | Some { Keeper_turn_admission.lane; started_at } ->
        (* NDT-OK: gettimeofday renders the in-flight turn age for the log line only *)
        Printf.sprintf
          "%s turn running for %.0fs"
          (Keeper_turn_admission.lane_to_string lane)
          (Unix.gettimeofday () -. started_at)
      | None -> "holder info not yet published"
    in
    Log.Keeper.info
      "%s: turn slot busy (%s); skipping autonomous cycle until next heartbeat"
      meta_after_triage.name
      holder;
    meta_after_triage
;;
