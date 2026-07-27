(** Per-keeper memory execution lane. See keeper_memory_lane.mli (RFC-0257). *)

(* Post-turn memory work splits into two kinds that write different stores
   under their own locks ([Keeper_memory_bank.with_memory_bank_lock] vs
   [Keeper_memory_os_io.with_facts_lock] / [with_episode_bundle_lock]), so they
   never needed to serialize against each other. Sharing one lane made them
   compete for one reservation budget anyway, and the librarian holds its
   mutex across a provider round trip (seconds) while the deterministic write
   is a local append. A turn submits one of each, so a librarian still in
   flight from the previous turn left room for only one of them — and the
   deterministic write is one-shot with no retry, while the librarian unit is
   re-tried by its own cadence. Measured live on 2026-07-20: 220 drops against
   375 librarian writes, keeper `analyst` at 144 drops / 136 writes, 52 of
   those turns losing both units.

   Each kind therefore gets its own entry: its own mutex (so a provider round
   trip cannot block a local append) and its own reservation budget (so neither
   kind can evict the other). Serialization *within* a kind is preserved. *)
type lane =
  | Deterministic
  | Librarian

let lane_label = function
  | Deterministic -> "deterministic"
  | Librarian -> "librarian"
;;

type librarian_drain =
  { mutable latest : (unit -> unit) option
  ; mutable in_flight : bool
  ; mutable switch_hook : Eio.Switch.hook option
  }

type entry =
  { mem_mu : Eio.Mutex.t
    (* Serializes deterministic work. Librarian work has one drain fiber, so its
       [librarian_drain] state is the serialization boundary. *)
  ; state_mu : Stdlib.Mutex.t
    (* Guards [pending] and [librarian_drain]. Critical sections never yield. *)
  ; mutable pending : int
  ; mutable librarian_drain : librarian_drain option
  }

type outcome =
  | Submitted
  | Coalesced
  | Ran_inline
  | Dropped

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

let entry_for ~base_path ~keeper_name ~lane =
  let key =
    Keeper_registry_types.registry_key ~base_path keeper_name ^ "#" ^ lane_label lane
  in
  Stdlib.Mutex.protect registry_mu (fun () ->
    match Hashtbl.find_opt entries key with
    | Some e -> e
    | None ->
      let e =
        { mem_mu = Eio.Mutex.create ()
        ; state_mu = Stdlib.Mutex.create ()
        ; pending = 0
        ; librarian_drain = None
        }
      in
      Hashtbl.add entries key e;
      e)
;;

let metric_name m = Keeper_metrics.(to_string m)

let record_counter ~keeper_name ~lane metric =
  Otel_metric_store.inc_counter
    (metric_name metric)
    ~labels:[ "keeper", keeper_name; "lane", lane_label lane ]
    ()
;;

let inc_pending ~keeper_name ~lane () =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLanePending)
    ~labels:[ "keeper", keeper_name; "lane", lane_label lane ]
    ()
;;

let dec_pending ~keeper_name ~lane () =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLanePending)
    ~labels:[ "keeper", keeper_name; "lane", lane_label lane ]
    ()
;;

let inc_in_flight ~keeper_name ~lane () =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLaneInFlight)
    ~labels:[ "keeper", keeper_name; "lane", lane_label lane ]
    ()
;;

let dec_in_flight ~keeper_name ~lane () =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLaneInFlight)
    ~labels:[ "keeper", keeper_name; "lane", lane_label lane ]
    ()
;;

let inc_latest_pending ~keeper_name ~lane () =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLaneLatestPending)
    ~labels:[ "keeper", keeper_name; "lane", lane_label lane ]
    ()
;;

let dec_latest_pending ~keeper_name ~lane () =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLaneLatestPending)
    ~labels:[ "keeper", keeper_name; "lane", lane_label lane ]
    ()
;;

let try_reserve ~keeper_name ~lane entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    let bound = max_pending () in
    if entry.pending >= bound
    then None
    else (
      entry.pending <- entry.pending + 1;
      inc_pending ~keeper_name ~lane ();
      Some bound))
;;

let release_reservation ~keeper_name ~lane entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    entry.pending <- entry.pending - 1;
    dec_pending ~keeper_name ~lane ())
;;

let make_reservation () =
  { release_mu = Stdlib.Mutex.create (); released = false; switch_hook = None }
;;

let reservation_released reservation =
  Stdlib.Mutex.protect reservation.release_mu (fun () -> reservation.released)
