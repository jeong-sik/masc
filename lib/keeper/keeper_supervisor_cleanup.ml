(** Cleanup completion delivery.

    Meta mutation, lane join, and registry removal are owned by
    [Keeper_shutdown_finalize]. The [Supervisor_cleaned] lifecycle
    event is delivered from the durable completion receipt after
    finalization, never from the sweep that observed the old entry. *)

open Keeper_shutdown_types

let lifecycle_event_bus_ready () =
  match Event_bus_slots.get_masc () with
  | None -> Error "MASC lifecycle event bus is not installed"
  | Some _ -> Ok ()
;;

let handle_completion _config operation = function
  | Keeper_shutdown_types.Supervisor_cleaned ->
    (match lifecycle_event_bus_ready () with
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
       Log.Keeper.info
         "%s: supervisor cleanup finalization delivered operation=%s"
         operation.keeper_name
       operation_id;
       Ok ())
  | Keeper_shutdown_types.Dashboard_keeper_purged ->
    Error "dashboard Keeper purge completion requires the server artifact boundary"
;;
