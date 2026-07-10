(** Per-keeper memory execution lane. See keeper_memory_lane.mli (RFC-0257). *)

type entry =
  { state_mu : Stdlib.Mutex.t
    (* Guards the FIFO and worker ownership. Critical sections never yield. *)
  ; jobs : (unit -> unit) Stdlib.Queue.t
  ; mutable pending : int
  ; mutable next_worker_id : int
  ; mutable active_worker_id : int option
  }

type outcome =
  | Submitted
  | Ran_inline
  | Dropped

type abandonment_reason =
  | Executor_switch_unavailable
  | Executor_switch_released
  | Worker_cancelled
  | Worker_failed
  | Hook_registration_failed
  | Fork_failed

let abandonment_reason_label = function
  | Executor_switch_unavailable -> "executor_switch_unavailable"
  | Executor_switch_released -> "executor_switch_released"
  | Worker_cancelled -> "worker_cancelled"
  | Worker_failed -> "worker_failed"
  | Hook_registration_failed -> "hook_registration_failed"
  | Fork_failed -> "fork_failed"
;;

let entries : (string, entry) Hashtbl.t = Hashtbl.create 16

(* Module-level singleton table: Stdlib.Mutex because lookup is reachable
   outside an Eio context (test setup) and the critical section never yields. *)
let registry_mu = Stdlib.Mutex.create ()

(* Set once by [init] at startup, before keepers run. Guarded by [registry_mu]
   so a reader sees the write. *)
let executor_sw : Eio.Switch.t option ref = ref None

let init ~sw =
  Stdlib.Mutex.protect registry_mu (fun () -> executor_sw := Some sw)
;;

let current_sw () = Stdlib.Mutex.protect registry_mu (fun () -> !executor_sw)

let entry_for ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect registry_mu (fun () ->
    match Hashtbl.find_opt entries key with
    | Some entry -> entry
    | None ->
      let entry =
        { state_mu = Stdlib.Mutex.create ()
        ; jobs = Stdlib.Queue.create ()
        ; pending = 0
        ; next_worker_id = 0
        ; active_worker_id = None
        }
      in
      Hashtbl.add entries key entry;
      entry)
;;

let metric_name metric = Keeper_metrics.(to_string metric)

let record_counter ~keeper_name metric =
  Otel_metric_store.inc_counter
    (metric_name metric)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let record_counter_delta ~keeper_name metric count =
  if count > 0
  then
    Otel_metric_store.inc_counter
      (metric_name metric)
      ~labels:[ "keeper", keeper_name ]
      ~delta:(float_of_int count)
      ()
;;

let inc_pending ~keeper_name () =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLanePending)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let dec_pending ~keeper_name () =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLanePending)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let dec_pending_by ~keeper_name count =
  if count > 0
  then
    Otel_metric_store.dec_gauge
      (metric_name MemoryLanePending)
      ~labels:[ "keeper", keeper_name ]
      ~delta:(float_of_int count)
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

let protect_cleanup ~keeper_name label f =
  try f () with
  | exn ->
    record_counter ~keeper_name MemoryLaneUnitFailures;
    Log.Keeper.warn ~keeper_name
      "memory lane cleanup failed (%s): %s"
      label
      (Printexc.to_string exn)
;;

let enqueue ~keeper_name entry job =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    Stdlib.Queue.add job entry.jobs;
    entry.pending <- entry.pending + 1;
    inc_pending ~keeper_name ();
    match entry.active_worker_id with
    | Some _ -> None
    | None ->
      entry.next_worker_id <- entry.next_worker_id + 1;
      let worker_id = entry.next_worker_id in
      entry.active_worker_id <- Some worker_id;
      Some worker_id)
;;

let take_next entry ~worker_id =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.active_worker_id with
    | Some active when active = worker_id ->
      (match Stdlib.Queue.take_opt entry.jobs with
       | Some job -> Some job
       | None ->
         entry.active_worker_id <- None;
         None)
    | Some _ | None -> None)
;;

let release_job ~keeper_name entry =
  let released =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      if entry.pending <= 0
      then false
      else (
        entry.pending <- entry.pending - 1;
        true))
  in
  if released
  then dec_pending ~keeper_name ()
  else (
    record_counter ~keeper_name MemoryLaneUnitFailures;
    Log.Keeper.error ~keeper_name "memory lane pending counter underflow prevented")
;;

let worker_is_active entry ~worker_id =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    entry.active_worker_id = Some worker_id)
;;

let abandon_queued ~keeper_name entry ~worker_id ~reason =
  let abandoned =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      match entry.active_worker_id with
      | Some active when active = worker_id ->
        let count = Stdlib.Queue.length entry.jobs in
        Stdlib.Queue.clear entry.jobs;
        entry.pending <- entry.pending - count;
        entry.active_worker_id <- None;
        count
      | Some _ | None -> 0)
  in
  if abandoned > 0
  then (
    record_counter_delta ~keeper_name MemoryLaneDropped abandoned;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:
        [ "keeper", keeper_name
        ; "site", "memory_lane_abandoned"
        ; "reason", abandonment_reason_label reason
        ]
      ~delta:(float_of_int abandoned)
      ();
    dec_pending_by ~keeper_name abandoned;
    Log.Keeper.warn ~keeper_name
      "memory lane worker abandoned queued units count=%d reason=%s"
      abandoned
      (abandonment_reason_label reason));
  abandoned
