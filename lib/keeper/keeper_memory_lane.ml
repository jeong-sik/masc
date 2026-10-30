(** Per-keeper Librarian execution lane. See keeper_memory_lane.mli (RFC-0257). *)

let lane_label = "librarian"
open Result.Syntax

type librarian_drain =
  { mutable latest : (unit -> unit) option
  ; mutable in_flight : bool
  ; mutable switch_hook : Eio.Switch.hook option
  ; owner_lane : Keeper_lane.t
  }

(* An attached drain owns its current unit even before it starts. Its latest
   slot is the only other unit that can be pending. *)
let pending_in_drain drain =
  1 + (if Option.is_some drain.latest then 1 else 0)
;;

type external_effect = {
  identity : unit ref;
  context : Eio.Cancel.t;
  owner_domain : Domain.id;
  exited : unit Eio.Promise.t;
  resolve_exit : unit Eio.Promise.u;
}

type entry =
  { state_mu : Stdlib.Mutex.t
    (* Guards the drain, purge fence and active external
       cancellation scopes. Critical sections never yield. *)
  ; mutable librarian_drain : librarian_drain option
  ; mutable last_owner_lane : Keeper_lane.t option
    (* The lane of the most recent drain, kept after [librarian_drain] is
       cleared because that lane may still be in its cleanup. A Keeper purge
       waits on it ([cancel_and_await_librarian]). *)
  ; mutable external_effects : external_effect list
  ; mutable purge_owner : unit ref option
  }

type outcome =
  | Submitted
  | Coalesced
  | Ran_inline
  | Dropped

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

let entry_key ~base_path ~keeper_name =
  Keeper_registry_types.registry_key ~base_path keeper_name ^ "#" ^ lane_label
;;

let make_entry () =
  { state_mu = Stdlib.Mutex.create ()
  ; librarian_drain = None
  ; last_owner_lane = None
  ; external_effects = []
  ; purge_owner = None
  }
;;

let entry_for ~base_path ~keeper_name =
  let key = entry_key ~base_path ~keeper_name in
  Stdlib.Mutex.protect registry_mu (fun () ->
    match Hashtbl.find_opt entries key with
    | Some e -> e
    | None ->
      let e = make_entry () in
      Hashtbl.add entries key e;
      e)
;;

let metric_name m = Keeper_metrics.(to_string m)

let record_counter ~keeper_name metric =
  Otel_metric_store.inc_counter
    (metric_name metric)
    ~labels:[ "keeper", keeper_name; "lane", lane_label ]
    ()
;;

let inc_pending ~keeper_name () =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLanePending)
    ~labels:[ "keeper", keeper_name; "lane", lane_label ]
    ()
;;

let dec_pending ~keeper_name () =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLanePending)
    ~labels:[ "keeper", keeper_name; "lane", lane_label ]
    ()
;;

let inc_in_flight ~keeper_name () =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLaneInFlight)
    ~labels:[ "keeper", keeper_name; "lane", lane_label ]
    ()
;;

let dec_in_flight ~keeper_name () =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLaneInFlight)
    ~labels:[ "keeper", keeper_name; "lane", lane_label ]
    ()
;;

let inc_latest_pending ~keeper_name () =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLaneLatestPending)
    ~labels:[ "keeper", keeper_name; "lane", lane_label ]
    ()
;;

let dec_latest_pending ~keeper_name () =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLaneLatestPending)
    ~labels:[ "keeper", keeper_name; "lane", lane_label ]
    ()
;;

let protect_cleanup ~keeper_name label f =
  try f () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_counter ~keeper_name MemoryLaneUnitFailures;
    Log.Keeper.warn ~keeper_name
      "memory lane cleanup failed (%s): %s"
      label
      (Printexc.to_string exn)
;;

type librarian_submission =
  | Start_drain of librarian_drain
  | Queue_latest
  | Replace_latest
  | Purge_in_progress

type librarian_drain_step =
  | Drain_stopped
  | Drain_done of Eio.Switch.hook option
  | Drain_next of (unit -> unit)

let librarian_reserve entry f =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    if Option.is_some entry.purge_owner then Purge_in_progress else
    match entry.librarian_drain with
    | None ->
      let drain =
        { latest = None
        ; in_flight = false
        ; switch_hook = None
        ; owner_lane = Keeper_lane.create ()
        }
      in
      entry.librarian_drain <- Some drain;
      entry.last_owner_lane <- Some drain.owner_lane;
      Start_drain drain
    | Some drain ->
      (match drain.latest with
       | None ->
         drain.latest <- Some f;
         Queue_latest
       | Some _ ->
         drain.latest <- Some f;
         Replace_latest))