;;

let release_reservation_once ~keeper_name ~lane entry reservation =
  let should_release =
    Stdlib.Mutex.protect reservation.release_mu (fun () ->
      if reservation.released
      then false
      else (
        reservation.released <- true;
        true))
  in
  if should_release then release_reservation ~keeper_name ~lane entry
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

let protect_cleanup ~keeper_name ~lane label f =
  try f () with
  | exn ->
    record_counter ~keeper_name ~lane MemoryLaneUnitFailures;
    Log.Keeper.warn ~keeper_name
      "memory lane cleanup failed (%s): %s"
      label
      (Printexc.to_string exn)
;;

let release_after_run ~keeper_name ~lane entry reservation ~acquired ~in_flight =
  if !in_flight
  then
    protect_cleanup ~keeper_name ~lane "dec_in_flight" (fun () ->
      dec_in_flight ~keeper_name ~lane ());
  if !acquired
  then
    protect_cleanup ~keeper_name ~lane "unlock" (fun () -> Eio.Mutex.unlock entry.mem_mu);
  protect_cleanup ~keeper_name ~lane "release_reservation" (fun () ->
    release_reservation_once ~keeper_name ~lane entry reservation)
;;

let arm_switch_release ~keeper_name ~lane entry reservation sw =
  let release_from_switch () =
    protect_cleanup ~keeper_name ~lane "executor_switch_release" (fun () ->
      release_reservation_once ~keeper_name ~lane entry reservation)
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
let run_unit ~keeper_name ~lane entry reservation sw f =
  let acquired = ref false in
  let in_flight = ref false in
  Eio.Switch.run (fun cleanup_sw ->
    Eio.Switch.on_release cleanup_sw (fun () ->
      release_after_run ~keeper_name ~lane entry reservation ~acquired ~in_flight);
      disarm_switch_hook reservation;
      try
        Eio.Mutex.lock entry.mem_mu;
        (* No suspension point between [lock] returning and this assignment, so
           cancellation cannot strand a held mutex with [acquired = false]. *)
        acquired := true;
        inc_in_flight ~keeper_name ~lane ();
        in_flight := true;
        Eio_context.with_turn_switch sw f
      with
      | Eio.Cancel.Cancelled _ -> () (* shutdown: silent, cleanup runs above *)
      | exn ->
        record_counter ~keeper_name ~lane MemoryLaneUnitFailures;
        Log.Keeper.warn ~keeper_name
          "memory lane unit failed: %s"
          (Printexc.to_string exn))
;;

type librarian_submission =
  | Start_drain of librarian_drain
  | Queue_latest
  | Replace_latest

type librarian_drain_step =
  | Drain_stopped
  | Drain_done of Eio.Switch.hook option
  | Drain_next of (unit -> unit)

let librarian_reserve entry f =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.librarian_drain with
    | None ->
      let drain = { latest = None; in_flight = false; switch_hook = None } in
      entry.librarian_drain <- Some drain;
      entry.pending <- 1;
      Start_drain drain
    | Some drain ->
      (match drain.latest with
       | None ->
         drain.latest <- Some f;
         entry.pending <- entry.pending + 1;
         Queue_latest
       | Some _ ->
         drain.latest <- Some f;
         Replace_latest))
;;

let librarian_drain_is_active entry drain =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.librarian_drain with
    | Some current -> current == drain
    | None -> false)
;;

let emit_librarian_cleanup ~keeper_name ~pending ~in_flight ~latest_pending =
  for _ = 1 to pending do
    protect_cleanup ~keeper_name ~lane:Librarian "dec_pending" (fun () ->
      dec_pending ~keeper_name ~lane:Librarian ())
  done;
  if in_flight
  then
    protect_cleanup ~keeper_name ~lane:Librarian "dec_in_flight" (fun () ->
      dec_in_flight ~keeper_name ~lane:Librarian ());
  if latest_pending
  then
    protect_cleanup ~keeper_name ~lane:Librarian "dec_latest_pending" (fun () ->
      dec_latest_pending ~keeper_name ~lane:Librarian ())
;;

let detach_librarian_drain entry drain =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.librarian_drain with
    | Some current when current == drain ->
      let pending = entry.pending in
      let in_flight = drain.in_flight in
      let latest_pending = Option.is_some drain.latest in
      let hook = drain.switch_hook in
      entry.pending <- 0;
      entry.librarian_drain <- None;
      drain.latest <- None;
      drain.in_flight <- false;
      drain.switch_hook <- None;
      Some (pending, in_flight, latest_pending, hook)
    | Some _ | None -> None)
