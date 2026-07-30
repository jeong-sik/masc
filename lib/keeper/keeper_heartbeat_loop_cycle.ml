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
    external modules (Keeper_unified_turn, Agent_sdk, Log, Otel_metric_store,
    Keeper_metrics, Keeper_registry) or other siblings
    ([Keeper_heartbeat_loop_in_turn_pulse], [Observations]). *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
module In_turn_pulse = Keeper_heartbeat_loop_in_turn_pulse
module Observations = Keeper_heartbeat_loop_observations

type cycle_outcome =
  | Completed of keeper_meta
  | Checkpointed of keeper_meta
  | Input_required of keeper_meta
  | Cancelled of keeper_meta
  | Skipped of keeper_meta
  | Failed of
      { meta : keeper_meta
      ; failure : Keeper_unified_turn.turn_failure
      }
  | Busy of
      { meta : keeper_meta
      ; block : Keeper_turn_admission.autonomous_block
      }
  | Manual_compaction_failed of
      { meta : keeper_meta
      ; failure : Keeper_manual_compaction.failure
      }
  | Manual_compaction_not_applied of
      { meta : keeper_meta
      ; no_compaction : Keeper_post_turn.no_compaction
      }
  | Manual_compaction_applied of
      { receipt : Keeper_manual_compaction.applied_receipt
      ; followup : cycle_outcome
      }

let rec meta = function
  | Completed meta
  | Checkpointed meta
  | Input_required meta
  | Cancelled meta
  | Skipped meta
  | Failed { meta; _ }
  | Busy { meta; _ }
  | Manual_compaction_failed { meta; _ }
  | Manual_compaction_not_applied { meta; _ } ->
    meta
  | Manual_compaction_applied { followup; _ } -> meta followup
;;

let rec turn_failure = function
  | Failed { failure; _ } -> Some failure
  | Manual_compaction_applied { followup; _ } -> turn_failure followup
  | Completed _ | Checkpointed _ | Input_required _ | Cancelled _ | Skipped _
  | Busy _ | Manual_compaction_failed _ | Manual_compaction_not_applied _ ->
    None
;;

let manual_compaction_followup_failure = function
  | Manual_compaction_applied { followup; _ } -> turn_failure followup
  | Completed _ | Checkpointed _ | Input_required _ | Cancelled _ | Skipped _
  | Failed _ | Busy _ | Manual_compaction_failed _ | Manual_compaction_not_applied _
    ->
    None
;;

let rec deferred_runtime_lane = function
  | Failed { failure; _ } -> failure.Keeper_unified_turn.deferred_runtime_lane
  | Manual_compaction_applied { followup; _ } -> deferred_runtime_lane followup
  | Completed _ | Checkpointed _ | Input_required _ | Cancelled _ | Skipped _
  | Busy _ | Manual_compaction_failed _ | Manual_compaction_not_applied _ ->
    None
;;

