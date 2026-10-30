module P = Lane_addon_companion_publication
open Result.Syntax
type error = Publication_failed of P.error | Queue_unconfirmed
let error_to_string = function
  | Publication_failed error -> P.error_to_string error
  | Queue_unconfirmed -> "original companion queue admission is unconfirmed"
let deliver ~fs ~config ~origin ~output_schema ~event =
  let* record=P.retain ~fs ~config ~origin ~output_schema ~event |> Result.map_error (fun error -> Publication_failed error) in
  let payload=P.queue_payload record in
  let source=record.origin.Lane_addon_companion_origin.source in
  let stimulus=Keeper_event_queue.{post_id=addon_operation_change_post_id payload;
    urgency=Immediate;arrived_at=Time_compat.now ();payload=Addon_operation_changed payload} in
  let* ()=match Keeper_registry_event_queue.enqueue_stimulus_once_durable_result
      ~base_path:record.origin.base_path source.keeper_name stimulus with
    | Keeper_registry_event_queue.Stimulus_enqueued | Stimulus_already_present -> Ok ()
    | Stimulus_storage_error _ -> Error Queue_unconfirmed in
  (* Durable source admission precedes this optional lifecycle hint. *)
  (try
     match Keeper_registry.wakeup_running ~intent:Keeper_registry.Reactive_signal
         ~base_path:record.origin.base_path source.keeper_name with
     | Keeper_registry.Signaled | Deferred_unregistered | Deferred_not_running _ | Deferred_lifecycle _ -> ()
   with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | _ -> Log.Keeper.warn ~keeper_name:source.keeper_name "companion publication wake hint unavailable");
  Ok ()
