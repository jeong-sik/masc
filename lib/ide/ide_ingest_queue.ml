(** Bounded, drop-oldest ingestion queue for IDE observation events.
    See ide_ingest_queue.mli for the rationale. *)

type job = unit -> unit

let default_capacity = 1024
let active = Atomic.make false
let dropped = Atomic.make 0

type queue_state =
  { mu : Stdlib.Mutex.t
  ; cond : Eio.Condition.t
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
  ; items = Queue.create ()
  }

let with_queue f =
  Stdlib.Mutex.lock queue.mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock queue.mu) f
;;

let dropped_count () = Atomic.get dropped
let depth () = with_queue (fun () -> Queue.length queue.items)

let run_job label job =
  try job () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Ide.error "ingest_queue %s: job failed: %s" label (Printexc.to_string exn)
;;

let submit (job : job) : unit =
  if Atomic.get active
  then (
    with_queue (fun () ->
      (* Keep the bound and the enqueue in one short critical section. This is
         intentionally a Stdlib.Mutex rather than Eio.Mutex because submit can
         be reached from pre-Eio/test contexts, and the protected work never
         performs I/O or suspends. *)
      if Queue.length queue.items >= Atomic.get capacity
      then (
        (* See [dropped]: eviction is intentional for the bounded newest-job queue. *)
        ignore (Queue.take_opt queue.items : job option);
        Atomic.incr dropped);
      Queue.add job queue.items);
    Eio.Condition.broadcast queue.cond)
  else
    (* No writer installed (tests, pre-bootstrap): preserve the previous
       synchronous behavior by running the job inline. *)
    run_job "inline" job
;;

let take_nonblocking () =
  with_queue (fun () -> Queue.take_opt queue.items)
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

let run_writer () =
  Atomic.set active true;
  let rec loop () =
    let job = Eio.Condition.loop_no_mutex queue.cond take_nonblocking in
    run_job "writer" job;
    Eio.Fiber.yield ();
    loop ()
  in
  loop ()
;;

module For_testing = struct
  let reset ?(capacity_override = default_capacity) () =
    with_queue (fun () ->
      Queue.clear queue.items);
    Atomic.set capacity capacity_override;
    Atomic.set active false;
    Atomic.set dropped 0;
    Eio.Condition.broadcast queue.cond
  ;;

  let set_active b = Atomic.set active b
end
