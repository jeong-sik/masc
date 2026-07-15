(** Per-keeper memory execution lane. See keeper_memory_lane.mli (RFC-0257). *)

type work_item = unit -> unit

type entry =
  { queue : work_item Queue.t
  ; state_mu : Stdlib.Mutex.t
    (* Guards [queue], [pending], and [worker_active]. Critical sections never
       yield. *)
  ; mutable pending : int
  ; mutable worker_active : bool
  }

type admission_error =
  | Executor_not_initialized
  | Executor_domain_mismatch
  | Executor_stopping
  | Worker_start_failed of exn

type executor =
  { sw : Eio.Switch.t
  ; owner_domain : Domain.id
  }

exception Worker_did_not_start

let admission_error_code = function
  | Executor_not_initialized -> "executor_not_initialized"
  | Executor_domain_mismatch -> "executor_domain_mismatch"
  | Executor_stopping -> "executor_stopping"
  | Worker_start_failed _ -> "worker_start_failed"
;;

let admission_error_to_string = function
  | Executor_not_initialized -> "memory lane executor is not initialized"
  | Executor_domain_mismatch -> "memory lane submission came from a non-owner domain"
  | Executor_stopping -> "memory lane executor is cancelling or finished"
  | Worker_start_failed exn ->
    Printf.sprintf "memory lane worker failed to start: %s" (Printexc.to_string exn)
;;

let entries : (string, entry) Hashtbl.t = Hashtbl.create 16

(* Module-level singleton table: Stdlib.Mutex because lookup is reachable
   outside an Eio context (test setup) and the critical section never yields. *)
let registry_mu = Stdlib.Mutex.create ()

(* Set once by [init] at startup, before keepers run. Guarded by [registry_mu]
   so a reader sees the write. The owner domain is part of the executor
   capability: Eio switches may only be used from their creating domain. *)
let executor : executor option ref = ref None

let init ~sw =
  Stdlib.Mutex.protect registry_mu (fun () ->
    executor := Some { sw; owner_domain = Domain.self () })
;;

let current_executor () = Stdlib.Mutex.protect registry_mu (fun () -> !executor)

let entry_for ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect registry_mu (fun () ->
    match Hashtbl.find_opt entries key with
    | Some entry -> entry
    | None ->
      let entry =
        { queue = Queue.create ()
        ; state_mu = Stdlib.Mutex.create ()
        ; pending = 0
        ; worker_active = false
        }
      in
      Hashtbl.add entries key entry;
      entry)
;;

let metric_name metric = Keeper_metrics.(to_string metric)

let record_counter ?(delta = 1.0) ~keeper_name metric =
  Otel_metric_store.inc_counter
    (metric_name metric)
    ~labels:[ "keeper", keeper_name ]
    ~delta
    ()
;;

let record_rejection ~keeper_name error =
  Otel_metric_store.inc_counter
    (metric_name MemoryLaneAdmissionRejected)
    ~labels:[ "keeper", keeper_name; "reason", admission_error_code error ]
    ()
;;

let inc_pending ~keeper_name () =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLanePending)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let dec_pending ?(delta = 1.0) ~keeper_name () =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLanePending)
    ~labels:[ "keeper", keeper_name ]
    ~delta
    ()
;;

let inc_in_flight ~keeper_name () =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLaneInFlight)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let dec_in_flight ~keeper_name () =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLaneInFlight)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let admit ~keeper_name entry work =
  let action =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      entry.pending <- entry.pending + 1;
      if entry.worker_active
      then (
        Queue.push work entry.queue;
        `Enqueued)
      else (
        entry.worker_active <- true;
        `Start_worker))
  in
  inc_pending ~keeper_name ();
  action
;;

let rollback_worker_start ~keeper_name entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    entry.worker_active <- false;
    entry.pending <- entry.pending - 1);
  dec_pending ~keeper_name ()
;;

let finish_one ~keeper_name entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    entry.pending <- entry.pending - 1);
  dec_pending ~keeper_name ()
;;

let take_next entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match Queue.take_opt entry.queue with
    | Some work -> Some work
    | None ->
      entry.worker_active <- false;
      None)
;;

let cancel_queued ~keeper_name entry =
  let cancelled =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      let count = Queue.length entry.queue in
      Queue.clear entry.queue;
      entry.pending <- entry.pending - count;
      entry.worker_active <- false;
      count)
  in
  if cancelled > 0
  then (
    dec_pending ~keeper_name ~delta:(Float.of_int cancelled) ();
    record_counter
      ~keeper_name
      ~delta:(Float.of_int cancelled)
      MemoryLaneCancelledUnits);
  cancelled
;;

type run_result =
  | Continue
  | Cancelled

