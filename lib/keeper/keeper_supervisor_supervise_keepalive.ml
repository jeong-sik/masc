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

let same_offline_generation
      ~(expected : Keeper_registry.registry_entry)
      (current : Keeper_registry.registry_entry)
  =
  Keeper_lane.Id.equal
    (Keeper_lane.id current.lane)
    (Keeper_lane.id expected.lane)
  && current.phase = Keeper_state_machine.Offline
  && Int.equal current.transition_seq expected.transition_seq
;;

module For_testing = struct
  let same_offline_generation = same_offline_generation
end

let supervise_keepalive
      ~(publish_lifecycle :
         event:Keeper_lifecycle_events.lifecycle_event ->
         string -> string -> unit -> unit)
      ~(launch_supervised_fiber :
         intake_token:Keeper_shutdown_intake_fence.intake_token ->
         lifecycle_token:Keeper_lifecycle_reservation.token ->
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
    Keeper_owner_registry.shutdown_operation_id
      ~base_path
      ~keeper_name:meta.name
  in
  let execution_truth =
    match admission with
    | Error error ->
      Keeper_activation_readiness.Unknown
        (Keeper_owner_registry.lookup_error_to_string error)
    | Ok shutdown_operation_id ->
      Keeper_activation_readiness.classify_owner_execution
        ~shutdown_operation_id
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
  let wake_queued_owner_operations () =
    match
      Keeper_owner_registry.wake_operation_drain
        ~base_path
        ~keeper_name:meta.name
    with
    | Ok () -> ()
    | Error error ->
      Log.Keeper.warn
        "supervisor: owner operation drain wake rejected keeper=%s error=%s"
        meta.name
        (Keeper_owner_registry.command_error_to_string error)
  in
  let launch_registered intake_token lifecycle_token reg =
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
    match
      launch_supervised_fiber
        ~intake_token
        ~lifecycle_token
        ~proactive_warmup_sec
        ctx
        meta
        reg
    with
    | Error _ -> ()
    | Ok () ->
      wake_queued_owner_operations ();
      (try
         publish_lifecycle
           ~event:
             (Keeper_lifecycle_events.Custom_event
                { verb = Keeper_lifecycle_events.Started
                ; phase = Some Keeper_state_machine.Running
                })
           meta.name
           "supervised"
           ()
       with
       | exn ->
         (* The lane crossed its start boundary successfully. Observation
            failure must not escape into launch rollback and detach it from
            the registry. *)
         Log.Keeper.error
           "supervisor launch lifecycle publication failed keeper=%s: %s"
           meta.name
           (Printexc.to_string exn))
  in
  let log_transaction_error = function
    | Keeper_keepalive_launch_transaction.Shutdown_reserved operation_id ->
      Log.Keeper.warn
        "supervisor launch skipped %s because shutdown operation %s owns admission"
        meta.name
        (Keeper_shutdown_types.Operation_id.to_string operation_id)
    | Keeper_keepalive_launch_transaction.Intake_token_not_live ->
      Log.Keeper.error
        "supervisor launch rejected an inactive durable-intake token for %s"
        meta.name
    | Keeper_keepalive_launch_transaction.Reservation_unavailable owner ->
      Log.Keeper.info
        "supervisor launch deferred to lifecycle transaction owner keeper=%s owner=%s"
        meta.name
        (Keeper_lifecycle_reservation.snapshot_to_string owner)
    | Keeper_keepalive_launch_transaction.Registration_failed (`Occupied current) ->
      Log.Keeper.info
        "supervisor launch retained concurrently registered lane keeper=%s phase=%s"
        meta.name
        (Keeper_state_machine.phase_to_string current.Keeper_registry.phase)
    | Keeper_keepalive_launch_transaction.Registration_failed (`Registration error) ->
      (match error with
       | Keeper_registry.Registration_shutdown_reserved operation_id ->
         Log.Keeper.warn
           "supervisor launch skipped %s because shutdown operation %s owns admission"
           meta.name
           (Keeper_shutdown_types.Operation_id.to_string operation_id)
       | Keeper_registry.Registration_intake_token_not_live ->
         Log.Keeper.error
           "supervisor launch rejected an unexpected inactive durable-intake token for %s"
           meta.name
       | Keeper_registry.Registration_lifecycle_reserved owner ->
         Log.Keeper.warn
           "supervisor launch skipped %s because lifecycle transaction owns admission: %s"
           meta.name
           (Keeper_lifecycle_reservation.snapshot_to_string owner)
       | Keeper_registry.Registration_invalid validation_error ->
         Log.Keeper.error
           "supervisor registry validation rejected %s: %s"
           meta.name
           (Keeper_registry.registry_entry_validation_error_to_string validation_error)
       | Keeper_registry.Registration_event_queue_unavailable { keeper_name; detail } ->
         Log.Keeper.error
           "supervisor registry event queue unavailable keeper=%s: %s"
           keeper_name
           detail
       | Keeper_registry.Registration_turn_failure_streak_unavailable
           { keeper_name; detail } ->
         Log.Keeper.error
           "supervisor registry turn failure streak unavailable keeper=%s: %s"
           keeper_name
           detail)
    | Keeper_keepalive_launch_transaction.Lifecycle_open_failed
        { error; rollback_error } ->
      Log.Keeper.warn
        "supervisor launch deferred until Librarian owner exits keeper=%s error=%s%s"
        meta.name
        (Keeper_memory_lane.lifecycle_open_error_to_string error)
        (match rollback_error with
         | None -> ""
         | Some detail -> "; rollback failed: " ^ detail);
      ignore
        (Keeper_memory_lane.abort_librarian
           ~base_path
           ~keeper_name:meta.name
          : (Keeper_memory_lane.librarian_abort_outcome,
             Keeper_memory_lane.librarian_abort_error)
              result)
    | Keeper_keepalive_launch_transaction.Launch_failed
        { exception_detail; librarian_abort_error; rollback_error } ->
      let cleanup_detail label = function
        | None -> ""
        | Some detail -> "; " ^ label ^ " failed: " ^ detail
      in
      Log.Keeper.error
        "supervisor launch callback failed keeper=%s error=%s%s%s"
        meta.name
        exception_detail
        (cleanup_detail "Librarian abort" librarian_abort_error)
        (cleanup_detail "registry rollback" rollback_error)
  in
  let run_launch_transaction ~register ~rollback =
    match
      Keeper_keepalive_launch_transaction.run
        ~base_path
        ~keeper_name:meta.name
        ~register
        ~rollback
        launch_registered
    with
    | Ok () -> ()
    | Error error -> log_transaction_error error
  in
  let register_and_launch () =
    run_launch_transaction
      ~register:(fun token intake_token ->
        match Keeper_registry.get ~base_path meta.name with
        | Some current -> Error (`Occupied current)
        | None ->
          Keeper_registry.register_offline_if_admitted_for_lifecycle
            ~intake_token
            token
            ~base_path
            meta.name
            meta
          |> Result.map_error (fun error -> `Registration error))
      ~rollback:Keeper_keepalive_launch_transaction.Remove_registered
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
    (* This is the only durable signal that the supervisor is declining to
       recover a keeper it will keep declining.

       #29467 demoted it to the routine channel as steady-state noise. That
       read the volume without reading what produced it. The two admission
       rules for one keeper disagree: process boot excludes only
       {paused, declarative_autoboot_disabled, autoboot_disabled,
       shutdown_admission_fence} (keeper_runtime.ml), while this recovery path
       classifies through [classify_owner_execution], which is
       [~require_proactive:true] and so refuses any keeper with proactive
       disabled. A keeper boot would happily start therefore cannot be brought
       back by the sweep once it falls Offline — it retries and refuses every
       ~30s until the server restarts.

       That is what the volume was. 25 canary keepers sat Offline from
       2026-08-21 through 2026-08-22T01:30:56Z emitting 14,017 of that day's
       130,102 rows, and the 01:31:12Z restart moved every one of them
       [offline -> running via fiber_started]. Quieting the line would have
       hidden a fleet-wide liveness failure, so it stays at Info until the
       admission asymmetry is closed. See #29487. *)
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
        | Keeper_state_machine.Offline ->
          run_launch_transaction
            ~register:(fun _token _intake_token ->
              match Keeper_registry.get ~base_path meta.name with
              | Some current when same_offline_generation ~expected:reg current ->
                Ok current
              | Some current -> Error (`Occupied current)
              | None -> Error (`Occupied reg))
            ~rollback:Keeper_keepalive_launch_transaction.Retain_registered
        | Keeper_state_machine.Running
        | Keeper_state_machine.Failing
        | Keeper_state_machine.Draining
        | Keeper_state_machine.Paused
        | Keeper_state_machine.Stopped
        | Keeper_state_machine.Crashed
        | Keeper_state_machine.Restarting ->
          Log.Keeper.debug
            "%s: supervisor keepalive retained existing %s owner for lifecycle sweep"
            meta.name
            (Keeper_state_machine.phase_to_string reg.phase)))
;;
