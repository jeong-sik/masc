(** Keeper cycle execution with error-class
    handling, extracted from [keeper_heartbeat_loop.ml] (godfile
    decomp).

    [run_keeper_cycle] wraps a single keeper-cycle execution
    in an [in_turn_liveness_pulse] heartbeat fiber, then triages the
    result. The function is the canonical error-classification layer
    for the keepalive loop:

    - Fatal environment errors (Eio switch/net unavailable) → ERROR
      log + [masc_keeper_heartbeat_failures_total] tick (phase=
      fatal_environment) + [Keeper_registry.set_failure_reason
      Exception] + raises [Keeper_registry.Keeper_fiber_crash] for
      the supervisor to handle.

    - Provider-timeout errors → typed provider observation + WARN log. The
      original turn failure is preserved and no lifecycle state is inferred.

    - Any other [Error err] → DEBUG log + re-read meta (with
      [Keeper_metrics.MetaReadFailures] on read failure +
      site=none_after_failure or error_after_failure label).

    - [Ok updated] → clear prior observational failure reason and return
      updated meta.

    Pure helper move — no callback injection, all references reach
    external modules (Keeper_unified_turn, Agent_core, Log, Otel_metric_store,
    Keeper_metrics, Keeper_registry) or other siblings
    ([Keeper_heartbeat_loop_in_turn_pulse], [Observations]). *)

open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
module In_turn_pulse = Keeper_heartbeat_loop_in_turn_pulse
module Observations = Keeper_heartbeat_loop_observations

type cycle_outcome =
  | Completed of { meta : keeper_meta }
  | Checkpointed of
      { meta : keeper_meta
      ; followup : Keeper_agent_result.checkpoint_followup
      }
  | Input_required of keeper_meta
  | Cancelled of keeper_meta
  | Skipped of keeper_meta
  | Failed of
      { meta : keeper_meta
      ; failure : Keeper_unified_turn.turn_failure
      }
  | Rested of
      { meta : keeper_meta
      ; rest : Keeper_turn_driver.provider_rest
      ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
      }

let disposition_token = function
  | Completed _ -> "completed"
  | Checkpointed _ -> "checkpointed"
  | Input_required _ -> "input_required"
  | Cancelled _ -> "cancelled"
  | Skipped _ -> "skipped"
  | Failed _ -> "failed"
  | Rested _ -> "rested"
;;

let meta = function
  | Completed { meta; _ }
  | Checkpointed { meta; _ }
  | Input_required meta
  | Cancelled meta
  | Skipped meta
  | Failed { meta; _ }
  | Rested { meta; _ } ->
    meta
;;

let deferred_runtime_lane = function
  | Failed { failure; _ } -> failure.Keeper_unified_turn.deferred_runtime_lane
  | Rested { deferred_runtime_lane; _ } -> deferred_runtime_lane
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
      ?hitl_resolutions
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ~(turn_input : Keeper_heartbeat_source_batch.turn_input)
      ()
  =
  let admitted_execution =
    In_turn_pulse.with_in_turn_liveness_pulse ~ctx ~meta:meta_after_triage ~stop (fun () ->
      Keeper_unified_turn.run_keeper_cycle
        ~before_dispatch_authority
        ~execution_path:Keeper_unified_metrics_decision.Autonomous_cycle
        ?deferred_runtime_lane
        ?on_deferred_runtime_consumed
        ~config:ctx.config
        ~meta:meta_after_triage
        ~publication_recovery_provider:ctx.publication_recovery_provider
        ~observation:obs
        ~turn_input
        ?hitl_resolutions
        (* RFC-0315: pass the whole decision, not just its channel — the
           prompt renders the verdict reasons so the turn knows why it woke. *)
        ~turn_decision
        ~shared_context
        ?event_bus
        ())
  in
  let record_pulse outcome =
    Keeper_turn_pulse.record
      ~base_path:ctx.config.base_path
      ~keeper_name:meta_after_triage.name
      ~at:(Time_compat.now ())
      outcome;
    Keeper_row_broadcast.changed
      ~base_path:ctx.config.base_path
      ~keeper_name:meta_after_triage.name
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
    record_pulse Keeper_turn_pulse.Turn_failed;
    Failed { meta; failure }
  | Ok (Keeper_unified_turn.Turn_completed { meta }) ->
    record_pulse Keeper_turn_pulse.Turn_ok;
    Completed { meta }
  | Ok (Keeper_unified_turn.Turn_checkpointed { meta; followup }) ->
    record_pulse Keeper_turn_pulse.Turn_ok;
    Checkpointed { meta; followup }
  | Ok (Keeper_unified_turn.Turn_input_required updated) ->
    record_pulse Keeper_turn_pulse.Turn_ok;
    Input_required updated
  | Ok (Keeper_unified_turn.Turn_cancelled meta) -> Cancelled meta
  | Ok (Keeper_unified_turn.Turn_skipped meta) -> Skipped meta
  | Ok (Keeper_unified_turn.Turn_rested { meta; rest; deferred_runtime_lane }) ->
    record_pulse Keeper_turn_pulse.Turn_rested;
    Rested { meta; rest; deferred_runtime_lane }
;;

let run_keeper_cycle
      ~admission_token
      ?deferred_runtime_lane
      ?on_deferred_runtime_consumed
      ?event_bus
      ?hitl_resolutions
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ~(turn_input : Keeper_heartbeat_source_batch.turn_input)
      ()
  =
  (* One named switch per cycle: Eio writes a switch's name into the
     runtime-events ring when the switch opens, and the ring is overwritten
     within minutes, so a name opened once at lane start is invisible to a
     tracer attached later. Opened per cycle, every window sees which keeper
     a long run on the main domain belongs to. *)
  Eio.Switch.run ~name:("keeper " ^ meta_after_triage.name ^ " cycle") @@ fun _ ->
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
    ~turn_input
    ?event_bus
    ?hitl_resolutions
    ()
;;