let run_one ~keeper_name entry sw work =
  inc_in_flight ~keeper_name ();
  Fun.protect
    ~finally:(fun () ->
      dec_in_flight ~keeper_name ();
      finish_one ~keeper_name entry)
    (fun () ->
      try
        Eio_context.with_turn_switch sw work;
        Continue
      with
      | Eio.Cancel.Cancelled _ as exn ->
        if Eio.Fiber.is_cancelled ()
        then (
          record_counter ~keeper_name MemoryLaneCancelledUnits;
          Cancelled)
        else (
          (* A promise may carry [Cancelled] while this worker's own context is
             still live. Treat that as a unit failure, not executor shutdown;
             otherwise one foreign result could discard the rest of the FIFO. *)
          record_counter ~keeper_name MemoryLaneUnitFailures;
          Log.Keeper.warn ~keeper_name
            "memory lane unit returned a foreign cancellation: %s"
            (Printexc.to_string exn);
          Continue)
      | exn ->
        record_counter ~keeper_name MemoryLaneUnitFailures;
        Log.Keeper.warn ~keeper_name
          "memory lane unit failed: %s"
          (Printexc.to_string exn);
        Continue)
;;

let rec worker_loop ~keeper_name entry sw work =
  match run_one ~keeper_name entry sw work with
  | Cancelled ->
    let queued = cancel_queued ~keeper_name entry in
    Log.Keeper.warn ~keeper_name
      "memory lane executor cancelled: current unit cancelled, queued_units=%d"
      queued
  | Continue -> (
    match Eio.Switch.get_error sw with
    | Some _ ->
      let queued = cancel_queued ~keeper_name entry in
      Log.Keeper.warn ~keeper_name
        "memory lane executor stopped after current unit: queued_units_cancelled=%d"
        queued
    | None -> (
      match take_next entry with
      | None -> ()
      | Some next -> worker_loop ~keeper_name entry sw next))
;;

let cancel_before_first ~keeper_name entry =
  record_counter ~keeper_name MemoryLaneCancelledUnits;
  finish_one ~keeper_name entry;
  let queued = cancel_queued ~keeper_name entry in
  Log.Keeper.warn ~keeper_name
    "memory lane executor cancelled before worker dispatch: cancelled_units=%d"
    (queued + 1)
;;

let run_worker ~keeper_name entry sw first =
  try
    Eio.Fiber.yield ();
    (try worker_loop ~keeper_name entry sw first with
     | exn ->
       let queued = cancel_queued ~keeper_name entry in
       record_counter ~keeper_name MemoryLaneUnitFailures;
       Log.Keeper.error ~keeper_name
         "memory lane worker failed: queued_units_cancelled=%d error=%s"
         queued
         (Printexc.to_string exn))
  with
  | Eio.Cancel.Cancelled _ -> cancel_before_first ~keeper_name entry
  | exn ->
    finish_one ~keeper_name entry;
    let queued = cancel_queued ~keeper_name entry in
    record_counter ~keeper_name MemoryLaneUnitFailures;
    Log.Keeper.error ~keeper_name
      "memory lane worker dispatch failed: queued_units_cancelled=%d error=%s"
      queued
      (Printexc.to_string exn)
;;

let start_worker ~keeper_name entry sw first =
  let started, set_started = Eio.Promise.create () in
  match
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve set_started ();
      run_worker ~keeper_name entry sw first)
  with
  | () -> (
    match Eio.Promise.peek started with
    | Some () -> Ok ()
    | None ->
      let error = Worker_start_failed Worker_did_not_start in
      rollback_worker_start ~keeper_name entry;
      Error error)
  | exception exn ->
    rollback_worker_start ~keeper_name entry;
    Error (Worker_start_failed exn)
;;

let reject ~keeper_name error =
  record_rejection ~keeper_name error;
  Error error
;;

let submit ~base_path ~keeper_name work =
  match current_executor () with
  | None -> reject ~keeper_name Executor_not_initialized
  | Some { sw; owner_domain } ->
    if Domain.self () <> owner_domain
    then reject ~keeper_name Executor_domain_mismatch
    else (
      match Eio.Switch.get_error sw with
      | Some _ -> reject ~keeper_name Executor_stopping
      | None ->
        let entry = entry_for ~base_path ~keeper_name in
        (match admit ~keeper_name entry work with
         | `Enqueued ->
           record_counter ~keeper_name MemoryLaneSubmitted;
           Ok ()
         | `Start_worker -> (
           match start_worker ~keeper_name entry sw work with
           | Ok () ->
             record_counter ~keeper_name MemoryLaneSubmitted;
             Ok ()
           | Error error -> reject ~keeper_name error)))
;;

module For_testing = struct
  let reset () =
    Stdlib.Mutex.protect registry_mu (fun () ->
      Hashtbl.reset entries;
      executor := None)
  ;;

  let find_entry ~base_path ~keeper_name =
    let key = Keeper_registry_types.registry_key ~base_path keeper_name in
    Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key)
  ;;

  let pending ~base_path ~keeper_name =
    find_entry ~base_path ~keeper_name
    |> Option.map (fun entry ->
      Stdlib.Mutex.protect entry.state_mu (fun () -> entry.pending))
  ;;

  let queued ~base_path ~keeper_name =
    find_entry ~base_path ~keeper_name
    |> Option.map (fun entry ->
      Stdlib.Mutex.protect entry.state_mu (fun () -> Queue.length entry.queue))
  ;;

  let active_workers ~base_path ~keeper_name =
    find_entry ~base_path ~keeper_name
    |> Option.map (fun entry ->
      Stdlib.Mutex.protect entry.state_mu (fun () ->
        if entry.worker_active then 1 else 0))
  ;;
end
