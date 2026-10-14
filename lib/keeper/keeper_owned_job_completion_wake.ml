module Store = Keeper_owned_job_store
let ( let* ) = Result.bind

type report =
  { inspected : int; waiting : int; delivered : int; retired : int
  ; failures : (string * Store.error) list }
type outcome = Waiting | Delivered | Retired

let wake_hint (record : Store.record) =
  (* The exact notification is already durable. A wake is only a lifecycle hint. *)
  try
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
      (Store.Job_id.to_string record.job_id) (Printexc.to_string exn)

let deliver ~on_result_ready (record : Store.record) =
  let completion : Keeper_event_queue.owned_job_completion =
    {oj_job_id=record.job_id;oj_source=record.source;oj_channel=record.completion_channel} in
  let stimulus : Keeper_event_queue.stimulus =
    {post_id=Keeper_event_queue.owned_job_completion_post_id completion;
     urgency=Immediate;arrived_at=Time_compat.now ();payload=Owned_job_completed completion} in
  let* () = match Keeper_registry_event_queue.enqueue_stimulus_once_durable_result
      ~base_path:record.base_path record.keeper_name stimulus with
    | Keeper_registry_event_queue.Stimulus_enqueued | Stimulus_already_present -> Ok ()
    | Stimulus_storage_error detail -> Error (Store.Io_failed detail) in
  (* The exact completed output and notification are already durable. The
     continuation observer can schedule its original DAG without a model turn. *)
  (try on_result_ready record with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn -> Log.Keeper.warn ~keeper_name:record.keeper_name
       "owned job result observer failed job_id=%s: %s"
       (Store.Job_id.to_string record.job_id) (Printexc.to_string exn));
  (* Cleanup or producer ACK failure cannot suppress the committed queue's hint. *)
  wake_hint record;
  let* acknowledged = Store.acknowledge_completion record in
  let* () = Store.retire_delivery_marker acknowledged in
  Ok Delivered

let recover ~on_result_ready ~base_path (marker : Store.pending_delivery) =
  try
    let* record = Store.recover ~base_path ~keeper_name:marker.keeper_name marker.job_id in
    if record.completion_delivered then
      let* () = Store.retire_delivery_marker record in Ok Retired
    else if Store.result_ready record then deliver ~on_result_ready record
    else
      let* record = Keeper_owned_job_runtime.reconcile record in
      if Store.result_ready record then deliver ~on_result_ready record else Ok Waiting
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Store.Io_failed (Printexc.to_string exn))

(* One fiber per pending job is capped like the dashboard enrichment pools, so
   a large Waiting set cannot fan out that many backend CLI calls at once. *)
let recovery_max_fibers = 8

let reconcile ~config =
  let base_path = config.Workspace.base_path in
  let* pending = Store.pending_deliveries ~base_path in
  let empty = {inspected=0;waiting=0;delivered=0;retired=0;failures=pending.failures} in
  let one (marker : Store.pending_delivery) = marker.job_id,recover ~on_result_ready:ignore ~base_path marker in
  let outcomes = match Fs_compat.execution_context () with
    | Fs_compat.Non_eio -> List.map one pending.entries
    | Fs_compat.Eio_fiber ->
      Eio.Fiber.List.map ~max_fibers:recovery_max_fibers one pending.entries in
  let report = List.fold_left (fun report (job_id,outcome) ->
    let report = {report with inspected=report.inspected+1} in
    match outcome with
    | Ok Waiting -> {report with waiting=report.waiting+1}
    | Ok Delivered -> {report with delivered=report.delivered+1}
    | Ok Retired -> {report with retired=report.retired+1}
    | Error error -> {report with failures=(Store.Job_id.to_string job_id,error) :: report.failures})
      empty outcomes in
  Ok {report with failures=List.rev report.failures}

module Job_set = Set.Make (struct
  type t = Store.Job_id.t
  let compare left right = String.compare (Store.Job_id.to_string left) (Store.Job_id.to_string right)
end)
type t =
  { config : Workspace.config
  ; on_result_ready : Store.record -> unit
  ; mutable active : Job_set.t }
let create ~config ?(on_result_ready=ignore) () = {config;on_result_ready;active=Job_set.empty}

let pulse ~sw supervisor =
  let base_path = supervisor.config.Workspace.base_path in
  let* pending = Store.pending_deliveries ~base_path in
  List.iter (fun (identity,error) ->
    Log.Server.warn "owned job completion discovery retained job=%s error=%s"
      identity (Store.error_to_string error)) pending.failures;
  List.iter (fun (marker : Store.pending_delivery) ->
    if not (Job_set.mem marker.job_id supervisor.active) then (
      (* Single-domain Eio reservations do not yield. This set suppresses
         duplicate live workers; only the durable journal can authorize effects. *)
      supervisor.active <- Job_set.add marker.job_id supervisor.active;
      try Eio.Fiber.fork ~sw (fun () ->
        Fun.protect
          ~finally:(fun () -> supervisor.active <- Job_set.remove marker.job_id supervisor.active)
          (fun () ->
            match recover ~on_result_ready:supervisor.on_result_ready ~base_path marker with
            | Error error -> Log.Server.warn "owned job completion retained job=%s error=%s"
                (Store.Job_id.to_string marker.job_id) (Store.error_to_string error)
            | Ok Waiting -> ()
            | Ok Delivered | Ok Retired -> Log.Server.info "owned job completion recovered job=%s"
                (Store.Job_id.to_string marker.job_id)))
      with exn ->
        supervisor.active <- Job_set.remove marker.job_id supervisor.active;
        raise exn)) pending.entries;
  Ok ()