;;

let cleanup_librarian_drain ~keeper_name ~remove_hook entry drain =
  match detach_librarian_drain entry drain with
  | None -> ()
  | Some (pending, in_flight, latest_pending, hook) ->
    emit_librarian_cleanup ~keeper_name ~pending ~in_flight ~latest_pending;
    if remove_hook
    then Option.iter (fun h -> ignore (Eio.Switch.try_remove_hook h)) hook
;;

let arm_librarian_switch_release ~keeper_name entry drain sw =
  let release_from_switch () =
    protect_cleanup ~keeper_name ~lane:Librarian
      "librarian_executor_switch_release"
      (fun () ->
        cleanup_librarian_drain ~keeper_name ~remove_hook:false entry drain)
  in
  try
    let hook = Eio.Switch.on_release_cancellable sw release_from_switch in
    let retained =
      Stdlib.Mutex.protect entry.state_mu (fun () ->
        match entry.librarian_drain with
        | Some current when current == drain ->
          drain.switch_hook <- Some hook;
          true
        | Some _ | None -> false)
    in
    if not retained then ignore (Eio.Switch.try_remove_hook hook)
  with
  | _exn ->
    (* A finished switch may run the callback and raise while registering it.
       Cleanup is idempotent for this exact drain identity. *)
    release_from_switch ()
;;

let librarian_begin_current ~keeper_name entry drain =
  let started =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      match entry.librarian_drain with
      | Some current when current == drain ->
        drain.in_flight <- true;
        true
      | Some _ | None -> false)
  in
  if started then inc_in_flight ~keeper_name ~lane:Librarian ();
  started
;;

let librarian_finish_current ~keeper_name entry drain =
  let in_flight, took_latest, step =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      match entry.librarian_drain with
      | Some current when current == drain ->
        let in_flight = drain.in_flight in
        drain.in_flight <- false;
        entry.pending <- entry.pending - 1;
        (match drain.latest with
         | Some next ->
           drain.latest <- None;
           in_flight, true, Drain_next next
         | None ->
           let hook = drain.switch_hook in
           drain.switch_hook <- None;
           entry.librarian_drain <- None;
           in_flight, false, Drain_done hook)
      | Some _ | None -> false, false, Drain_stopped)
  in
  if in_flight
  then dec_in_flight ~keeper_name ~lane:Librarian ();
  (match step with
   | Drain_stopped -> ()
   | Drain_done _ | Drain_next _ ->
     dec_pending ~keeper_name ~lane:Librarian ());
  if took_latest then dec_latest_pending ~keeper_name ~lane:Librarian ();
  step
;;

let rec run_librarian_drain ~keeper_name entry drain sw current =
  if librarian_begin_current ~keeper_name entry drain
  then (
    let cancelled =
      try
        Eio_context.with_turn_switch sw current;
        false
      with
      | Eio.Cancel.Cancelled _ -> true
      | exn ->
        record_counter ~keeper_name ~lane:Librarian MemoryLaneUnitFailures;
        Log.Keeper.warn ~keeper_name
          "memory lane unit failed: %s"
          (Printexc.to_string exn);
        false
    in
    if cancelled
    then cleanup_librarian_drain ~keeper_name ~remove_hook:true entry drain
    else (
      match librarian_finish_current ~keeper_name entry drain with
      | Drain_stopped -> ()
      | Drain_done hook ->
        Option.iter (fun h -> ignore (Eio.Switch.try_remove_hook h)) hook
      | Drain_next latest ->
        run_librarian_drain ~keeper_name entry drain sw latest))
;;

