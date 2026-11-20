type lane = Keeper_lane of string

type event_id =
  { source : string
  ; opaque_id : string
  }

type failure_reason =
  | Callback_raised of string
  | Callback_cancelled of string
  | Owner_released

type failure =
  { lane : lane
  ; event_id : event_id
  ; reason : failure_reason
  }

type submit_error = Owner_unavailable

type lane_config =
  { max_pending_per_lane : int
  }

type job =
  { event_id : event_id
  ; run : unit -> unit
  }

(* Idle lanes are absent from [lanes]. Active starts when dispatch claims a
   lane, and lasts through callbacks and yields until its FIFO is checked empty. *)
type lane_phase = Scheduled | Active

type lane_state =
  { jobs : job Queue.t
  ; mutable phase : lane_phase
  }

type waiter =
  { cond : Eio.Condition.t
  ; mutable cancelled : bool
  }

type t =
  { sw : Eio.Switch.t
  ; mutex : Stdlib.Mutex.t
  ; condition : Eio.Condition.t
  ; lanes : (lane, lane_state) Hashtbl.t
  ; waiters : (lane, waiter Queue.t) Hashtbl.t
  ; ready : lane Queue.t
  ; capacity_limit : int option
  ; on_failure : failure -> unit
  ; mutable lifecycle : [ `Open | `Closed ]
  }

let lane_to_string (Keeper_lane keeper_name) = "keeper:" ^ keeper_name

let event_id_to_string event_id =
  event_id.source ^ ":" ^ event_id.opaque_id
;;

let failure_reason_to_string = function
  | Callback_raised detail -> "callback_raised: " ^ detail
  | Callback_cancelled detail -> "callback_cancelled: " ^ detail
  | Owner_released -> "owner_released"
;;

let submit_error_to_string = function
  | Owner_unavailable -> "owner_unavailable"
;;

let with_lock t f = Stdlib.Mutex.protect t.mutex f

let report_failure t failure =
  try t.on_failure failure with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Server.error
      "connector ingress failure observer crashed lane=%s event=%s: %s"
      (lane_to_string failure.lane)
      (event_id_to_string failure.event_id)
      (Printexc.to_string exn)
;;

let run_job t lane job =
  try job.run () with
  | Eio.Cancel.Cancelled cause as exn ->
    Eio.Cancel.protect (fun () ->
      report_failure
        t
        { lane
        ; event_id = job.event_id
        ; reason = Callback_cancelled (Printexc.to_string cause)
        });
    raise exn
  | exn ->
    report_failure
      t
      { lane
      ; event_id = job.event_id
      ; reason = Callback_raised (Printexc.to_string exn)
      }
;;

