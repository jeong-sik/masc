(** Dead-tombstone cleanup admission and completion delivery.

    The supervisor only submits an exact-lane durable shutdown operation.
    Meta mutation, lane join, registry removal, and accumulator removal are
    owned by [Keeper_shutdown_finalize]. [Dead_cleaned] and
    [Tombstone_reaped] are delivered from the durable completion receipt after
    finalization, never from the sweep that observed the old entry. *)

open Keeper_shutdown_types

let cleanup_intent : Keeper_shutdown_types.cleanup_intent =
  { reason = Dead_tombstone_cleanup
  ; remove_session = false
  }
;;

let record_submission_failure keeper_name =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string SupervisorCleanupFailures)
    ~labels:
      [ "keeper", keeper_name
      ; ( "site"
        , Keeper_supervisor_cleanup_failure_site.(
            to_label Dead_tombstone_submission) )
      ]
    ()
;;

let cleanup_dead_tombstone
    (ctx : _ Keeper_types_profile.context)
    (entry : Keeper_registry.registry_entry)
  =
  let request : Keeper_shutdown_prepare_join.request =
    { actor = ctx.agent_name
    ; cleanup_intent
    }
  in
  match Keeper_shutdown_runtime.submit ~config:ctx.config ~entry ~request with
  | Ok operation ->
    Log.Keeper.info
      "%s: dead tombstone finalization accepted operation=%s"
      entry.name
      (Keeper_shutdown_types.Operation_id.to_string operation.operation_id)
  | Error error ->
    record_submission_failure entry.name;
    Log.Keeper.error
      "%s: dead tombstone finalization submission failed: %s"
      entry.name
      (Keeper_shutdown_runtime.submit_error_to_string error)
;;

let completion_meta_for_coverage config operation =
  match Keeper_meta_store.read_meta config operation.Keeper_shutdown_types.keeper_name with
  | Ok (Some meta)
    when Keeper_id.Trace_id.equal meta.runtime.trace_id operation.trace_id
         && Int.equal meta.runtime.generation operation.generation -> Some meta
  | Ok (Some _) ->
    Log.Keeper.warn
      "%s: dead tombstone completion coverage meta identity changed"
      operation.keeper_name;
    None
  | Ok None ->
    Log.Keeper.warn
      "%s: dead tombstone completion coverage meta is absent"
      operation.keeper_name;
    None
  | Error detail ->
    Log.Keeper.warn
      "%s: dead tombstone completion coverage meta read failed: %s"
      operation.keeper_name
      detail;
    None
;;

let lifecycle_event_bus_ready () =
  match Masc_event_bus.get () with
  | None -> Error "MASC lifecycle event bus is not installed"
  | Some _ -> Ok ()
;;

let dead_tombstone_sinks_ready () =
  match lifecycle_event_bus_ready () with
  | Error _ as error -> error
  | Ok () when not (Keeper_subprocess_registry.default_cleanup_hook_registered ()) ->
    Error "default Keeper subprocess cleanup hook is not registered"
  | Ok () -> Ok ()
;;

let handle_completion config operation = function
  | Keeper_shutdown_types.Dead_tombstone_reaped ->
    (match dead_tombstone_sinks_ready () with
     | Error _ as error -> error
     | Ok () ->
       let operation_id =
         Keeper_shutdown_types.Operation_id.to_string operation.operation_id
       in
       Keeper_supervisor_publish_lifecycle.publish_lifecycle
         ~event:
           (Keeper_lifecycle_events.Custom_event
              { verb = Keeper_lifecycle_events.Dead_cleaned; phase = None })
         operation.keeper_name
         ("shutdown_operation=" ^ operation_id)
         ();
       let meta = completion_meta_for_coverage config operation in
       Keeper_lifecycle_hooks.run
         ~base_dir:(Workspace.masc_root_dir config)
         ?meta
         ~keeper_id:operation.keeper_name
         Keeper_lifecycle_hooks.Tombstone_reaped;
       Log.Keeper.info
         "%s: dead tombstone finalization delivered operation=%s"
         operation.keeper_name
       operation_id;
       Ok ())
  | Keeper_shutdown_types.Dashboard_keeper_purged ->
    Error "dashboard Keeper purge completion requires the server artifact boundary"
;;
