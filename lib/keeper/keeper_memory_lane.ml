(** Per-keeper Librarian execution lane. See keeper_memory_lane.mli (RFC-0257). *)

let lane_label = "librarian"

type librarian_drain =
  { mutable latest : (unit -> unit) option
  ; mutable in_flight : bool
  ; mutable switch_hook : Eio.Switch.hook option
  ; owner_lane : Keeper_lane.t
  }

type entry =
  { state_mu : Stdlib.Mutex.t
    (* Guards [lifecycle], [pending], [librarian_drain], and
       [last_owner_lane]. Critical sections never yield. *)
  ; mutable lifecycle : lifecycle
  ; mutable pending : int
  ; mutable librarian_drain : librarian_drain option
  ; mutable last_owner_lane : Keeper_lane.t option
  }

and lifecycle =
  | Accepting
  | Draining

type outcome =
  | Submitted
  | Coalesced
  | Ran_inline
  | Dropped
  | Rejected_draining

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

let make_entry lifecycle =
  { state_mu = Stdlib.Mutex.create ()
  ; lifecycle
  ; pending = 0
  ; librarian_drain = None
  ; last_owner_lane = None
  }
;;

let entry_for ~base_path ~keeper_name =
  let key = entry_key ~base_path ~keeper_name in
  Stdlib.Mutex.protect registry_mu (fun () ->
    match Hashtbl.find_opt entries key with
    | Some e -> e
    | None ->
      let e = make_entry Accepting in
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
  | Reject_draining

type librarian_drain_step =
  | Drain_stopped
  | Drain_done of Eio.Switch.hook option
  | Drain_next of (unit -> unit)

let librarian_reserve entry f =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.lifecycle, entry.librarian_drain with
    | Draining, _ -> Reject_draining
    | Accepting, None ->
      let drain =
        { latest = None
        ; in_flight = false
        ; switch_hook = None
        ; owner_lane = Keeper_lane.create ()
        }
      in
      entry.librarian_drain <- Some drain;
      entry.last_owner_lane <- Some drain.owner_lane;
      entry.pending <- 1;
      Start_drain drain
    | Accepting, Some drain ->
      (match drain.latest with
       | None ->
         drain.latest <- Some f;
         entry.pending <- entry.pending + 1;
         Queue_latest
       | Some _ ->
         drain.latest <- Some f;
         Replace_latest))
;;

type lifecycle_open_error = Librarian_drain_still_active

let lifecycle_open_error_to_string = function
  | Librarian_drain_still_active ->
    "a prior Keeper lifecycle still owns active Librarian work"
;;

let begin_librarian_lifecycle ~base_path ~keeper_name =
  let entry = entry_for ~base_path ~keeper_name in
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.librarian_drain, entry.last_owner_lane with
    | Some _, _ -> Error Librarian_drain_still_active
    | None, Some owner_lane when Option.is_none (Keeper_lane.peek_exit owner_lane) ->
      Error Librarian_drain_still_active
    | None, (None | Some _) ->
      (* A new admitted Keeper lifecycle owns no work from the prior one. Keep
         terminal receipts until this boundary so shutdown can still observe a
         failed/cancelled owner, then clear them even if that owner exited while
         the entry was still [Accepting] (for example, a pre-fork executor
         drop). *)
      entry.last_owner_lane <- None;
      entry.lifecycle <- Accepting;
      Ok ())
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