(* Body of [run_keeper_cycle], runnable only while holding the keeper's
   turn slot ([Keeper_turn_admission]). The post-failure meta re-reads stay
   inside the slot for the same reason as the chat lane: a concurrent turn
   must not interleave with this lane's meta writes (RFC-0225 §1). *)
let run_keeper_cycle_admitted
      ~before_dispatch_authority
      ?deferred_runtime_lane
      ?on_deferred_runtime_consumed
      ?event_bus
      ?hitl_resolution
      ?continuation_delivery_channel
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
        ~generation:meta_after_triage.runtime.nonce
        ~wake
        ?hitl_resolution
        ?continuation_delivery_channel
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
  | Ok (Keeper_unified_turn.Turn_completed updated) -> Completed updated
  | Ok (Keeper_unified_turn.Turn_checkpointed updated) -> Checkpointed updated
  | Ok (Keeper_unified_turn.Turn_input_required updated) -> Input_required updated
  | Ok (Keeper_unified_turn.Turn_cancelled meta) -> Cancelled meta
  | Ok (Keeper_unified_turn.Turn_skipped meta) -> Skipped meta
;;

let run_keeper_cycle_with
      ~run_manual_compaction
      ~admission_token
      ?deferred_runtime_lane
      ?on_deferred_runtime_consumed
      ?event_bus
      ?hitl_resolution
      ?continuation_delivery_channel
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ~(wake : Keeper_registry.wake_reason)
      ?manual_compaction_requested
      ()
  =
  let busy_outcome block =
    (match block with
     | Keeper_turn_admission.Shutdown_requested operation_id ->
       Log.Keeper.info
         "%s: autonomous turn admission closed by shutdown operation %s"
         meta_after_triage.name
         (Keeper_shutdown_types.Operation_id.to_string operation_id)
     | Keeper_turn_admission.Turn_busy in_flight ->
       (* Another lane holds this keeper's turn slot (RFC-0225 §3.1): skip the
          cycle and return the pre-cycle meta unchanged. The next heartbeat
          retries naturally — same shape as the pre-existing skip decisions. *)
       let holder =
         match in_flight with
         | Some { Keeper_turn_admission.lane; started_at } ->
           Printf.sprintf
             "%s turn running for %.0fs"
             (Keeper_turn_admission.lane_to_string lane)
             (* NDT-OK: gettimeofday renders the in-flight turn age for the log line only *)
             (Unix.gettimeofday () -. started_at)
         | None -> "holder info not yet published"
       in
       Log.Keeper.info
         "%s: turn slot busy (%s); skipping autonomous cycle until next heartbeat"
         meta_after_triage.name
         holder);
    Busy { meta = meta_after_triage; block }
  in
  let run_standard_cycle () =
    run_keeper_cycle_admitted
      ~before_dispatch_authority:
        (fun () -> Keeper_turn_admission.validate_before_dispatch admission_token)
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
      ?continuation_delivery_channel
      ()
  in
  match manual_compaction_requested with
  | Some false | None -> run_standard_cycle ()
  | Some true ->
    (* Manual compaction and its follow-up remain inside the already admitted
       cycle. The turn mutex is the only live admission authority; durable chat
       receipts do not add a separate compaction gate. *)
    (match
       run_manual_compaction
         ~before_dispatch_authority:
           (fun _observation ->
              Keeper_turn_admission.validate_before_dispatch admission_token)
         ~config:ctx.config
         ~meta:meta_after_triage
         ()
     with
     | `Busy block -> busy_outcome block
     | `Compaction_failed failure ->
       Log.Keeper.error
         ~keeper_name:meta_after_triage.name
         "manual compaction failed in owner lane: %s"
         (Keeper_manual_compaction.failure_to_string failure);
       Manual_compaction_failed { meta = meta_after_triage; failure }
     | `No_compaction (no_compaction : Keeper_post_turn.no_compaction) ->
       Log.Keeper.info
         ~keeper_name:meta_after_triage.name
         "manual compaction reached typed terminal: %s"
         (Keeper_compaction_outcome.no_compaction_reason_label no_compaction.reason);
       Manual_compaction_not_applied { meta = meta_after_triage; no_compaction }
     | `Applied (success : Keeper_manual_compaction.success) ->
       Manual_compaction_applied
         { receipt = success.receipt; followup = run_standard_cycle () })
;;

let run_keeper_cycle
      ~admission_token
      ?deferred_runtime_lane
      ?on_deferred_runtime_consumed
      ?event_bus
      ?hitl_resolution
      ?continuation_delivery_channel
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~turn_decision
      ~shared_context
      ~wake
      ?manual_compaction_requested
      ()
  =
run_keeper_cycle_with
  ~run_manual_compaction:
    (fun
      ~before_dispatch_authority:_
      ~config
      ~meta
      ()
      ->
       Keeper_manual_compaction.run_under_admission
         ~before_dispatch_authority:
           (fun _observation ->
              Keeper_turn_admission.validate_before_dispatch admission_token)
         ~config
         ~meta
         ())
    ~admission_token
    ?deferred_runtime_lane
    ?on_deferred_runtime_consumed
    ?event_bus
    ?hitl_resolution
    ?continuation_delivery_channel
    ~ctx
    ~meta_after_triage
    ~stop
    ~obs
    ~turn_decision
    ~shared_context
    ~wake
    ?manual_compaction_requested
    ()
;;
