open Keeper_msg_async_types
open Keeper_msg_async_state

type request_ops =
  { save_json_durable :
      ownership_root:string
      -> temp_dir:string
      -> string
      -> Yojson.Safe.t
      -> (unit, Keeper_fs.durable_write_error) result
  ; remove_file_durable :
      ownership_root:string
      -> string
      -> (unit, Keeper_fs.durable_remove_error) result
  ; generate_request_id : unit -> string
  ; before_integrity_projection : unit -> unit
  ; signal_cancel : Eio.Switch.t -> exn -> unit
  }

let production_request_ops =
  { save_json_durable =
      (fun ~ownership_root ~temp_dir path json ->
         Keeper_fs.save_json_durable_atomic
           ~ownership_root
           ~temp_dir
           path
           json)
  ; remove_file_durable =
      (fun ~ownership_root path ->
         Keeper_fs.remove_file_durable ~ownership_root path)
  ; generate_request_id =
      (fun () -> Random_id.prefixed ~prefix:"kmsg-" ~bytes:16)
  ; before_integrity_projection = (fun () -> ())
  ; signal_cancel = Eio.Switch.fail
  }

let with_store_transition_lock ~base_path ~request_id f =
  let key : Store_transition_key.t = { base_path; request_id } in
  let lock =
    Eio.Mutex.use_rw ~protect:true mu (fun () ->
      match Store_transition_table.find_opt store_transition_locks key with
      | Some lock ->
        lock.users <- lock.users + 1;
        lock
      | None ->
        let lock = { mutex = Eio.Mutex.create (); users = 1 } in
        Store_transition_table.add store_transition_locks key lock;
        lock)
  in
  (* fun-protect-finally-ok: the user-count decrement runs under
     [Eio.Cancel.protect], so it completes even when [f] raised because this
     fiber is being cancelled. [Eio.Mutex.use_rw ~protect:true] is not enough on
     its own: Eio documents [protect] as covering the critical section, not the
     wait for the lock, so a contended [mu] would abort the cleanup and leave
     [lock.users] above zero — the entry keyed by request id would then never be
     removed from [store_transition_locks]. [with_keeper_lane_lock] below already
     protects its cleanup the same way. *)
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () ->
        Eio.Mutex.use_rw ~protect:true mu (fun () ->
          lock.users <- lock.users - 1;
          if lock.users = 0
          then
            match Store_transition_table.find_opt store_transition_locks key with
            | Some current when current == lock ->
              Store_transition_table.remove store_transition_locks key
            | Some _ | None -> ())))
    (fun () -> Eio.Mutex.use_rw ~protect:true lock.mutex f)
;;

type lane_observation =
  | Unobserved_lane
  | Persistence_lane

type 'a lane_lock_outcome =
  | Lane_lock_returned of 'a
  | Lane_lock_raised of exn * Printexc.raw_backtrace

let persistence_lane_waits_metric =
  Keeper_metrics.(to_string PersistenceLaneWaits)
;;

let persistence_lane_pending_metric =
  Keeper_metrics.(to_string PersistenceLanePending)
;;

let persistence_lane_in_flight_metric =
  Keeper_metrics.(to_string PersistenceLaneInFlight)
;;

let persistence_lane_duration_metric =
  Keeper_metrics.(to_string PersistenceLaneDuration)
;;

let persistence_lane_waits = Atomic.make_contended 0
let persistence_lane_pending = Atomic.make_contended 0
let persistence_lane_in_flight = Atomic.make_contended 0

let persistence_lane_samples () =
  [ { Otel_metrics.name = persistence_lane_waits_metric
      ; value = Float.of_int (Atomic.get persistence_lane_waits)
      ; labels = []
      ; kind = Otel_metrics.Counter
      }
    ; { Otel_metrics.name = persistence_lane_pending_metric
      ; value = Float.of_int (Atomic.get persistence_lane_pending)
      ; labels = []
      ; kind = Otel_metrics.Gauge
      }
    ; { Otel_metrics.name = persistence_lane_in_flight_metric
      ; value = Float.of_int (Atomic.get persistence_lane_in_flight)
      ; labels = []
      ; kind = Otel_metrics.Gauge
      }
  ]
