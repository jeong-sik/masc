(** Keepalive supervision entry-point, extracted from
    [keeper_supervisor.ml] (godfile decomp).

    [supervise_keepalive] decides whether to spawn a supervised
    keepalive fiber for [meta]. It launches fresh registrations and
    resumes registrations still in [Offline]. Other registered phases
    remain owned by the lifecycle sweep. On a fresh registration:

    1. Asks [Keeper_registry] for a spawn-slot decision. On [Error
       reason], records the denial and publishes an [Admission_denied]
       lifecycle event in [Offline] phase; the keeper does not spawn.
    2. On [Ok ()]:
       - logs persona drift if missing
       - registers offline in [Keeper_registry]
       - lazily initializes the workspace root (Workspace.init)
       - syncs keeper workspace presence + writes meta (failures degrade
         to original meta but tick failure counters)
       - calls the injected [~launch_supervised_fiber] to actually
         spawn the supervised fiber
       - publishes a [Started] / [Running]-phase lifecycle event

    Two parent-local callbacks are injected to avoid sibling -> parent
    cycles:

    - [~publish_lifecycle] — emits structured lifecycle events
    - [~launch_supervised_fiber] — the large parent-local fiber
      spawner (the body of which itself does not move; this sibling
      just forwards) *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_execution
module Startup_helpers = Keeper_supervisor_startup_helpers

let supervise_keepalive
      ~(publish_lifecycle :
         event:Keeper_lifecycle_events.lifecycle_event ->
         string -> string -> unit -> unit)
      ~(launch_supervised_fiber :
         proactive_warmup_sec:int ->
         _ context ->
         keeper_meta ->
         Keeper_registry.registry_entry ->
         (unit, Keeper_state_machine.transition_error) result)
      ~proactive_warmup_sec
      (ctx : _ context)
      (meta : keeper_meta)
  =
  let base_path = ctx.config.base_path in
  let admission =
    Keeper_turn_admission.snapshot_for
      ~base_path
      ~keeper_name:meta.name
  in
  let execution_truth =
    Keeper_activation_readiness.classify_owner_execution
      ~shutdown_operation_id:admission.snapshot_shutdown_operation_id
      ~runtime:
        (Keeper_activation_readiness.owner_runtime_of_registry_entry
           (Keeper_registry.get ~base_path meta.name))
      (Ok meta)
  in
  let record_recovery_retained reason =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string LifecycleDispatchRejections)
      ~labels:
        [ "keeper", meta.name
        ; "event", "supervisor_keepalive_start"
        ; "reason", reason
        ]
      ();
    publish_lifecycle
      ~event:
        (Keeper_lifecycle_events.Custom_event
           { verb = Keeper_lifecycle_events.Admission_denied
           ; phase = Some Keeper_state_machine.Offline
           })
      meta.name
      reason
      ()
  in
  let launch_registered reg =
    let () =
      Startup_helpers.log_persona_drift_if_missing ~base_path meta
    in
    (try
       if not (Workspace_utils.is_initialized ctx.config)
       then (
         let (_init_msg : string) = Workspace.init ctx.config ~agent_name:None in
         ())
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string WorkspaceInitFailures)
         ~labels:[ "keeper", meta.name ]
         ();
       Log.Keeper.error "supervisor workspace init failed: %s" (Printexc.to_string exn));
    let live_meta =
      try
        let synced = meta in
        (match write_meta ctx.config synced with
         | Ok () -> ()
         | Error msg ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string WriteMetaFailures)
             ~labels:[ "keeper", meta.name; "phase", "presence_sync" ]
             ();
           Log.Keeper.warn
             "supervisor presence sync: write_meta failed for %s: %s"
             meta.name
             msg);
        synced
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string PresenceSyncFailures)
          ~labels:[ "keeper", meta.name ]
          ();
        Log.Keeper.error "supervisor presence sync failed: %s" (Printexc.to_string exn);
        meta
    in
    Keeper_registry.update_meta ~base_path meta.name live_meta;
    match launch_supervised_fiber ~proactive_warmup_sec ctx live_meta reg with
    | Error _ -> ()
    | Ok () ->
      publish_lifecycle
        ~event:
          (Keeper_lifecycle_events.Custom_event
             { verb = Keeper_lifecycle_events.Started
             ; phase = Some Keeper_state_machine.Running
             })
        meta.name
        "supervised"
        ()
  in
  let register_and_launch () =
    match
      Keeper_registry.register_offline_if_admitted
        ~base_path
        meta.name
        meta
    with
    | Error (Keeper_registry.Registration_shutdown_reserved operation_id) ->
      Log.Keeper.warn
        "supervisor launch skipped %s because shutdown operation %s owns admission"
        meta.name
        (Keeper_shutdown_types.Operation_id.to_string operation_id)
    | Error (Keeper_registry.Registration_lifecycle_reserved owner) ->
      Log.Keeper.warn
        "supervisor launch skipped %s because lifecycle transaction owns admission: %s"
        meta.name
        (Keeper_lifecycle_reservation.snapshot_to_string owner)
    | Error (Keeper_registry.Registration_invalid validation_error) ->
      Log.Keeper.error
        "supervisor registry validation rejected %s: %s"
        meta.name
        (Keeper_registry.registry_entry_validation_error_to_string validation_error)
    | Error (Keeper_registry.Registration_event_queue_unavailable { keeper_name; detail }) ->
      Log.Keeper.error
        "supervisor registry event queue unavailable keeper=%s: %s"
        keeper_name
        detail
    | Error
        (Keeper_registry.Registration_board_cursor_unavailable
           { keeper_name; reason }) ->
      Log.Keeper.error
        "supervisor registry board cursor unavailable keeper=%s: %s"
        keeper_name
        (Keeper_registry.board_cursor_registration_error_to_string reason)
    | Ok reg -> launch_registered reg
  in
  match execution_truth with
  | Keeper_activation_readiness.Unknown detail ->
    record_recovery_retained "unknown";
    Log.Keeper.error
      "%s: supervisor keepalive recovery retained because owner execution truth is unknown: %s"
      meta.name
      detail
  | Keeper_activation_readiness.Shutdown_fenced operation_id ->
    record_recovery_retained "shutdown_fenced";
    Log.Keeper.warn
      "%s: supervisor keepalive recovery retained by shutdown operation %s"
      meta.name
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
  | Keeper_activation_readiness.Retained_disabled reason ->
    let reason =
      Keeper_activation_readiness.retained_disabled_reason_to_wire reason
    in
    record_recovery_retained reason;
    Log.Keeper.info
      "%s: supervisor keepalive recovery retained by disabled policy: %s"
      meta.name
      reason
  | Keeper_activation_readiness.Paused_dead reason ->
    let reason =
      Keeper_activation_readiness.paused_dead_reason_to_wire reason
    in
    record_recovery_retained reason;
    Log.Keeper.info
      "%s: supervisor keepalive recovery retained by paused/dead owner truth: %s"
      meta.name
      reason
  | Keeper_activation_readiness.Executable -> ()
  | Keeper_activation_readiness.Recoverable ->
    (match Keeper_registry.get ~base_path meta.name with
     | None -> register_and_launch ()
     | Some reg ->
       (match reg.phase with
        | Keeper_state_machine.Offline -> launch_registered reg
        | Keeper_state_machine.Running
        | Keeper_state_machine.Failing
        | Keeper_state_machine.Overflowed
        | Keeper_state_machine.Compacting
        | Keeper_state_machine.HandingOff
        | Keeper_state_machine.Draining
        | Keeper_state_machine.Paused
        | Keeper_state_machine.Stopped
        | Keeper_state_machine.Crashed
        | Keeper_state_machine.Restarting
        | Keeper_state_machine.Dead ->
          Log.Keeper.debug
            "%s: supervisor keepalive retained existing %s owner for lifecycle sweep"
            meta.name
            (Keeper_state_machine.phase_to_string reg.phase)))
;;