;;

let run_job ~keeper_name entry ~sw job =
  inc_in_flight ~keeper_name ();
  Fun.protect
    ~finally:(fun () ->
      protect_cleanup ~keeper_name "dec_in_flight" (fun () ->
        dec_in_flight ~keeper_name ());
      protect_cleanup ~keeper_name "release_job" (fun () ->
        release_job ~keeper_name entry))
    (fun () ->
      try Eio_context.with_turn_switch sw job with
      | Eio.Cancel.Cancelled _ as exn ->
        record_counter ~keeper_name MemoryLaneDropped;
        Log.Keeper.warn ~keeper_name
          "memory lane in-flight unit cancelled before completion";
        raise exn
      | exn ->
        record_counter ~keeper_name MemoryLaneUnitFailures;
        Log.Keeper.warn ~keeper_name
          "memory lane unit failed: %s"
          (Printexc.to_string exn))
;;

let rec drain_worker ~keeper_name entry ~worker_id ~sw =
  match take_next entry ~worker_id with
  | None -> ()
  | Some job ->
    run_job ~keeper_name entry ~sw job;
    drain_worker ~keeper_name entry ~worker_id ~sw
;;

let start_worker ~keeper_name entry ~worker_id sw =
  let release_from_switch () =
    ignore
      (abandon_queued
         ~keeper_name
         entry
         ~worker_id
         ~reason:Executor_switch_released)
  in
  match Eio.Switch.get_error sw with
  | Some _ ->
    ignore
      (abandon_queued
         ~keeper_name
         entry
         ~worker_id
         ~reason:Executor_switch_unavailable);
    false
  | None ->
    let hook =
      try Some (Eio.Switch.on_release_cancellable sw release_from_switch) with
      | exn ->
        ignore
          (abandon_queued
             ~keeper_name
             entry
             ~worker_id
             ~reason:Hook_registration_failed);
        Log.Keeper.warn ~keeper_name
          "memory lane worker release hook registration failed: %s"
          (Printexc.to_string exn);
        None
    in
    (match hook with
     | None -> false
     | Some hook ->
       if not (worker_is_active entry ~worker_id)
       then (
         ignore (Eio.Switch.try_remove_hook hook);
         false)
       else (
         try
           Eio.Fiber.fork ~sw (fun () ->
             Fun.protect
               ~finally:(fun () -> ignore (Eio.Switch.try_remove_hook hook))
               (fun () ->
                 try
                   (* [Fiber.fork] runs the child immediately. Yield once so
                      [submit] returns before deterministic disk work or a
                      provider call begins on the memory worker. *)
                   Eio.Fiber.yield ();
                   drain_worker ~keeper_name entry ~worker_id ~sw
                 with
                 | Eio.Cancel.Cancelled _ as exn ->
                   ignore
                     (abandon_queued
                        ~keeper_name
                        entry
                        ~worker_id
                        ~reason:Worker_cancelled);
                   raise exn
                 | exn ->
                   ignore
                     (abandon_queued
                        ~keeper_name
                        entry
                        ~worker_id
                        ~reason:Worker_failed);
                   record_counter ~keeper_name MemoryLaneUnitFailures;
                   Log.Keeper.error ~keeper_name
                     "memory lane worker failed: %s"
                     (Printexc.to_string exn)));
           true
         with
         | Eio.Cancel.Cancelled _ as exn ->
           ignore (Eio.Switch.try_remove_hook hook);
           ignore
             (abandon_queued
                ~keeper_name
                entry
                ~worker_id
                ~reason:Worker_cancelled);
           raise exn
         | exn ->
           ignore (Eio.Switch.try_remove_hook hook);
           ignore
             (abandon_queued
                ~keeper_name
                entry
                ~worker_id
                ~reason:Fork_failed);
           Log.Keeper.error ~keeper_name
             "memory lane worker fork failed: %s"
             (Printexc.to_string exn);
           false))
;;

let submit ~base_path ~keeper_name job =
  match current_sw () with
  | None ->
    (* Not initialized: run inline. The caller is still inside the per-keeper
       turn lane, so single-fiber-per-keeper memory access is preserved. A
       raising unit is contained and counted rather than escaping. *)
    (try job () with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       record_counter ~keeper_name MemoryLaneUnitFailures;
       Log.Keeper.warn ~keeper_name
         "memory lane unit failed (inline): %s"
         (Printexc.to_string exn));
    record_counter ~keeper_name MemoryLaneRanInline;
    Ran_inline
  | Some sw ->
    let entry = entry_for ~base_path ~keeper_name in
    let worker_id = enqueue ~keeper_name entry job in
    record_counter ~keeper_name MemoryLaneSubmitted;
    (match worker_id with
     | None -> Submitted
     | Some worker_id ->
       if start_worker ~keeper_name entry ~worker_id sw then Submitted else Dropped)
;;

module For_testing = struct
  let reset () =
    Stdlib.Mutex.protect registry_mu (fun () ->
      Hashtbl.reset entries;
      executor_sw := None)
  ;;

  let pending ~base_path ~keeper_name =
    let key = Keeper_registry_types.registry_key ~base_path keeper_name in
    Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key)
    |> Option.map (fun entry ->
      Stdlib.Mutex.protect entry.state_mu (fun () -> entry.pending))
  ;;
end