;;

let () = Otel_metrics.register_source persistence_lane_samples
;;

let elapsed_seconds started =
  Mtime.Span.to_float_ns (Mtime.span started (Mtime_clock.now ())) /. 1e9
;;

(** Raised when a bounded lane admission expires (or cannot be bounded because
    no ambient monotonic clock is installed). Only the submit path passes a
    budget, so only it can raise this; status-settlement acquisitions are
    unbounded and never see it. *)
exception Lane_admission_timeout of string

let try_acquire_gate (gate : lane_gate) =
  Stdlib.Mutex.protect gate.gate_mu (fun () ->
    if not gate.held then (
      gate.held <- true;
      true)
    else false)
;;

let release_gate (gate : lane_gate) =
  let rec next_live_waiter () =
    match Queue.take_opt gate.waiters with
    | None -> None
    | Some waiter ->
      if waiter.cancelled then next_live_waiter ()
      else (
        waiter.granted <- true;
        Some waiter.wake)
  in
  let wake =
    Stdlib.Mutex.protect gate.gate_mu (fun () ->
      match next_live_waiter () with
      | Some wake -> Some wake
      | None ->
        gate.held <- false;
        None)
  in
  Option.iter (fun wake -> Eio.Promise.resolve wake ()) wake
;;

let acquire_gate ~on_wait (gate : lane_gate) =
  let action =
    Stdlib.Mutex.protect gate.gate_mu (fun () ->
      if not gate.held then (
        gate.held <- true;
        `Acquired)
      else (
        let promise, wake = Eio.Promise.create () in
        let waiter = { granted = false; cancelled = false; wake } in
        Queue.add waiter gate.waiters;
        `Wait (waiter, promise)))
  in
  match action with
  | `Acquired -> ()
  | `Wait (waiter, promise) ->
    let abort_wait () =
      let must_release =
        Stdlib.Mutex.protect gate.gate_mu (fun () ->
          if waiter.granted then true
          else (
            waiter.cancelled <- true;
            false))
      in
      if must_release then release_gate gate
    in
    (try
       on_wait ();
       Eio.Promise.await promise
     with
     | Eio.Cancel.Cancelled _ as exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       abort_wait ();
       Printexc.raise_with_backtrace exn backtrace
     | exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       abort_wait ();
       Printexc.raise_with_backtrace exn backtrace)
;;

