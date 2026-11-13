(** Keepalive supervision entry-point, extracted from
    [keeper_supervisor.ml] (godfile decomp).

    [supervise_keepalive] decides whether to spawn a supervised
    keepalive fiber for [meta]. It launches only an owner whose
    execution truth is [Recoverable]: a fresh registration, or a
    registration still in [Offline]. Other registered phases remain
    owned by the lifecycle sweep. A launch:

    1. Registers the lane through [Keeper_keepalive_launch_transaction].
       A refused registration is logged and nothing is spawned.
    2. Lazily initializes the workspace root (Workspace.init).
    3. Calls the injected [~launch_supervised_fiber] to spawn the
       supervised fiber.
    4. Wakes the owner's queued-operation drain and publishes a
       [Started] / [Running]-phase lifecycle event.

    Every other verdict retains the owner and only logs the reason.

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
       (* The lane crossed its start boundary successfully. Observation
          failure must not escape into launch rollback and detach it from
          the registry. A cancellation raised by the publication is such a
          failure: the lane is running either way. *)
       | exn -> (* cancel-guard-ok: the lane already started; escaping here rolls the launch back and detaches a running lane *)
         Log.Keeper.error
           "supervisor launch lifecycle publication failed keeper=%s: %s"
           meta.name
           (Printexc.to_string exn))
  in
  let log_transaction_error = function
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
    | Keeper_keepalive_launch_transaction.Launch_failed
        { exception_detail; rollback_error } ->
      let cleanup_detail label = function
        | None -> ""
        | Some detail -> "; " ^ label ^ " failed: " ^ detail
      in
      Log.Keeper.error
        "supervisor launch callback failed keeper=%s error=%s%s"
        meta.name
        exception_detail
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
  (* [Unknown], [Shutdown_fenced], [Retained_disabled] and [Paused_dead] are
     the owner's standing state, and the sweep reads it again on every pass.
     These branches dispatch and launch nothing, so they count no lifecycle
     dispatch rejection and publish no [Admission_denied]: both mean a launch
     was attempted and refused, as in [Keeper_keepalive.start_keepalive] and
     the sweep's crashed-lane restart. The log line keeps the reason. The
     state itself is read from the registry phase, the persisted meta and the
     runtime health [owner_lifecycle] (#29485). *)
  match execution_truth with
  | Keeper_activation_readiness.Unknown detail ->
    Log.Keeper.error
      "%s: supervisor keepalive recovery retained because owner execution truth is unknown: %s"
      meta.name
      detail
  | Keeper_activation_readiness.Shutdown_fenced operation_id ->
    Log.Keeper.warn
      "%s: supervisor keepalive recovery retained by shutdown operation %s"
      meta.name
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
  | Keeper_activation_readiness.Retained_disabled reason ->
    Log.Keeper.info
      "%s: supervisor keepalive recovery retained by disabled policy: %s"
      meta.name
      (Keeper_activation_readiness.retained_disabled_reason_to_wire reason)
  | Keeper_activation_readiness.Paused_dead reason ->
    Log.Keeper.info
      "%s: supervisor keepalive recovery retained by paused/dead owner truth: %s"
      meta.name
      (Keeper_activation_readiness.paused_dead_reason_to_wire reason)
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
        (* #26323: a registered [Crashed] entry never reaches [launch_registered]
           from here, so this call never dispatches [Fiber_started] against it
           and cannot produce the reported [invalid_transition: crashed ->
           running]. The registry (see [Keeper_registry_setup.registry]) holds
           no entry across a process restart, so [Keeper_registry.get] answers
           [None] for every keeper at boot and this call always takes the
           fresh-registration branch above instead; a [Crashed] entry only
           exists here for a keeper that crashed within this same live
           process, and it is retained for the lifecycle sweep, which recovers
           it through the typed [Crashed -> Restarting -> Running] path
           ([Keeper_state_machine_mermaid], [keeper_supervisor.ml]'s
           [queue_crashed_entry]/[Supervisor_restart_attempt]), never the
           direct transition the matrix does not contain. Regression guard:
           [test_supervise_keepalive_retains_sweep_owned_entries]. *)
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
