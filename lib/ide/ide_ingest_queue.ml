(** Bounded, drop-oldest ingestion queue for IDE observation events.
    See ide_ingest_queue.mli for the rationale. *)

type job = unit -> unit

let default_capacity = 1024

(* Drop threshold. The backing stream is created a little larger than the
   threshold so a drop-then-add on the hot path always has buffer room and
   never suspends the enqueuing (keeper turn) fiber. *)
let stream_headroom = 64

let capacity = ref default_capacity
let queue : job Eio.Stream.t ref = ref (Eio.Stream.create (default_capacity + stream_headroom))
let active = Atomic.make false
let dropped = Atomic.make 0

let dropped_count () = Atomic.get dropped
let depth () = Eio.Stream.length !queue

let run_job label job =
  try job () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Printf.eprintf "Ide_ingest_queue.%s: job failed: %s\n%!" label (Printexc.to_string exn)
;;

let submit (job : job) : unit =
  if Atomic.get active
  then (
    let q = !queue in
    (* Drop the oldest queued job when at capacity so the enqueue below has
       room and cannot block. take_nonblocking removes the oldest entry. *)
    if Eio.Stream.length q >= !capacity
    then (
      match Eio.Stream.take_nonblocking q with
      | Some _ -> Atomic.incr dropped
      | None -> ());
    Eio.Stream.add q job)
  else
    (* No writer installed (tests, pre-bootstrap): preserve the previous
       synchronous behavior by running the job inline. *)
    run_job "inline" job
;;

let drain_pending () =
  let rec loop () =
    match Eio.Stream.take_nonblocking !queue with
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
    let job = Eio.Stream.take !queue in
    run_job "writer" job;
    loop ()
  in
  loop ()
;;

module For_testing = struct
  let reset ?(capacity_override = default_capacity) () =
    capacity := capacity_override;
    queue := Eio.Stream.create (capacity_override + stream_headroom);
    Atomic.set active false;
    Atomic.set dropped 0
  ;;

  let set_active b = Atomic.set active b
  let is_active () = Atomic.get active
end
