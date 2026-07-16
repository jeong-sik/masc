(** Per-keeper memory execution lane. See keeper_memory_lane.mli (RFC-0257). *)

type entry =
  { mem_mu : Eio.Mutex.t
    (* Serializes memory work within one keeper; held across a provider round
       trip (seconds), hence the fiber-cooperative Eio.Mutex. Raw lock/unlock,
       not [use_rw]: a raising unit must not poison the lane. *)
  ; state_mu : Stdlib.Mutex.t
    (* Guards [pending]. Critical sections never yield. *)
  ; mutable pending : int
  }

type outcome =
  | Submitted
  | Ran_inline
  | Dropped

type idle_submission =
  | Idle_submitted
  | Idle_already_active
  | Idle_executor_unavailable
  | Idle_fork_failed

type start_result =
  | Start_submitted
  | Start_executor_unavailable
  | Start_fork_failed

type reservation =
  { release_mu : Stdlib.Mutex.t
  ; mutable released : bool
  ; mutable switch_hook : Eio.Switch.hook option
  }

(* Per-keeper reservation bound: 1 in-flight (holding [mem_mu]) plus 1 queued.
   A third concurrent post-turn unit for the same keeper means turns outpace
   extraction; the excess is best-effort and dropped rather than piling up
   fibers. Tunable via environment for fleet-wide capacity experiments. *)
let max_pending () =
  Keeper_memory_bank_env.memory_env_int_logged
    "MASC_KEEPER_MEMORY_LANE_MAX_PENDING"
    ~default:2
  |> max 1
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
    | Some e -> e
    | None ->
      let e =
        { mem_mu = Eio.Mutex.create ()
        ; state_mu = Stdlib.Mutex.create ()
        ; pending = 0
        }
      in
      Hashtbl.add entries key e;
      e)
;;

let metric_name m = Keeper_metrics.(to_string m)

let record_counter ~keeper_name metric =
  Otel_metric_store.inc_counter
    (metric_name metric)
    ~labels:[ "keeper", keeper_name ]
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

let try_reserve ~keeper_name entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    let bound = max_pending () in
    if entry.pending >= bound
    then None
    else (
      entry.pending <- entry.pending + 1;
      inc_pending ~keeper_name ();
      Some bound))
;;

let try_reserve_if_idle ~keeper_name entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    if entry.pending <> 0
    then false
    else (
      entry.pending <- 1;
      inc_pending ~keeper_name ();
      true))
;;

let release_reservation ~keeper_name entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    entry.pending <- entry.pending - 1;
    dec_pending ~keeper_name ())
;;

let make_reservation () =
  { release_mu = Stdlib.Mutex.create (); released = false; switch_hook = None }
;;

let reservation_released reservation =
  Stdlib.Mutex.protect reservation.release_mu (fun () -> reservation.released)
;;

let release_reservation_once ~keeper_name entry reservation =
  let should_release =
    Stdlib.Mutex.protect reservation.release_mu (fun () ->
      if reservation.released
      then false
      else (
        reservation.released <- true;
        true))
  in
  if should_release then release_reservation ~keeper_name entry
;;

let disarm_switch_hook reservation =
  let hook =
    Stdlib.Mutex.protect reservation.release_mu (fun () ->
      let hook = reservation.switch_hook in
      reservation.switch_hook <- None;
      hook)
  in
  Option.iter (fun hook -> ignore (Eio.Switch.try_remove_hook hook)) hook
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

let release_after_run ~keeper_name entry reservation ~acquired ~in_flight =
  if !in_flight
  then protect_cleanup ~keeper_name "dec_in_flight" (fun () -> dec_in_flight ~keeper_name ());
  if !acquired
  then protect_cleanup ~keeper_name "unlock" (fun () -> Eio.Mutex.unlock entry.mem_mu);
  protect_cleanup ~keeper_name "release_reservation" (fun () ->
    release_reservation_once ~keeper_name entry reservation)
;;

let arm_switch_release ~keeper_name entry reservation sw =
  let release_from_switch () =
    protect_cleanup ~keeper_name "executor_switch_release" (fun () ->
      release_reservation_once ~keeper_name entry reservation)
  in
  try
    let hook = Eio.Switch.on_release_cancellable sw release_from_switch in
    Stdlib.Mutex.protect reservation.release_mu (fun () ->
      if reservation.released
      then ignore (Eio.Switch.try_remove_hook hook)
      else reservation.switch_hook <- Some hook)
  with
  | _exn ->
    (* Finished switches can raise while running the release callback; any hook
       registration failure means the executor cannot own this reservation. *)
    release_from_switch ()