let owner_available t =
  match t.lifecycle, Eio.Switch.get_error t.sw with
  | `Open, None -> true
  | `Closed, _ | `Open, Some _ -> false
;;

let pending_count_locked t lane =
  match Hashtbl.find_opt t.lanes lane with
  | Some state -> Queue.length state.jobs
  | None -> 0
;;

let lane_has_capacity_locked t lane =
  match t.capacity_limit with
  | None -> true
  | Some capacity -> pending_count_locked t lane < capacity
;;

let rec prune_cancelled_head q =
  match Queue.peek_opt q with
  | Some w when w.cancelled ->
    ignore (Queue.take_opt q);
    prune_cancelled_head q
  | Some _ | None -> ()
;;

let peek_live_waiter_locked t lane =
  match Hashtbl.find_opt t.waiters lane with
  | None -> None
  | Some q ->
    prune_cancelled_head q;
    if Queue.is_empty q
    then (
      Hashtbl.remove t.waiters lane;
      None)
    else Queue.peek_opt q
;;

let peek_wake_waiter_cond_locked t lane =
  if not (owner_available t)
  then None
  else if lane_has_capacity_locked t lane
  then Option.map (fun w -> w.cond) (peek_live_waiter_locked t lane)
  else None
;;

let drain_all_waiters_locked t =
  let conds =
    Hashtbl.fold
      (fun _lane q acc ->
         let lane_conds = Queue.fold (fun acc w -> w.cond :: acc) [] q in
         Queue.clear q;
         lane_conds @ acc)
      t.waiters
      []
  in
  Hashtbl.clear t.waiters;
  conds
;;

let push_waiter_locked t lane waiter =
  let q =
    match Hashtbl.find_opt t.waiters lane with
    | Some q -> q
    | None ->
      let q = Queue.create () in
      Hashtbl.add t.waiters lane q;
      q
  in
  Queue.add waiter q
;;

let remove_waiter_locked t lane waiter =
  waiter.cancelled <- true;
  match Hashtbl.find_opt t.waiters lane with
  | None -> ()
  | Some q ->
    let filtered = Queue.create () in
    Queue.iter
      (fun w -> if not w.cancelled && w != waiter then Queue.add w filtered)
      q;
    Queue.clear q;
    if Queue.is_empty filtered
    then Hashtbl.remove t.waiters lane
    else Queue.transfer filtered q
;;

let enqueue_job_locked t ~lane ~event_id run =
  let job = { event_id; run } in
  match Hashtbl.find_opt t.lanes lane with
  | Some state ->
    (* Scheduled lanes already have a ready key. Active lanes retain
       their worker even when its callback has emptied the FIFO. *)
    Queue.add job state.jobs;
    false
  | None ->
    let state = { jobs = Queue.create (); phase = Scheduled } in
    Queue.add job state.jobs;
    Hashtbl.add t.lanes lane state;
    Queue.add lane t.ready;
    true
;;

let take_lane_job t lane state =
  let job_opt, waiter_conds =
    with_lock t (fun () ->
      if not (owner_available t)
      then None, drain_all_waiters_locked t
      else
        match Queue.take_opt state.jobs with
        | Some job ->
          let wake =
            match peek_wake_waiter_cond_locked t lane with
            | Some cond -> [ cond ]
            | None -> []
          in
          Some job, wake
        | None ->
          Hashtbl.remove t.lanes lane;
          let wake =
            match peek_wake_waiter_cond_locked t lane with
            | Some cond -> [ cond ]
            | None -> []
          in
          None, wake)
  in
  List.iter Eio.Condition.broadcast waiter_conds;
  job_opt
;;

let cleanup_lane t lane state =
  let action, waiter_conds =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.lanes lane with
      | Some current when current == state ->
        if Queue.is_empty state.jobs
        then (
          Hashtbl.remove t.lanes lane;
          let wake =
            match peek_wake_waiter_cond_locked t lane with
            | Some cond -> [ cond ]
            | None ->
              if not (owner_available t)
              then drain_all_waiters_locked t
              else []
          in
          `Done, wake)
        else if owner_available t
        then (
          (* Requeue leftover jobs if the worker exited abnormally while the
             owner remained open. *)
          state.phase <- Scheduled;
          Queue.add lane t.ready;
          let wake =
            match peek_wake_waiter_cond_locked t lane with
            | Some cond -> [ cond ]
            | None -> []
          in
          `Reschedule, wake)
        else (
          let jobs =
            Queue.fold (fun acc job -> job :: acc) [] state.jobs |> List.rev
          in
          Queue.clear state.jobs;
          Hashtbl.remove t.lanes lane;
          `Drain jobs, drain_all_waiters_locked t)
      | Some _ | None ->
        let wake =
          if not (owner_available t)
          then drain_all_waiters_locked t
          else []
        in
        `Done, wake)
  in
  List.iter Eio.Condition.broadcast waiter_conds;
  match action with
  | `Done -> ()
  | `Reschedule -> Eio.Condition.broadcast t.condition
  | `Drain jobs ->
    Eio.Cancel.protect (fun () ->
      List.iter
        (fun job ->
           report_failure
             t
             { lane; event_id = job.event_id; reason = Owner_released })
        jobs)
;;

let run_lane t lane state =
  let rec loop () =
    match take_lane_job t lane state with
    | None -> ()
    | Some job ->
      run_job t lane job;
      Eio.Fiber.yield ();
      loop ()
  in
  Fun.protect ~finally:(fun () -> cleanup_lane t lane state) loop
;;

(* Drain past stale or already-active entries so a non-empty ready queue can
   never return [None] and lose a wakeup for later [Scheduled] lanes. *)
let take_ready_lane t =
  with_lock t (fun () ->
    let rec next () =
      if not (owner_available t)
      then None
      else
        match Queue.take_opt t.ready with
        | None -> None
        | Some lane ->
          (match Hashtbl.find_opt t.lanes lane with
           | Some state ->
             (match state.phase with
              | Scheduled ->
                state.phase <- Active;
                Some (lane, state)
              | Active -> next ())
           | None -> next ())
    in
    next ())
;;

let rec run_dispatcher t : [ `Stop_daemon ] =
  let lane, state =
    Eio.Condition.loop_no_mutex t.condition (fun () -> take_ready_lane t)
  in
  (try Eio.Fiber.fork ~sw:t.sw (fun () -> run_lane t lane state) with
   | exn ->
     let bt = Printexc.get_raw_backtrace () in
     cleanup_lane t lane state;
     Printexc.raise_with_backtrace exn bt);
  run_dispatcher t
;;

let close t =
  let pending, waiter_conds =
    with_lock t (fun () ->
      match t.lifecycle with
      | `Closed -> [], []
      | `Open ->
        t.lifecycle <- `Closed;
        let pending_by_lane =
          Hashtbl.fold
            (fun lane state acc ->
               let jobs =
                 Queue.fold
                   (fun acc job -> (lane, job) :: acc)
                   []
                   state.jobs
                 |> List.rev
               in
               Queue.clear state.jobs;
               jobs :: acc)
            t.lanes
            []
        in
        Hashtbl.clear t.lanes;
        Queue.clear t.ready;
        let waiter_conds = drain_all_waiters_locked t in
        List.concat pending_by_lane, waiter_conds)
  in
  Eio.Condition.broadcast t.condition;
  List.iter Eio.Condition.broadcast waiter_conds;
  List.iter
    (fun (lane, job) ->
       report_failure
         t
         { lane; event_id = job.event_id; reason = Owner_released })
    pending
