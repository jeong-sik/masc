module Store = Keeper_owned_job_store
let ( let* ) = Result.bind

type report =
  { inspected : int; waiting : int; delivered : int; retired : int
  ; failures : (string * Store.error) list }
type outcome = Waiting | Delivered | Retired

let deliver (record : Store.record) =
  let completion : Keeper_event_queue.owned_job_completion =
    {oj_job_id=record.job_id;oj_source=record.source;oj_channel=record.completion_channel} in
  let stimulus : Keeper_event_queue.stimulus =
    {post_id=Keeper_event_queue.owned_job_completion_post_id completion;
     urgency=Immediate;arrived_at=Time_compat.now ();
     payload=Owned_job_completed completion} in
  let* () = match Keeper_registry_event_queue.enqueue_stimulus_once_durable_result
      ~base_path:record.base_path record.keeper_name stimulus with
    | Keeper_registry_event_queue.Stimulus_enqueued
    | Stimulus_already_present -> Ok ()
    | Stimulus_storage_error detail -> Error (Store.Io_failed detail) in
  let* acknowledged = Store.acknowledge_completion record in
  let* () = Store.retire_delivery_marker acknowledged in
  (* Wake is a hint after the durable enqueue and canonical acknowledgement.
     Lifecycle refusal leaves the queue for the next admitted turn. *)
  (try
     match Keeper_registry.wakeup_running ~intent:Keeper_registry.Reactive_signal
         ~base_path:record.base_path record.keeper_name with
     | Keeper_registry.Signaled -> ()
     | Deferred_unregistered | Deferred_not_running _ | Deferred_lifecycle _ ->
         Log.Keeper.info ~keeper_name:record.keeper_name
           "owned job completion wake deferred job_id=%s" (Store.Job_id.to_string record.job_id)
   with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn -> Log.Keeper.warn ~keeper_name:record.keeper_name
       "owned job completion wake hint failed job_id=%s: %s"
       (Store.Job_id.to_string record.job_id) (Printexc.to_string exn));
  Ok Delivered

let reconcile ~config =
  let base_path = config.Workspace.base_path in
  let* pending = Store.pending_deliveries ~base_path in
  let empty = {inspected=0;waiting=0;delivered=0;retired=0;failures=pending.failures} in
  let recover (marker : Store.pending_delivery) =
    let outcome =
      try
        let* record = Store.load ~base_path ~keeper_name:marker.keeper_name marker.job_id in
        if record.completion_delivered then
          let* () = Store.retire_delivery_marker record in Ok Retired
        else if Store.result_ready record then deliver record
        else
          let* record = Keeper_owned_job_runtime.reconcile record in
          if Store.result_ready record then deliver record else Ok Waiting
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Store.Io_failed (Printexc.to_string exn)) in
    marker.job_id,outcome in
  (* Original jobs own separate backend handles and journals. Their recovery
     I/O can progress independently; report assembly remains pure and ordered. *)
  let outcomes = match Fs_compat.execution_context () with
    | Fs_compat.Non_eio -> List.map recover pending.entries
    | Fs_compat.Eio_fiber -> Eio.Fiber.List.map recover pending.entries in
  let report = List.fold_left (fun report (job_id,outcome) ->
    let report = {report with inspected=report.inspected+1} in
    match outcome with
    | Ok Waiting -> {report with waiting=report.waiting+1}
    | Ok Delivered -> {report with delivered=report.delivered+1}
    | Ok Retired -> {report with retired=report.retired+1}
    | Error error -> {report with failures=(Store.Job_id.to_string job_id,error) :: report.failures})
      empty outcomes in
  Ok {report with failures=List.rev report.failures}