;;

let has_waiting ~base_path ~keeper_name =
  let key = entry_key ~base_path ~keeper_name in
  match Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key) with
  | None -> false
  | Some entry ->
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      match entry.librarian_drain with
      | Some drain -> Option.is_some drain.latest
      | None -> false)
;;

let librarian_drain_is_active entry drain =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.librarian_drain with
    | Some current -> current == drain
    | None -> false)
;;

let emit_librarian_cleanup ~keeper_name ~pending ~in_flight ~latest_pending =
  for _ = 1 to pending do
    protect_cleanup ~keeper_name "dec_pending" (fun () ->
      dec_pending ~keeper_name ())
  done;
  if in_flight
  then
    protect_cleanup ~keeper_name "dec_in_flight" (fun () ->
      dec_in_flight ~keeper_name ());
  if latest_pending
  then
    protect_cleanup ~keeper_name "dec_latest_pending" (fun () ->
      dec_latest_pending ~keeper_name ())
;;

let detach_librarian_drain entry drain =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.librarian_drain with
    | Some current when current == drain ->
      let pending = pending_in_drain drain in
      let in_flight = drain.in_flight in
      let latest_pending = Option.is_some drain.latest in
      let hook = drain.switch_hook in
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
    protect_cleanup ~keeper_name
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
  if started then inc_in_flight ~keeper_name ();
  started
;;

let librarian_finish_current ~keeper_name entry drain =
  let in_flight, took_latest, step =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      match entry.librarian_drain with
      | Some current when current == drain ->
        let in_flight = drain.in_flight in
        drain.in_flight <- false;
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
  then dec_in_flight ~keeper_name ();
  (match step with
   | Drain_stopped -> ()
   | Drain_done _ | Drain_next _ ->
     dec_pending ~keeper_name ());
  if took_latest then dec_latest_pending ~keeper_name ();
  step
;;

let rec run_librarian_drain ~keeper_name entry drain sw current =
  if librarian_begin_current ~keeper_name entry drain
  then (
    (try Eio_context.with_turn_switch sw current with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       record_counter ~keeper_name MemoryLaneUnitFailures;
       Log.Keeper.warn ~keeper_name
         "memory lane unit failed: %s"
         (Printexc.to_string exn));
    match librarian_finish_current ~keeper_name entry drain with
    | Drain_stopped -> ()
    | Drain_done hook ->
      Option.iter (fun h -> ignore (Eio.Switch.try_remove_hook h)) hook
    | Drain_next latest ->
      run_librarian_drain ~keeper_name entry drain sw latest)
;;

let drop_during_purge ~keeper_name =
  record_counter ~keeper_name MemoryLaneDropped;
  Log.Keeper.info ~keeper_name "Librarian wake discarded while keeper files are being purged";
  Dropped
;;

let submit_librarian ~keeper_name entry sw f =
  match librarian_reserve entry f with
  | Purge_in_progress -> drop_during_purge ~keeper_name
  | Queue_latest ->
    inc_pending ~keeper_name ();
    inc_latest_pending ~keeper_name ();
    record_counter ~keeper_name MemoryLaneSubmitted;
    Submitted
  | Replace_latest ->
    record_counter ~keeper_name MemoryLaneCoalesced;
    (* Coalescing is the lane's normal flow (a newer unit supersedes an
       unprocessed older one), not a fault; INFO keeps it observable without
       paging. The old message hardcoded "pending=2" as a literal, which
       reported a count no code tracked. *)
    Log.Keeper.info ~keeper_name
      "memory lane coalesced latest snapshot (lane=librarian): replacing \
       superseded post-turn memory unit";
    Coalesced
  | Start_drain drain ->
    inc_pending ~keeper_name ();
    record_counter ~keeper_name MemoryLaneSubmitted;
    arm_librarian_switch_release ~keeper_name entry drain sw;
    if not (librarian_drain_is_active entry drain)
    then (
      let reason = Failure "Librarian executor switch released before lane start" in
      (match Keeper_lane.reject_before_start drain.owner_lane ~reason with
       | Ok () -> ()
       | Error _ ->
         (* Rejection only fails after another path has already claimed this
            exact owner receipt; either way it is no longer [Not_started]. *)
         ());
      record_counter ~keeper_name MemoryLaneDropped;
      Log.Keeper.warn ~keeper_name
        "memory lane executor switch unavailable (lane=librarian): dropping post-turn \
         memory unit";
      Dropped)
    else (
      try
        (match
           Keeper_lane.fork
             ~sw
             drain.owner_lane
             ~run:(fun lane_sw ->
               run_librarian_drain ~keeper_name entry drain lane_sw f)
             ~cleanup:(fun _outcome ->
               cleanup_librarian_drain
                 ~keeper_name
                 ~remove_hook:true
                 entry
                 drain;
               Ok ())
         with
         | Ok () -> Submitted
         | Error error ->
           cleanup_librarian_drain ~keeper_name ~remove_hook:true entry drain;
           record_counter ~keeper_name MemoryLaneUnitFailures;
           Log.Keeper.warn ~keeper_name
             "memory lane fork failed: %s"
             (Keeper_lane.start_error_to_string error);
           Dropped)
      with
      | Eio.Cancel.Cancelled _ as e ->
        cleanup_librarian_drain ~keeper_name ~remove_hook:true entry drain;
        raise e
      | exn ->
        cleanup_librarian_drain ~keeper_name ~remove_hook:true entry drain;
        record_counter ~keeper_name MemoryLaneUnitFailures;
        Log.Keeper.warn ~keeper_name
          "memory lane fork failed: %s"
          (Printexc.to_string exn);
        Dropped)