let submit_librarian ~keeper_name entry sw f =
  match librarian_reserve entry f with
  | Reject_draining ->
    record_counter ~keeper_name MemoryLaneRejectedDraining;
    Log.Keeper.warn ~keeper_name
      "memory lane rejected post-turn unit after lifecycle drain began (lane=librarian)";
    Rejected_draining
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
    (* Not initialized: run inline. The caller is still inside the per-keeper
       turn lane, so single-fiber-per-keeper memory access is preserved. The
       lifecycle fence still applies before the executor switch exists: a
       launch rollback or terminal drain must not be bypassed by the inline
       fallback. A raising admitted unit is contained and counted rather than
       escaping. *)
    let entry = entry_for ~base_path ~keeper_name in
    if
      Stdlib.Mutex.protect entry.state_mu (fun () -> entry.lifecycle = Draining)
    then Rejected_draining
    else (
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

type librarian_drain_outcome =
  | No_librarian_work
  | Librarian_drained

type librarian_drain_error =
  | Librarian_interrupted of Keeper_lane.outcome
  | Librarian_cleanup_failed of string
  | Librarian_drain_timed_out of float

type librarian_abort_outcome =
  | Librarian_abort_idle
  | Librarian_abort_requested
  | Librarian_abort_already_in_progress
  | Librarian_abort_already_exited of Keeper_lane.exit
  | Librarian_abort_committed_with_failure of exn

type librarian_abort_error =
  | Librarian_abort_wrong_domain
  | Librarian_abort_not_committed of exn

let librarian_lane_outcome_to_string = function
  | Keeper_lane.Completed -> "completed"
  | Keeper_lane.Shutdown_before_start -> "shutdown_before_start"
  | Keeper_lane.Shutdown_requested -> "shutdown_requested"
  | Keeper_lane.Shutdown_cancel_failed failure ->
    "shutdown_cancel_failed: " ^ Printexc.to_string failure.cause
  | Keeper_lane.Cancelled_by_parent exn ->
    "cancelled_by_parent: " ^ Printexc.to_string exn
  | Keeper_lane.Failed exn -> "failed: " ^ Printexc.to_string exn
;;

let librarian_drain_error_to_string = function
  | Librarian_interrupted outcome ->
    "Librarian drain ended without completion: "
    ^ librarian_lane_outcome_to_string outcome
  | Librarian_cleanup_failed detail -> "Librarian cleanup failed: " ^ detail
  | Librarian_drain_timed_out seconds ->
    Printf.sprintf
      "Librarian drain timed out after %.0fs waiting for the owner lane to exit"
      seconds
;;

let librarian_abort_error_to_string = function
  | Librarian_abort_wrong_domain ->
    "Librarian cancellation was requested from a non-owner domain"
  | Librarian_abort_not_committed exn ->
    "Librarian cancellation was not committed: " ^ Printexc.to_string exn
;;

let abort_librarian ~base_path ~keeper_name =
  let entry = entry_for ~base_path ~keeper_name in
  let owner_lane =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      entry.lifecycle <- Draining;
      match entry.librarian_drain with
      | Some drain -> Some drain.owner_lane
      | None -> entry.last_owner_lane)
  in
  match owner_lane with
  | None -> Ok Librarian_abort_idle
  | Some owner_lane ->
    (match Keeper_lane.peek_exit owner_lane with
     | Some exit -> Ok (Librarian_abort_already_exited exit)
     | None ->
       (match Keeper_lane.request_cancel owner_lane with
        | Keeper_lane.Cancel_requested -> Ok Librarian_abort_requested
        | Keeper_lane.Cancel_already_requested
        | Keeper_lane.Cancel_already_exiting ->
          Ok Librarian_abort_already_in_progress
        | Keeper_lane.Cancel_committed_with_failure exn ->
          Ok (Librarian_abort_committed_with_failure exn)
        | Keeper_lane.Cancel_wrong_domain -> Error Librarian_abort_wrong_domain
        | Keeper_lane.Cancel_not_committed exn ->
          Error (Librarian_abort_not_committed exn)))
;;

(* Cap on how long a graceful drain waits for the Librarian owner lane to
   exit. [finish_lifecycle] joins from inside [Eio.Cancel.protect], so an
   outer cancellation (or a test's [with_timeout_exn]) cannot interrupt the
   join; a Librarian unit parked on an external promise would otherwise hang
   keeper termination forever (issue #33576). The race below uses the fiber's
   own cancellation token, which works inside [Cancel.protect]. When no
   global Eio clock is installed the join stays unbounded as before. *)
let librarian_drain_timeout_sec = 30.0

(* Test override so RED/GREEN runs need not wait the production cap. *)
let drain_timeout_override_sec = ref None

let current_drain_timeout_sec () =
  match !drain_timeout_override_sec with
  | Some seconds -> seconds
  | None -> librarian_drain_timeout_sec
;;

let drain_and_join_librarian ~base_path ~keeper_name =
  let entry =
    let key = entry_key ~base_path ~keeper_name in
    Stdlib.Mutex.protect registry_mu (fun () ->
      match Hashtbl.find_opt entries key with
      | Some entry -> entry
      | None ->
        let entry = make_entry Draining in
        Hashtbl.add entries key entry;
        entry)
  in
  let owner_lane =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      entry.lifecycle <- Draining;
      match entry.librarian_drain with
      | Some drain -> Some drain.owner_lane
      | None -> entry.last_owner_lane)
  in
  match owner_lane with
  | None -> Ok No_librarian_work
  | Some owner_lane ->
    let join () = Keeper_lane.await_exit owner_lane in
    let exit_or_timeout :
        [ `Joined of Keeper_lane.exit | `Timed_out of float ] =
      match Eio_context.get_clock_opt () with
      | None -> `Joined (join ())
      | Some clock ->
        let timeout_sec = current_drain_timeout_sec () in
        Eio.Fiber.first
          (fun () -> `Joined (join ()))
          (fun () ->
             Eio.Time.sleep clock timeout_sec;
             `Timed_out timeout_sec)
    in
    match exit_or_timeout with
    | `Timed_out seconds -> Error (Librarian_drain_timed_out seconds)
    | `Joined exit ->
      (match exit.cleanup_error with
       | Some detail -> Error (Librarian_cleanup_failed detail)
       | None ->
         (match exit.outcome with
          | Keeper_lane.Completed -> Ok Librarian_drained
          | outcome -> Error (Librarian_interrupted outcome)))
;;

module For_testing = struct
  let reset () =
    Stdlib.Mutex.protect registry_mu (fun () ->
      Hashtbl.reset entries;
      executor_sw := None;
      drain_timeout_override_sec := None)
  ;;

  let set_drain_timeout_sec seconds = drain_timeout_override_sec := Some seconds
  let drain_timeout_sec () = current_drain_timeout_sec ()
;;

  let pending ~base_path ~keeper_name =
    let key = entry_key ~base_path ~keeper_name in
    Stdlib.Mutex.protect registry_mu (fun () -> Hashtbl.find_opt entries key)
    |> Option.map (fun e -> Stdlib.Mutex.protect e.state_mu (fun () -> e.pending))
  ;;
end
