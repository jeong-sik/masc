(** Cleanup completion delivery.

    Meta mutation, lane join, registry removal, and accumulator removal are
    owned by [Keeper_shutdown_finalize]. The [Supervisor_cleaned] lifecycle
    event and hook are delivered from the durable completion receipt after
    finalization, never from the sweep that observed the old entry. *)

open Keeper_shutdown_types

let completion_meta_for_coverage config operation =
  match Keeper_meta_store.read_meta config operation.Keeper_shutdown_types.keeper_name with
  | Ok (Some meta)
    when Keeper_id.Trace_id.equal meta.runtime.trace_id operation.trace_id ->
    Some meta
  | Ok (Some _) ->
    Log.Keeper.warn
      "%s: supervisor cleanup completion coverage meta identity changed"
      operation.keeper_name;
    None
  | Ok None ->
    Log.Keeper.warn
      "%s: supervisor cleanup completion coverage meta is absent"
      operation.keeper_name;
    None
  | Error detail ->
    Log.Keeper.warn
      "%s: supervisor cleanup completion coverage meta read failed: %s"
      operation.keeper_name
      detail;
    None
;;

let lifecycle_event_bus_ready () =
  match Event_bus_slots.get_masc () with
  | None -> Error "MASC lifecycle event bus is not installed"
  | Some _ -> Ok ()
;;

let cleanup_sinks_ready () =
  match lifecycle_event_bus_ready () with
  | Error _ as error -> error
  | Ok () when not (Keeper_subprocess_registry.default_cleanup_hook_registered ()) ->
    Error "default Keeper subprocess cleanup hook is not registered"
  | Ok () -> Ok ()
;;

let handle_completion config operation = function
  | Keeper_shutdown_types.Supervisor_cleaned ->
    (match cleanup_sinks_ready () with
     | Error _ as error -> error
     | Ok () ->
       let operation_id =
         Keeper_shutdown_types.Operation_id.to_string operation.operation_id
       in
       Keeper_supervisor_publish_lifecycle.publish_lifecycle
         ~event:
           (Keeper_lifecycle_events.Custom_event
              { verb = Keeper_lifecycle_events.Supervisor_cleaned; phase = None })
         operation.keeper_name
         ("shutdown_operation=" ^ operation_id)
         ();
       let meta = completion_meta_for_coverage config operation in
       Keeper_lifecycle_hooks.run
         ~base_dir:(Workspace.masc_root_dir config)
         ?meta
         ~keeper_id:operation.keeper_name
         Keeper_lifecycle_hooks.Supervisor_cleaned;
       Log.Keeper.info
         "%s: supervisor cleanup finalization delivered operation=%s"
         operation.keeper_name
       operation_id;
       Ok ())
  | Keeper_shutdown_types.Dashboard_keeper_purged ->
    Error "dashboard Keeper purge completion requires the server artifact boundary"
;;