;;

let submit ~base_path ~keeper_name f =
  match current_sw () with
  | None ->
    let entry = entry_for ~base_path ~keeper_name in
    if Stdlib.Mutex.protect entry.state_mu (fun () -> Option.is_some entry.purge_owner)
    then drop_during_purge ~keeper_name
    else (
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
    Ran_inline)
  | Some sw ->
    let entry = entry_for ~base_path ~keeper_name in
    submit_librarian ~keeper_name entry sw f
;;

type external_effect_error = External_purge_in_progress | External_cancelled_by_purge
let external_effect_error_to_string = function
  | External_purge_in_progress -> "Keeper purge excludes a new external Librarian effect"
  | External_cancelled_by_purge -> "Original external Librarian effect was cancelled and joined for purge"
exception External_effect_purge of unit ref

let with_external_effect ~base_path ~keeper_name run =
  let entry=entry_for ~base_path ~keeper_name in
  let identity=ref () and registered=ref None in
  Fun.protect ~finally:(fun () ->
    Eio.Cancel.protect (fun () ->
      match !registered with
      | None -> ()
      | Some active ->
        Stdlib.Mutex.protect entry.state_mu (fun () ->
          entry.external_effects <- List.filter (fun current -> current.identity != identity) entry.external_effects);
        Eio.Promise.resolve active.resolve_exit ()))
    (fun () ->
      try Eio.Cancel.sub (fun context ->
        let exited,resolve_exit=Eio.Promise.create () in
        let active={identity;context;owner_domain=Domain.self ();exited;resolve_exit} in
        let acquired=Stdlib.Mutex.protect entry.state_mu (fun () ->
          if Option.is_some entry.purge_owner then false
          else (entry.external_effects <- active :: entry.external_effects;true)) in
        if not acquired then Error External_purge_in_progress
        else (registered:=Some active;Ok (run ())))
      with Eio.Cancel.Cancelled (External_effect_purge cancelled) when cancelled == identity ->
        (* This sub-scope has unwound. Parent/worker cancellation must still
           propagate; a Keeper purge alone must not kill the shared host loop. *)
        Eio.Fiber.check ();
        Error External_cancelled_by_purge)
;;

type purge_cancel_error =
  | Purge_already_in_progress
  | Purge_cancel_wrong_domain
  | Purge_cancel_not_committed of exn

let purge_cancel_error_to_string = function
  | Purge_already_in_progress -> "A Keeper purge already owns this Librarian lane"
  | Purge_cancel_wrong_domain ->
    "Librarian cancellation was requested from a domain that does not own the lane"
  | Purge_cancel_not_committed exn ->
    "Librarian cancellation was not committed: " ^ Printexc.to_string exn
;;

(* A purge deletes the progress file, and a unit still running could write it
   again afterwards. So the purge cancels the unit and waits for its lane to
   exit before it deletes anything. There is no time limit on the wait:
   cancellation is requested first, and a cancelled fiber unwinds through
   every suspension point, so the exit is not something to guess a bound for.
   The read position is written only after a Memory commit, so a round cut
   short here has left nothing half-written. *)
