type lane =
  | Keeper_lane of string
  | Connector_lane of string

type event_id =
  { source : string
  ; opaque_id : string
  }

type failure =
  { lane : lane
  ; event_id : event_id
  ; reason : string
  }

type job =
  { event_id : event_id
  ; run : unit -> unit
  }

type lane_state =
  { jobs : job Queue.t
  ; mutable scheduled : bool
  ; mutable active : bool
  }

type t =
  { sw : Eio.Switch.t
  ; mutex : Stdlib.Mutex.t
  ; condition : Eio.Condition.t
  ; lanes : (lane, lane_state) Hashtbl.t
  ; ready : lane Queue.t
  ; on_failure : failure -> unit
  }

let lane_to_string = function
  | Keeper_lane keeper_name -> "keeper:" ^ keeper_name
  | Connector_lane connector_id -> "connector:" ^ connector_id
;;

let event_id_to_string event_id =
  event_id.source ^ ":" ^ event_id.opaque_id
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
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    report_failure
      t
      { lane; event_id = job.event_id; reason = Printexc.to_string exn }
;;

let take_lane_job t lane state =
  with_lock t (fun () ->
    match Queue.take_opt state.jobs with
    | Some job -> Some job
    | None ->
      state.active <- false;
      Hashtbl.remove t.lanes lane;
      None)
;;

let rec run_lane t lane state =
  match take_lane_job t lane state with
  | None -> ()
  | Some job ->
    run_job t lane job;
    Eio.Fiber.yield ();
    run_lane t lane state
;;

let take_ready_lane t =
  with_lock t (fun () ->
    match Queue.take_opt t.ready with
    | None -> None
    | Some lane ->
      (match Hashtbl.find_opt t.lanes lane with
       | Some state when state.scheduled && not state.active ->
         state.scheduled <- false;
         state.active <- true;
         Some (lane, state)
       | Some _ | None -> None))
;;

let rec run_dispatcher t : [ `Stop_daemon ] =
  let lane, state =
    Eio.Condition.loop_no_mutex t.condition (fun () -> take_ready_lane t)
  in
  Eio.Fiber.fork ~sw:t.sw (fun () -> run_lane t lane state);
  run_dispatcher t
;;

let create ~sw ~on_failure () =
  let t =
    { sw
    ; mutex = Stdlib.Mutex.create ()
    ; condition = Eio.Condition.create ()
    ; lanes = Hashtbl.create 16
    ; ready = Queue.create ()
    ; on_failure
    }
  in
  Eio.Fiber.fork_daemon ~sw (fun () -> run_dispatcher t);
  t
;;

let submit t ~lane ~event_id run =
  let notify =
    with_lock t (fun () ->
      let state =
        match Hashtbl.find_opt t.lanes lane with
        | Some state -> state
        | None ->
          let state =
            { jobs = Queue.create (); scheduled = false; active = false }
          in
          Hashtbl.add t.lanes lane state;
          state
      in
      Queue.add { event_id; run } state.jobs;
      if state.active || state.scheduled
      then false
      else (
        state.scheduled <- true;
        Queue.add lane t.ready;
        true))
  in
  if notify then Eio.Condition.broadcast t.condition
;;
