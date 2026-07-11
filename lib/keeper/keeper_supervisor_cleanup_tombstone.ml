(** Dead-tombstone cleanup for the keeper supervisor, extracted from
    [keeper_supervisor.ml]. The cleanup CASes [paused = true] (merging
    heartbeat-owned fields), unregisters the keeper, drops its tool
    emission accumulator, and emits the [Dead_cleaned] lifecycle event.

    [publish_lifecycle] is injected explicitly so the sibling does not
    reach back into the supervisor godfile (mirrors the pattern already
    used by [Keeper_supervisor_self_preservation.apply]). *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_execution

let cleanup_dead_tombstone
      ~publish_lifecycle
      (ctx : _ context)
      (entry : Keeper_registry.registry_entry)
  =
  match read_meta ctx.config entry.name with
  | Ok (Some meta) ->
    let dead_tombstone_terminal_persisted =
      meta.paused
      &&
      match meta.latched_reason with
      | Some Keeper_latched_reason.Dead_tombstone ->
        Option.is_none meta.auto_resume_after_sec
        && Option.is_none meta.runtime.last_blocker
      | Some _
      | None -> false
    in
    let persisted_paused =
      if dead_tombstone_terminal_persisted
      then true
      else (
        (* #9733: dead tombstone cleanup writes [paused = true] —
             cycle-owned field — while heartbeat fibers can still
             update the same record's heartbeat-owned fields.  Use
             the same merged-CAS retry as the resume + overflow-pause
             paths so a parallel heartbeat write doesn't make this
             write fail and leave the keeper unpaused on disk while
             the supervisor proceeds to unregister it.

             The cleanup owns [paused]/[latched_reason] here, so use
             [dead_tombstone_cleanup_from_disk] rather than the
             heartbeat merge: on a CAS retry that re-reads an operator
             pause, the heartbeat merge would copy the operator reason
             back over [Dead_tombstone] and still return [Ok ()]. *)
        match
          write_meta_with_merge_result
            ~merge:Keeper_meta_merge.dead_tombstone_cleanup_from_disk
            ctx.config
            { meta with
              paused = true
            ; (* Record {i why} this meta is paused on disk: a dead-keeper
                 tombstone, distinct from an operator pause or runtime latch.
                 Observability only — the unregister/pause behavior below is
                 unchanged. *)
              latched_reason = Some Keeper_latched_reason.Dead_tombstone
            ; auto_resume_after_sec = None
            ; updated_at = now_iso ()
            ; runtime = { meta.runtime with last_blocker = None }
            }
        with
        | Ok () -> true
        | Error (Version_conflict _ as error) ->
          let err = write_error_to_string error in
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string WriteMetaFailures)
            ~labels:[ "keeper", entry.name; "phase", "dead_cleanup_cas_race" ]
            ();
          Log.Keeper.warn
            "%s: dead tombstone cleanup paused/reason write lost CAS race after retries: %s"
            entry.name
            err;
          false
        | Error (Storage_error err) ->
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string WriteMetaFailures)
            ~labels:[ "keeper", entry.name; "phase", "dead_cleanup" ]
            ();
          Log.Keeper.warn
            "%s: dead tombstone cleanup paused/reason write failed: %s"
            entry.name
            err;
          false)
    in
    Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
    Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
    if persisted_paused
    then (
      publish_lifecycle
        ~event:
          (Keeper_lifecycle_events.Custom_event
             { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
        entry.name
        "paused meta persisted"
        ();
      Log.Keeper.info "%s: dead tombstone cleaned up" entry.name)
    else (
      publish_lifecycle
        ~event:
          (Keeper_lifecycle_events.Custom_event
             { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
        entry.name
        "meta write failed, unregistered anyway"
        ();
      Log.Keeper.warn
        "%s: dead tombstone unregistered despite meta write failure"
        entry.name;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string SupervisorCleanupFailures)
        ~labels:
          [ "keeper", entry.name
          ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Dead_tombstone_meta_write))
          ]
        ())
  | Ok None ->
    Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
    Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
    publish_lifecycle
      ~event:
        (Keeper_lifecycle_events.Custom_event
           { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
      entry.name
      "meta missing"
      ();
    Log.Keeper.warn "%s: dead tombstone unregistered (meta missing)" entry.name;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SupervisorCleanupFailures)
      ~labels:
        [ "keeper", entry.name
        ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Dead_tombstone_meta_missing))
        ]
      ()
  | Error err ->
    Keeper_registry.unregister ~base_path:ctx.config.base_path entry.name;
    Keeper_tool_emission_hook.drop_keeper_accumulator entry.name;
    publish_lifecycle
      ~event:
        (Keeper_lifecycle_events.Custom_event
           { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
      entry.name
      (Printf.sprintf "meta read error: %s" err)
      ();
    Log.Keeper.warn "%s: dead tombstone unregistered (meta error: %s)" entry.name err;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SupervisorCleanupFailures)
      ~labels:
        [ "keeper", entry.name
        ; ("site", Keeper_supervisor_cleanup_failure_site.(to_label Dead_tombstone_meta_error))
        ]
      ()
;;