let submit_librarian ~keeper_name entry sw f =
  match librarian_reserve entry f with
  | Queue_latest ->
    inc_pending ~keeper_name ~lane:Librarian ();
    inc_latest_pending ~keeper_name ~lane:Librarian ();
    record_counter ~keeper_name ~lane:Librarian MemoryLaneSubmitted;
    Submitted
  | Replace_latest ->
    record_counter ~keeper_name ~lane:Librarian MemoryLaneCoalesced;
    Log.Keeper.warn ~keeper_name
      "memory lane coalesced latest snapshot (lane=librarian pending=2): replacing \
       superseded post-turn memory unit";
    Coalesced
  | Start_drain drain ->
    inc_pending ~keeper_name ~lane:Librarian ();
    record_counter ~keeper_name ~lane:Librarian MemoryLaneSubmitted;
    arm_librarian_switch_release ~keeper_name entry drain sw;
    if not (librarian_drain_is_active entry drain)
    then (
      record_counter ~keeper_name ~lane:Librarian MemoryLaneDropped;
      Log.Keeper.warn ~keeper_name
        "memory lane executor switch unavailable (lane=librarian): dropping post-turn \
         memory unit";
      Dropped)
    else (
      try
        Eio.Fiber.fork ~sw (fun () ->
          run_librarian_drain ~keeper_name entry drain sw f);
        Submitted
      with
      | Eio.Cancel.Cancelled _ as e ->
        cleanup_librarian_drain ~keeper_name ~remove_hook:true entry drain;
        raise e
      | exn ->
        cleanup_librarian_drain ~keeper_name ~remove_hook:true entry drain;
        record_counter ~keeper_name ~lane:Librarian MemoryLaneUnitFailures;
        Log.Keeper.warn ~keeper_name
          "memory lane fork failed: %s"
          (Printexc.to_string exn);
        Dropped)
;;

let submit_bounded ~keeper_name ~lane entry sw f =
  match try_reserve ~keeper_name ~lane entry with
  | None ->
    record_counter ~keeper_name ~lane MemoryLaneDropped;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:
        [ "keeper", keeper_name
        ; "site", "memory_lane_saturated"
        ; "lane", lane_label lane
        ]
      ();
    Log.Keeper.warn ~keeper_name
      "memory lane saturated (lane=%s pending>=%d): dropping post-turn memory unit"
      (lane_label lane)
      (max_pending ());
    Dropped
  | Some _bound ->
    let reservation = make_reservation () in
    arm_switch_release ~keeper_name ~lane entry reservation sw;
    if reservation_released reservation
    then (
      record_counter ~keeper_name ~lane MemoryLaneDropped;
      Log.Keeper.warn ~keeper_name
        "memory lane executor switch unavailable (lane=%s): dropping post-turn memory unit"
        (lane_label lane);
      Dropped)
    else (
      try
        record_counter ~keeper_name ~lane MemoryLaneSubmitted;
        Eio.Fiber.fork ~sw (fun () ->
          run_unit ~keeper_name ~lane entry reservation sw f);
        Submitted
      with
      | Eio.Cancel.Cancelled _ as e ->
        protect_cleanup ~keeper_name ~lane "fork_cancel_release" (fun () ->
          release_reservation_once ~keeper_name ~lane entry reservation);
        raise e
      | exn ->
        protect_cleanup ~keeper_name ~lane "fork_failure_release" (fun () ->
          release_reservation_once ~keeper_name ~lane entry reservation);
        record_counter ~keeper_name ~lane MemoryLaneUnitFailures;
        Log.Keeper.warn ~keeper_name
          "memory lane fork failed: %s"
          (Printexc.to_string exn);
        Dropped)
;;

let submit ~base_path ~keeper_name ~lane f =
  match current_sw () with
  | None ->
    (* Not initialized: run inline. The caller is still inside the per-keeper
       turn lane, so single-fiber-per-keeper memory access is preserved. A
       raising unit is contained and counted rather than escaping. *)
    (try f () with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       record_counter ~keeper_name ~lane MemoryLaneUnitFailures;
       Log.Keeper.warn ~keeper_name
         "memory lane unit failed (inline): %s"
         (Printexc.to_string exn));
    record_counter ~keeper_name ~lane MemoryLaneRanInline;
    Ran_inline
  | Some sw ->
    let entry = entry_for ~base_path ~keeper_name ~lane in
    (match lane with
     | Librarian -> submit_librarian ~keeper_name entry sw f
     | Deterministic -> submit_bounded ~keeper_name ~lane entry sw f)
;;

module For_testing = struct
  let reset () =
    Stdlib.Mutex.protect registry_mu (fun () ->
      Hashtbl.reset entries;
      executor_sw := None)
  ;;

  let pending ~base_path ~keeper_name ~lane =
    let key =
      Keeper_registry_types.registry_key ~base_path keeper_name ^ "#" ^ lane_label lane
    in
    Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key)
    |> Option.map (fun e -> Stdlib.Mutex.protect e.state_mu (fun () -> e.pending))
  ;;
end
