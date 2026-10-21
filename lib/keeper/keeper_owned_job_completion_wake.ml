module Store = Keeper_owned_job_store
let ( let* ) = Result.bind

type report =
  { inspected : int; waiting : int; delivered : int; retired : int
  ; failures : (string * Store.error) list }
type outcome = Waiting of Keeper_owned_job_runtime.held_absent option | Delivered | Retired

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
  let* _ = Store.acknowledge_completion record in
  (* Result delivery ends before cleanup I/O. Retain this discovery marker:
     a later maintenance fiber settles the same acknowledged terminal owner. *)
  Ok Delivered

let recover ?presence_round ?held_absent ~on_result_ready ~base_path (marker : Store.pending_delivery) =
  try
    let* record = Store.recover ~base_path ~keeper_name:marker.keeper_name marker.job_id in
    if record.completion_delivered then
      let* record = Keeper_owned_job_runtime.cleanup record in
      let* () = Store.retire_delivery_marker record in Ok Retired
    else if Store.result_ready record then deliver ~on_result_ready record
    else
      let* (record, held_absent) = Keeper_owned_job_runtime.reconcile_for_recovery
          ?presence_round ?previous:held_absent record in
      if Store.result_ready record then deliver ~on_result_ready record else Ok (Waiting held_absent)
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
    | Ok (Waiting _) -> {report with waiting=report.waiting+1}
    | Ok Delivered -> {report with delivered=report.delivered+1}
    | Ok Retired -> {report with retired=report.retired+1}
    | Error error -> {report with failures=(Store.Job_id.to_string job_id,error) :: report.failures})
      empty outcomes in
  Ok {report with failures=List.rev report.failures}

module Job_key = struct
  type t = Store.Job_id.t
  let compare left right = String.compare (Store.Job_id.to_string left) (Store.Job_id.to_string right)
end
module Job_set = Set.Make (Job_key)
module Job_map = Map.Make (Job_key)

let log_discovery ~base_path = function
  | Ok () -> ()
  | Error error -> Log.Server.warn "owned job completion discovery unavailable: %s base_path=%S"
      (Store.error_to_string error) base_path

type t =
  { config : Workspace.config
  ; on_result_ready : Store.record -> unit
  ; on_discovery : base_path:string -> (unit, Store.error) result -> unit
  ; mutable active : Job_set.t
  ; mutable held_absent : Keeper_owned_job_runtime.held_absent Job_map.t
  ; mutable discovery_active : bool }
let create ~config ?(on_result_ready=ignore) ?(on_discovery=log_discovery) () =
  {config;on_result_ready;on_discovery;active=Job_set.empty;held_absent=Job_map.empty;
   discovery_active=false}

let discover_and_schedule ~sw supervisor =
  Eio.Switch.check sw;
  let base_path = supervisor.config.Workspace.base_path in
  let presence_round = Keeper_owned_job_backend.create_presence_round () in
  let on_entry (marker : Store.pending_delivery) =
    if not (Job_set.mem marker.job_id supervisor.active) then (
      Eio.Switch.check sw;
      (* Single-domain Eio reservations do not yield. This set suppresses
         duplicate live workers; only the durable journal can authorize effects. *)
      supervisor.active <- Job_set.add marker.job_id supervisor.active;
      let held_absent = Job_map.find_opt marker.job_id supervisor.held_absent in
      supervisor.held_absent <- Job_map.remove marker.job_id supervisor.held_absent;
      try Eio.Fiber.fork ~sw (fun () ->
        Fun.protect
          ~finally:(fun () -> supervisor.active <- Job_set.remove marker.job_id supervisor.active)
          (fun () ->
            (* Fork may enter the child first. Let discovery continue before
               recovery I/O; cancellation here still releases this reservation. *)
            Eio.Fiber.yield ();
            match recover ~presence_round ?held_absent ~on_result_ready:supervisor.on_result_ready ~base_path marker with
            | Error error -> Log.Server.warn "owned job completion retained job=%s error=%s base_path=%S"
                (Store.Job_id.to_string marker.job_id) (Store.error_to_string error) base_path
            | Ok (Waiting None) -> ()
            | Ok (Waiting (Some held)) ->
                supervisor.held_absent <- Job_map.add marker.job_id held supervisor.held_absent
            | Ok Delivered | Ok Retired -> Log.Server.info "owned job completion recovered job=%s base_path=%S"
                (Store.Job_id.to_string marker.job_id) base_path))
      with exn ->
        supervisor.active <- Job_set.remove marker.job_id supervisor.active;
        raise exn) in
  let* pending = Store.discover_pending_deliveries ~base_path ~on_entry in
  let pending_ids = List.fold_left (fun ids (marker : Store.pending_delivery) ->
      Job_set.add marker.job_id ids) Job_set.empty pending.entries in
  supervisor.held_absent <- Job_map.filter (fun job_id _ -> Job_set.mem job_id pending_ids)
      supervisor.held_absent;
  List.iter (fun (identity,error) ->
    Log.Server.warn "owned job completion discovery retained job=%s error=%s base_path=%S"
      identity (Store.error_to_string error) base_path) pending.failures;
  Ok ()

type discovery_phase =
  | Discovery_reserved | Discovery_started
  | Discovery_settled of (unit, Store.error) result
  | Discovery_interrupted | Discovery_raised

let observe_discovery ~base_path ~reserved_ns phase =
  let emit () = try Log.Server.routine_lazy (fun () ->
      let phase, detail = match phase with
        | Discovery_reserved -> "reserved", ""
        | Discovery_started -> "started", ""
        | Discovery_settled result -> "settled",
            (match result with Ok () -> " outcome=returned" | Error _ -> " outcome=failed")
        | Discovery_interrupted -> "interrupted", ""
        | Discovery_raised -> "raised", "" in
      Printf.sprintf "owned_job_completion_discovery reserved_ns=%Ld phase=%s at_ns=%Ld%s base_path=%S"
        reserved_ns phase (Mtime_clock.elapsed_ns ()) detail base_path)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  Eio.Cancel.protect emit

let pulse ~sw supervisor =
  Eio.Switch.check sw;
  if not supervisor.discovery_active then (
    let base_path = supervisor.config.Workspace.base_path in
    let reserved_ns = Mtime_clock.elapsed_ns () in
    let observe = observe_discovery ~base_path ~reserved_ns in
    supervisor.discovery_active <- true;
    let release () = supervisor.discovery_active <- false in
    try
      observe Discovery_reserved;
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect ~finally:release (fun () ->
          try
            Eio.Fiber.yield ();
            observe Discovery_started;
            let result = discover_and_schedule ~sw supervisor in
            observe (Discovery_settled result);
            (try supervisor.on_discovery ~base_path result with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> Log.Server.warn "owned job completion discovery observer failed: %s base_path=%S"
                 (Printexc.to_string exn) base_path)
          with
          | Eio.Cancel.Cancelled _ as exn -> observe Discovery_interrupted; raise exn
          | exn ->
              observe Discovery_raised;
              Log.Server.warn "owned job completion discovery worker retained: %s base_path=%S"
                (Printexc.to_string exn) base_path))
    with exn ->
      let bt = Printexc.get_raw_backtrace () in
      release ();
      Printexc.raise_with_backtrace exn bt)