;;

let validate_max_pending = function
  | None -> None
  | Some ({ max_pending_per_lane } : lane_config) ->
    if max_pending_per_lane <= 0
    then
      invalid_arg
        "Connector_ingress_lane.create: max_pending_per_lane must be positive"
    else Some max_pending_per_lane
;;

let create ~sw ?config ~on_failure () =
  Eio.Switch.check sw;
  let capacity_limit = validate_max_pending config in
  let t =
    { sw
    ; mutex = Stdlib.Mutex.create ()
    ; condition = Eio.Condition.create ()
    ; lanes = Hashtbl.create 16
    ; waiters = Hashtbl.create 16
    ; ready = Queue.create ()
    ; capacity_limit
    ; on_failure
    ; lifecycle = `Open
    }
  in
  Eio.Switch.on_release sw (fun () -> close t);
  Eio.Fiber.fork_daemon ~sw (fun () -> run_dispatcher t);
  t
;;

let cancel_waiter t lane waiter =
  let wake_cond =
    with_lock t (fun () ->
      remove_waiter_locked t lane waiter;
      peek_wake_waiter_cond_locked t lane)
  in
  Option.iter Eio.Condition.broadcast wake_cond
;;

let try_claim_waiter_slot t ~lane ~event_id ~run waiter =
  Eio.Fiber.check ();
  let step =
    with_lock t (fun () ->
      if not (owner_available t)
      then (
        remove_waiter_locked t lane waiter;
        `Closed (drain_all_waiters_locked t))
      else
        match peek_live_waiter_locked t lane with
        | Some head when head == waiter && lane_has_capacity_locked t lane ->
          (match Hashtbl.find_opt t.waiters lane with
           | Some q ->
             ignore (Queue.take_opt q);
             if Queue.is_empty q then Hashtbl.remove t.waiters lane
           | None -> ());
          let notify_dispatcher = enqueue_job_locked t ~lane ~event_id run in
          let wake_next = peek_wake_waiter_cond_locked t lane in
          `Claimed (notify_dispatcher, wake_next)
        | Some _ -> `Retry
        | None ->
          if lane_has_capacity_locked t lane
          then (
            let notify_dispatcher = enqueue_job_locked t ~lane ~event_id run in
            `Claimed (notify_dispatcher, None))
          else (
            push_waiter_locked t lane waiter;
            `Retry))
  in
  match step with
  | `Closed extra_conds ->
    List.iter Eio.Condition.broadcast extra_conds;
    Some (Error Owner_unavailable)
  | `Claimed (notify_dispatcher, wake_next) ->
    Some (Ok (notify_dispatcher, wake_next))
  | `Retry -> None
;;

let submit t ~lane ~event_id run =
  let initial =
    with_lock t (fun () ->
      if not (owner_available t)
      then `Closed
      else
        let can_enqueue_now =
          Option.is_none t.capacity_limit
          || (Option.is_none (peek_live_waiter_locked t lane)
              && lane_has_capacity_locked t lane)
        in
        if can_enqueue_now
        then `Accepted (enqueue_job_locked t ~lane ~event_id run)
        else (
          let waiter = { cond = Eio.Condition.create (); cancelled = false } in
          push_waiter_locked t lane waiter;
          `Wait waiter))
  in
  match initial with
  | `Closed -> Error Owner_unavailable
  | `Accepted notify_dispatcher ->
    if notify_dispatcher then Eio.Condition.broadcast t.condition;
    Ok ()
  | `Wait waiter ->
    (try
       Eio.Fiber.check ();
       match
         Eio.Condition.loop_no_mutex waiter.cond (fun () ->
           try_claim_waiter_slot t ~lane ~event_id ~run waiter)
       with
       | Error _ as err -> err
       | Ok (notify_dispatcher, wake_next) ->
         if notify_dispatcher then Eio.Condition.broadcast t.condition;
         Option.iter Eio.Condition.broadcast wake_next;
         Ok ()
     with
     | exn ->
       let bt = Printexc.get_raw_backtrace () in
       cancel_waiter t lane waiter;
       Printexc.raise_with_backtrace exn bt)
;;

let pending_count t ~lane =
  with_lock t (fun () -> pending_count_locked t lane)
;;

let capacity t = t.capacity_limit
;;
