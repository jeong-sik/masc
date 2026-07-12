(** Keepalive supervision entry-point, extracted from
    [keeper_supervisor.ml] (godfile decomp).

    [supervise_keepalive] is the gate that decides whether to spawn a
    supervised keepalive fiber for [meta]. Idempotent on already-
    registered keepers (no-op). On a fresh registration:

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
  if Keeper_registry.is_registered ~base_path:ctx.config.base_path meta.name
  then ()
  else
    match Keeper_registry.spawn_slots_decision () with
    | Error reason ->
      Keeper_registry.record_spawn_slot_denied
        ~keeper_name:meta.name
        ~surface:"supervisor"
        reason;
      publish_lifecycle
        ~event:
          (Keeper_lifecycle_events.Custom_event
             { verb = Keeper_lifecycle_events.Admission_denied
             ; phase = Some Keeper_state_machine.Offline
             })
        meta.name
        (Keeper_registry.spawn_slot_denial_reason_to_detail reason)
        ()
    | Ok () ->
    Startup_helpers.log_persona_drift_if_missing ~base_path:ctx.config.base_path meta;
    (* Register in Keeper_registry — single source of truth. *)
    (match
       Keeper_registry.register_offline_if_admitted
         ~base_path:ctx.config.base_path
         meta.name
         meta
     with
     | Error (Keeper_registry.Registration_shutdown_reserved operation_id) ->
       Log.Keeper.info
         "supervisor launch skipped %s because shutdown operation %s owns admission"
         meta.name
         (Keeper_shutdown_types.Operation_id.to_string operation_id)
     | Error (Keeper_registry.Registration_lifecycle_reserved owner) ->
       Log.Keeper.info
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
     | Ok reg ->
    (* Workspace initialization *)
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
    Keeper_registry.update_meta ~base_path:ctx.config.base_path meta.name live_meta;
    match launch_supervised_fiber ~proactive_warmup_sec ctx live_meta reg with
    | Error _ ->
      (* The launch gate aborted fail-closed (no fiber forked; [done_p]
         resolved through the crash path and Crashed published by the gate).
         Announcing [Started]/[Running] here would report a keeper that is
         not running. *)
      ()
    | Ok () ->
      publish_lifecycle
        ~event:
          (Keeper_lifecycle_events.Custom_event
             { verb = Keeper_lifecycle_events.Started
             ; phase = Some Keeper_state_machine.Running
             })
        meta.name
        "supervised"
        ())
;;