;;

(* Runs on a forked fiber owned by the executor switch. Holds [mem_mu] across
   the unit. Releases the mutex (only if acquired) and the reservation on every
   exit, including cancellation at shutdown. No exception escapes: a best-effort
   unit must never propagate into the executor switch — that would cancel the
   fleet. *)
let run_unit ~keeper_name entry reservation f =
  let acquired = ref false in
  let in_flight = ref false in
  Eio.Switch.run (fun cleanup_sw ->
    Eio.Switch.on_release cleanup_sw (fun () ->
      release_after_run ~keeper_name entry reservation ~acquired ~in_flight);
      disarm_switch_hook reservation;
      try
        Eio.Mutex.lock entry.mem_mu;
        (* No suspension point between [lock] returning and this assignment, so
           cancellation cannot strand a held mutex with [acquired = false]. *)
        acquired := true;
        inc_in_flight ~keeper_name ();
        in_flight := true;
        Eio_context.with_turn_switch cleanup_sw (fun () -> f cleanup_sw)
      with
      | Eio.Cancel.Cancelled _ -> () (* shutdown: silent, cleanup runs above *)
      | exn ->
        record_counter ~keeper_name MemoryLaneUnitFailures;
        Log.Keeper.warn ~keeper_name
          "memory lane unit failed: %s"
          (Printexc.to_string exn))
;;

let start_reserved ~keeper_name entry sw f =
  let reservation = make_reservation () in
  arm_switch_release ~keeper_name entry reservation sw;
  if reservation_released reservation
  then (
    record_counter ~keeper_name MemoryLaneDropped;
    Log.Keeper.warn ~keeper_name
      "memory lane executor switch unavailable: dropping memory unit";
    Start_executor_unavailable)
  else
    try
      record_counter ~keeper_name MemoryLaneSubmitted;
      Eio.Fiber.fork ~sw (fun () -> run_unit ~keeper_name entry reservation f);
      Start_submitted
    with
    | Eio.Cancel.Cancelled _ as e ->
      protect_cleanup ~keeper_name "fork_cancel_release" (fun () ->
        release_reservation_once ~keeper_name entry reservation);
      raise e
    | exn ->
      protect_cleanup ~keeper_name "fork_failure_release" (fun () ->
        release_reservation_once ~keeper_name entry reservation);
      record_counter ~keeper_name MemoryLaneUnitFailures;
      Log.Keeper.warn ~keeper_name
        "memory lane fork failed: %s"
        (Printexc.to_string exn);
      Start_fork_failed
;;

let submit ~base_path ~keeper_name f =
  match current_sw () with
  | None ->
    (* Not initialized: run inline. The caller is still inside the per-keeper
       turn lane, so single-fiber-per-keeper memory access is preserved. A
       raising unit is contained and counted rather than escaping. *)
    (try f () with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       record_counter ~keeper_name MemoryLaneUnitFailures;
       Log.Keeper.warn ~keeper_name
         "memory lane unit failed (inline): %s"
         (Printexc.to_string exn));
    record_counter ~keeper_name MemoryLaneRanInline;
    Ran_inline
  | Some sw ->
    let entry = entry_for ~base_path ~keeper_name in
    (match try_reserve ~keeper_name entry with
     | None ->
       record_counter ~keeper_name MemoryLaneDropped;
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string DispatchEventFailures)
         ~labels:[ "keeper", keeper_name; "site", "memory_lane_saturated" ]
         ();
       Log.Keeper.warn ~keeper_name
         "memory lane saturated (pending>=%d): dropping post-turn memory unit"
         (max_pending ());
       Dropped
     | Some _bound ->
       (match start_reserved ~keeper_name entry sw (fun _ -> f ()) with
        | Start_submitted -> Submitted
        | Start_executor_unavailable | Start_fork_failed -> Dropped))
;;

let submit_if_idle ~base_path ~keeper_name f =
  match current_sw () with
  | None -> Idle_executor_unavailable
  | Some sw ->
    let entry = entry_for ~base_path ~keeper_name in
    if not (try_reserve_if_idle ~keeper_name entry)
    then Idle_already_active
    else
      match start_reserved ~keeper_name entry sw f with
      | Start_submitted -> Idle_submitted
      | Start_executor_unavailable -> Idle_executor_unavailable
      | Start_fork_failed -> Idle_fork_failed
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
    |> Option.map (fun e -> Stdlib.Mutex.protect e.state_mu (fun () -> e.pending))
  ;;
end
