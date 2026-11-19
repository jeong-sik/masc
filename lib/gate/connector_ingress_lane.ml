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

type bounded_submit_error =
  | Closed
  | Lane_full of
      { lane : lane
      ; pending : int
      ; capacity : int
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

type t =
  { sw : Eio.Switch.t
  ; mutex : Stdlib.Mutex.t
  ; condition : Eio.Condition.t
  ; lanes : (lane, lane_state) Hashtbl.t
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

let bounded_submit_error_to_string = function
  | Closed -> "closed"
  | Lane_full { lane; pending; capacity } ->
    Printf.sprintf
      "lane_full(%s: pending=%d capacity=%d)"
      (lane_to_string lane)
      pending
      capacity
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

let take_lane_job t lane state =
  with_lock t (fun () ->
    if not (owner_available t)
    then None
    else
      match Queue.take_opt state.jobs with
      | Some job -> Some job
      | None ->
        Hashtbl.remove t.lanes lane;
        None)
;;

let cleanup_lane t lane state =
  let action =
    with_lock t (fun () ->
      match Hashtbl.find_opt t.lanes lane with
      | Some current when current == state ->
        if Queue.is_empty state.jobs
        then (
          Hashtbl.remove t.lanes lane;
          `Done)
        else if owner_available t
        then (
          (* Requeue leftover jobs if the worker exited abnormally while the
             owner remained open. *)
          state.phase <- Scheduled;
          Queue.add lane t.ready;
          `Reschedule)
        else (
          let jobs =
            Queue.fold (fun acc job -> job :: acc) [] state.jobs |> List.rev
          in
          Queue.clear state.jobs;
          Hashtbl.remove t.lanes lane;
          `Drain jobs)
      | Some _ | None -> `Done)
  in
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
  let pending =
    with_lock t (fun () ->
      match t.lifecycle with
      | `Closed -> []
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
        List.concat pending_by_lane)
  in
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

let create_bounded ~sw ~config ~on_failure () =
  create ~sw ~config ~on_failure ()
;;

let submit_bounded t ~lane ~event_id run =
  let submission =
    with_lock t (fun () ->
      if not (owner_available t)
      then Error Closed
      else
        let job = { event_id; run } in
        (match Hashtbl.find_opt t.lanes lane with
         | Some state ->
           let pending = Queue.length state.jobs in
           (match t.capacity_limit with
            | Some capacity when pending >= capacity ->
              Error (Lane_full { lane; pending; capacity })
            | Some _ | None ->
              (* Scheduled lanes already have a ready key. Active lanes retain
                 their worker even when its callback has emptied the FIFO. *)
              Queue.add job state.jobs;
              Ok false)
         | None ->
           let state = { jobs = Queue.create (); phase = Scheduled } in
           Queue.add job state.jobs;
           Hashtbl.add t.lanes lane state;
           Queue.add lane t.ready;
           Ok true))
  in
  match submission with
  | Error _ as error -> error
  | Ok notify ->
    if notify then Eio.Condition.broadcast t.condition;
    Ok ()
;;

let submit t ~lane ~event_id run =
  match submit_bounded t ~lane ~event_id run with
  | Ok () -> Ok ()
  | Error Closed -> Error Owner_unavailable
  | Error (Lane_full { lane; pending; capacity }) ->
    Log.Server.warn
      "connector ingress lane full lane=%s pending=%d capacity=%d"
      (lane_to_string lane)
      pending
      capacity;
    Error Owner_unavailable
;;

let pending_count t ~lane =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.lanes lane with
    | Some state -> Queue.length state.jobs
    | None -> 0)
;;

let capacity t = t.capacity_limit
;;
