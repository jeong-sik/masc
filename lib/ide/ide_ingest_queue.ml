(** Bounded ingestion queue for IDE observation events.
    See ide_ingest_queue.mli for the rationale. *)

type job = unit -> unit

let default_capacity = 1024
let active = Atomic.make false

type queue_state =
  { mu : Stdlib.Mutex.t
  ; cond : Eio.Condition.t
  ; space_available : Eio.Condition.t
  ; items : job Queue.t
  }

(* Production never changes this — the only writer is [For_testing.reset].
   Keeping it beside the queue rather than inside it leaves [queue_state]
   with nothing but its lock, condition and item buffer, and the knob does
   not need the queue lock to be read. *)
let capacity = Atomic.make default_capacity

let queue =
  { mu = Stdlib.Mutex.create ()
  ; cond = Eio.Condition.create ()
  ; space_available = Eio.Condition.create ()
  ; items = Queue.create ()
  }

let with_queue f =
  Stdlib.Mutex.lock queue.mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock queue.mu) f
;;

let depth () = with_queue (fun () -> Queue.length queue.items)

let run_job label job =
  try job () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Ide.error "ingest_queue %s: job failed: %s" label (Printexc.to_string exn)
;;

let take_nonblocking () =
  let job = with_queue (fun () -> Queue.take_opt queue.items) in
  (match job with
   | None -> ()
   | Some _ -> Eio.Condition.broadcast queue.space_available);
  job
;;

let drain_pending () =
  let rec loop () =
    match take_nonblocking () with
    | None -> ()
    | Some job ->
      run_job "drain" job;
      loop ()
  in
  loop ()
;;

type admission = Enqueued | Inline

let try_admit job =
  (* No callback, I/O or suspension under this lock: inactive callers can also
     arrive outside Eio. Capacity and writer state are checked with insertion. *)
  with_queue (fun () ->
    if not (Atomic.get active) then Some Inline
    else if Queue.length queue.items < Atomic.get capacity then (
      Queue.add job queue.items;
      Some Enqueued)
    else None)
;;

let submit (job : job) : unit =
  let admission =
    if Atomic.get active then
      Eio.Condition.loop_no_mutex queue.space_available (fun () ->
        (* A space broadcast may win the condition's cancellation race. Check
           again before insertion so a cancelled waiter cannot leave a job. *)
        Eio.Fiber.check ();
        try_admit job)
    else
      (* Recheck under the queue lock in case the writer started meanwhile. *)
      match try_admit job with
      | Some admission -> admission
      | None ->
        Eio.Condition.loop_no_mutex queue.space_available (fun () ->
          Eio.Fiber.check ();
          try_admit job)
  in
  match admission with
  | Enqueued -> Eio.Condition.broadcast queue.cond
  | Inline ->
    drain_pending ();
    run_job "inline" job
;;

let run_writer () =
  with_queue (fun () ->
    if Atomic.get active then invalid_arg "IDE ingestion writer already running";
    Atomic.set active true);
  let rec loop () =
    let job =
      Eio.Condition.loop_no_mutex queue.cond (fun () ->
        Eio.Fiber.check ();
        take_nonblocking ())
    in
    run_job "writer" job;
    Eio.Fiber.yield ();
    loop ()
  in
  Fun.protect
    ~finally:(fun () ->
      with_queue (fun () -> Atomic.set active false);
      Eio.Condition.broadcast queue.space_available)
    loop
;;

module For_testing = struct
  let reset ?(capacity_override = default_capacity) () =
    if capacity_override <= 0 then invalid_arg "IDE ingestion capacity must be positive";
    with_queue (fun () ->
      Queue.clear queue.items;
      Atomic.set capacity capacity_override;
      Atomic.set active false);
    Eio.Condition.broadcast queue.cond;
    Eio.Condition.broadcast queue.space_available
  ;;

  let set_active b =
    with_queue (fun () -> Atomic.set active b);
    Eio.Condition.broadcast queue.space_available
end