let cancel_and_await_librarian ~base_path ~keeper_name =
  (* Do not create an entry merely to purge it. with_librarian_purge has already
     excluded new drain submissions and external registrations. *)
  let owner_lane,effects =
    let key=entry_key ~base_path ~keeper_name in
    match Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key) with
    | None -> None,[]
    | Some entry -> Stdlib.Mutex.protect entry.state_mu (fun () ->
        (match entry.librarian_drain with Some drain -> Some drain.owner_lane
         | None -> entry.last_owner_lane),entry.external_effects) in
  let request_lane lane =
    match Keeper_lane.peek_exit lane with
    | Some _ -> Ok ()
    | None -> match Keeper_lane.request_cancel lane with
      | Keeper_lane.Cancel_requested | Cancel_already_requested | Cancel_already_exiting -> Ok ()
      | Cancel_committed_with_failure exn ->
        Log.Keeper.warn ~keeper_name "Librarian cancellation committed with a callback failure: %s"
          (Printexc.to_string exn);Ok ()
      | Cancel_wrong_domain -> Error Purge_cancel_wrong_domain
      | Cancel_not_committed exn -> Error (Purge_cancel_not_committed exn) in
  let request_effect active =
    if active.owner_domain <> Domain.self () then Error Purge_cancel_wrong_domain
    else match Eio.Cancel.get_error active.context with
    | Some _ -> Ok ()
    | None ->
      (try Eio.Cancel.cancel active.context (External_effect_purge active.identity);Ok ()
       with exn -> (* cancel-guard-ok: cancel does not suspend this fiber; classify committed callback failures. *)
         match Eio.Cancel.get_error active.context with
         | Some (Eio.Cancel.Cancelled _) ->
           Log.Keeper.warn ~keeper_name "External Librarian cancellation committed with a callback failure: %s"
             (Printexc.to_string exn);Ok ()
         | None | Some _ -> Error (Purge_cancel_not_committed exn)) in
  (* Issue every cancellation before any join: a drain may itself be awaiting
     an external effect's result. A failed signal never authorizes deletion. *)
  let lane_signal=Option.fold ~none:(Ok ()) ~some:request_lane owner_lane in
  let effect_signals=List.map request_effect effects in
  let* ()=List.fold_left (fun first result -> match first with
    | Error _ -> first | Ok () -> result) lane_signal effect_signals in
  Option.iter (fun lane ->
    let exit=Keeper_lane.await_exit lane in
    match exit.Keeper_lane.cleanup_error with
    | None -> ()
    | Some detail -> Log.Keeper.warn ~keeper_name
      "Librarian lane exited with a cleanup failure before purge: %s" detail) owner_lane;
  List.iter (fun active -> Eio.Promise.await active.exited) effects;
  Ok ()
;;

let with_librarian_purge ~base_path ~keeper_name action =
  let entry = entry_for ~base_path ~keeper_name in
  let identity = ref () in
  Eio.Switch.run (fun sw ->
    (* Install release before acquisition; another purge's refusal cannot
       clear the identity of the caller that actually owns the exclusion. *)
    Eio.Switch.on_release sw (fun () ->
      Stdlib.Mutex.protect entry.state_mu (fun () ->
        match entry.purge_owner with
        | Some owner when owner == identity -> entry.purge_owner <- None
        | Some _ | None -> ()));
    let acquired = Stdlib.Mutex.protect entry.state_mu (fun () ->
      match entry.purge_owner with
      | Some _ -> false
      | None -> entry.purge_owner <- Some identity; true)
    in
    if not acquired then Error Purge_already_in_progress
    else
      match cancel_and_await_librarian ~base_path ~keeper_name with
      | Error error -> Error error
      | Ok () -> Ok (action ()))
;;

module For_testing = struct
  let reset () =
    Stdlib.Mutex.protect registry_mu (fun () ->
      Hashtbl.reset entries;
      executor_sw := None)
  ;;

  let pending ~base_path ~keeper_name =
    let key = entry_key ~base_path ~keeper_name in
    Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key)
    |> Option.map (fun e ->
      Stdlib.Mutex.protect e.state_mu (fun () ->
        match e.librarian_drain with
        | None -> 0
        | Some drain -> pending_in_drain drain))
  ;;

  let external_active ~base_path ~keeper_name =
    let key=entry_key ~base_path ~keeper_name in
    match Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key) with
    | None -> 0
    | Some entry -> Stdlib.Mutex.protect entry.state_mu (fun () -> List.length entry.external_effects)
  ;;

  let await_idle ~base_path ~keeper_name =
    let key = entry_key ~base_path ~keeper_name in
    let owner_lane =
      match
        Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key)
      with
      | None -> None
      | Some entry ->
        Stdlib.Mutex.protect entry.state_mu (fun () ->
          match entry.librarian_drain with
          | Some drain -> Some drain.owner_lane
          | None -> entry.last_owner_lane)
    in
    Option.iter
      (* See [await_idle]: only the exit boundary matters to this test seam. *)
      (fun owner_lane -> ignore (Keeper_lane.await_exit owner_lane : Keeper_lane.exit))
      owner_lane
  ;;
end