let with_lane_gate ~on_wait ~wait_budget ~lane_label (gate : lane_gate) f =
  let acquired =
    match wait_budget with
    | None ->
      (* Unbounded (settlement path): a committed write must always be able
         to settle, so [acquire_gate] waits FIFO as long as it takes. *)
      acquire_gate ~on_wait gate;
      true
    | Some budget_sec ->
      if try_acquire_gate gate then true
      else (
        match Eio_context.get_mono_clock_opt () with
        | None ->
          (* No ambient monotonic clock (pre-boot): a contended wait cannot
             be bounded honestly, so refuse immediately without inflating wait
             counters. *)
          false
        | Some clock ->
          if budget_sec <= 0.0 then false
          else (
            match
              Eio.Time.Timeout.run
                (Eio.Time.Timeout.seconds clock budget_sec)
                (fun () ->
                   acquire_gate ~on_wait gate;
                   Ok ())
            with
            | Ok () -> true
            | Error `Timeout -> false))
  in
  if not acquired then raise (Lane_admission_timeout lane_label);
  (* A started durable systhread cannot be cancelled. Keep the lane held until
     its transaction and gate release finish. Deliberately do not re-check the
     parent cancellation here: the caller must first settle the committed
     receipt/status, matching [Keeper_event_queue_owner_lock.with_durable_lock]. *)
  (* fun-protect-finally-ok: [release_gate] uses only a non-suspending
     [Stdlib.Mutex] and [Eio.Promise.resolve] for the gate acquired above. *)
  Fun.protect
    ~finally:(fun () -> release_gate gate)
    (fun () -> Eio.Cancel.protect f)
;;

let with_keeper_lane_lock observation table ~lane_label ?wait_budget ~base_path ~keeper_name f =
  let key : Keeper_lane_key.t = { base_path; keeper_name } in
  let lock =
    Eio.Mutex.use_rw ~protect:true mu (fun () ->
      match Keeper_lane_table.find_opt table key with
      | Some lock ->
        lock.users <- lock.users + 1;
        lock
      | None ->
        let lock =
          { gate_mu = Stdlib.Mutex.create ()
          ; held = false
          ; waiters = Queue.create ()
          ; users = 1
          }
        in
        Keeper_lane_table.add table key lock;
        lock)
  in
  let pending_observed = ref false in
  let on_wait () =
    match observation with
    | Unobserved_lane -> ()
    | Persistence_lane ->
      pending_observed := true;
      let (_ : int) = Atomic.fetch_and_add persistence_lane_waits 1 in
      let (_ : int) = Atomic.fetch_and_add persistence_lane_pending 1 in
      ()
  in
  let leave_pending () =
    if !pending_observed
    then (
      pending_observed := false;
      let (_ : int) = Atomic.fetch_and_add persistence_lane_pending (-1) in
      ())
  in
  let run () =
    match
      with_lane_gate ~on_wait ~wait_budget ~lane_label lock (fun () ->
        leave_pending ();
        match observation with
        | Unobserved_lane -> `Unobserved (f ())
        | Persistence_lane ->
          let started = Mtime_clock.now () in
          let (_ : int) = Atomic.fetch_and_add persistence_lane_in_flight 1 in
          let outcome =
            match f () with
            | value -> Lane_lock_returned value
            | exception exn -> (* cancel-guard-ok: PROVISIONAL, delete with #37372. The exception is stashed as Lane_lock_raised and thrown again at line 563 once the lane in-flight counter is decremented. *)
              Lane_lock_raised (exn, Printexc.get_raw_backtrace ())
          in
          `Persistence (outcome, elapsed_seconds started))
    with
    | `Unobserved value -> value
    | `Persistence (outcome, elapsed) ->
      (* Keep blocking metrics-store work outside the per-Keeper persistence
         gate. The transaction outcome and elapsed time were captured while
         holding the gate, and [with_lane_gate] has released it before this
         point. Do not re-check parent cancellation here: a committed result
      must reach its caller before cancellation propagates. *)
      Eio.Cancel.protect (fun () ->
        let (_ : int) = Atomic.fetch_and_add persistence_lane_in_flight (-1) in
        Otel_metric_store.observe_histogram persistence_lane_duration_metric elapsed);
      (match outcome with
       | Lane_lock_returned value -> value
       | Lane_lock_raised (exn, backtrace) ->
         Printexc.raise_with_backtrace exn backtrace)
  in
  (* fun-protect-finally-ok: the registry user-count cleanup acquires only the
     cancellation-protected bookkeeping mutex; it awaits no external event and
     cannot strand the protected exception behind cancellable cleanup. *)
  Fun.protect
    ~finally:(fun () ->
      leave_pending ();
      Eio.Cancel.protect (fun () ->
        Eio.Mutex.use_rw ~protect:true mu (fun () ->
          lock.users <- lock.users - 1;
          if lock.users = 0
          then
            match Keeper_lane_table.find_opt table key with
            | Some current when current == lock ->
              Keeper_lane_table.remove table key
            | Some _ | None -> ())))
    run
;;

let with_keeper_submission_lock ?wait_budget ~base_path ~keeper_name f =
  with_keeper_lane_lock
    Unobserved_lane
    keeper_submission_locks
    ~lane_label:"submission"
    ?wait_budget
    ~base_path
    ~keeper_name
    f
;;

let with_keeper_persistence_lock ?wait_budget ~base_path ~keeper_name f =
  with_keeper_lane_lock
    Persistence_lane
    keeper_persistence_locks
    ~lane_label:"persistence"
    ?wait_budget
    ~base_path
    ~keeper_name
    f
;;

exception CancelledByOperator
exception Worker_preempted of string
exception Worker_already_settled of entry
let server_background_switch () =
  match Eio_context.get_root_switch_opt () with
  | Some sw -> Ok sw
  | None ->
    Error
      (Background_switch_unavailable
         { reason = "keeper_msg requires the server root switch (unavailable)" })
;;
