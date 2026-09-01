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

    - Provider-timeout errors → typed provider observation + WARN log. The
      original turn failure is preserved and no lifecycle state is inferred.

    - Any other [Error err] → DEBUG log + re-read meta (with
      [metric_keeper_meta_read_failures] on read failure +
      Site=none_after_failure or error_after_failure label).

    - [Ok updated] → clear prior observational failure reason and return
      updated meta.

    Pure helper move — no callback injection, all references reach
    external modules (Keeper_unified_turn, Agent_core, Log, Otel_metric_store,
    Keeper_metrics, Keeper_registry) or other siblings
    ([Keeper_heartbeat_loop_in_turn_pulse], [Observations]). *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
module In_turn_pulse = Keeper_heartbeat_loop_in_turn_pulse
module Observations = Keeper_heartbeat_loop_observations

type cycle_outcome =
  | Completed of
      { meta : keeper_meta
      ; continuation_route :
          Keeper_unified_turn.continuation_route_disposition
      }
  | Checkpointed of
      { meta : keeper_meta
      ; checkpoint_reason : Keeper_unified_turn.checkpoint_reason
      ; continuation_route : Keeper_unified_turn.continuation_route_disposition
      }
  | Input_required of keeper_meta
  | Cancelled of keeper_meta
  | Skipped of keeper_meta
  | Failed of
      { meta : keeper_meta
      ; failure : Keeper_unified_turn.turn_failure
      }

let disposition_token = function
  | Completed _ -> "completed"
  | Checkpointed _ -> "checkpointed"
  | Input_required _ -> "input_required"
  | Cancelled _ -> "cancelled"
  | Skipped _ -> "skipped"
  | Failed _ -> "failed"
;;

let meta = function
  | Completed { meta; _ }
  | Checkpointed { meta; _ }
  | Input_required meta
  | Cancelled meta
  | Skipped meta
  | Failed { meta; _ } ->
    meta
;;

let deferred_runtime_lane = function
  | Failed { failure; _ } -> failure.Keeper_unified_turn.deferred_runtime_lane
  | Completed _ | Checkpointed _ | Input_required _ | Cancelled _ | Skipped _ ->
    None
;;

(* Body of [run_keeper_cycle], runnable only while holding the keeper's
   Keeper Owner child. The post-failure meta re-reads stay
   inside the slot for the same reason as the chat lane: a concurrent turn
   must not interleave with this lane's meta writes (RFC-0225 §1). *)
let run_keeper_cycle_admitted
      ~before_dispatch_authority
      ?deferred_runtime_lane
      ?on_deferred_runtime_consumed
      ?event_bus
      ?hitl_resolution
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ~(wake : Keeper_registry.wake_reason)
      ()
  =
  let admitted_execution =
    In_turn_pulse.with_in_turn_liveness_pulse ~ctx ~meta:meta_after_triage ~stop (fun () ->
      Keeper_unified_turn.run_keeper_cycle
        ~before_dispatch_authority
        ?deferred_runtime_lane
        ?on_deferred_runtime_consumed
        ~config:ctx.config
        ~meta:meta_after_triage
        ~publication_recovery_provider:ctx.publication_recovery_provider
        ~observation:obs
        ~wake
        ?hitl_resolution
        (* RFC-0315: pass the whole decision, not just its channel — the
           prompt renders the verdict reasons so the turn knows why it woke. *)
        ~turn_decision
        ~shared_context
        ?event_bus
        ())
  in
  match admitted_execution with
  | Error failure ->
    let err = failure.Keeper_unified_turn.error in
    let e_str = Agent_core.Error.to_string err in
    Log.Keeper.debug "%s: keeper cycle failed: %s" meta_after_triage.name e_str;
    (* Classify on the typed [Config (InvalidConfig { field = "eio_context" })]
       tag via [Runtime_agent_core_runner.is_eio_context_error], not by substring-
       scanning [e_str]: an Eio wording change must not silently drop this
       fatal-environment promotion. [e_str] is kept for the log/failure-reason
       message only. *)
    if Runtime_agent_core_runner.is_eio_context_error err then (
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
    then
      Log.Keeper.warn
        "%s: provider_timeout observed; preserving original turn failure"
        meta_after_triage.name;
    let meta =
      match read_effective_meta ctx.config meta_after_triage.name with
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
        meta_after_triage
    in
    Failed { meta; failure }
  | Ok
      (Keeper_unified_turn.Turn_completed
        { meta; continuation_route }) ->
    Completed { meta; continuation_route }
  | Ok
      (Keeper_unified_turn.Turn_checkpointed
         { meta; checkpoint_reason; continuation_route }) ->
    Checkpointed { meta; checkpoint_reason; continuation_route }
  | Ok (Keeper_unified_turn.Turn_input_required updated) -> Input_required updated
  | Ok (Keeper_unified_turn.Turn_cancelled meta) -> Cancelled meta
  | Ok (Keeper_unified_turn.Turn_skipped meta) -> Skipped meta
;;

let run_keeper_cycle
      ~admission_token
      ?deferred_runtime_lane
      ?on_deferred_runtime_consumed
      ?event_bus
      ?hitl_resolution
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ~(wake : Keeper_registry.wake_reason)
      ()
  =
  run_keeper_cycle_admitted
    ~before_dispatch_authority:
      (fun () -> Keeper_turn_dispatch_authority.validate admission_token)
    ?deferred_runtime_lane
    ?on_deferred_runtime_consumed
    ~ctx
    ~meta_after_triage
    ~stop
    ~obs
    ~turn_decision
    ~shared_context
    ~wake
    ?event_bus
    ?hitl_resolution
    ()
;;
