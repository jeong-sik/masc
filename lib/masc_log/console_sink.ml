(* Console mirror sink — decouples per-record console output from the
   producing domain.

   Every log record used to reach the console via a direct
   [Printf.eprintf "...%!"] on the calling fiber. With fd 2 on a pty, a
   full pty buffer (terminal scrollback, copy-mode selection, slow
   renderer) blocks [write(2)] OUTSIDE the Eio scheduler and halts the
   entire domain — observed live on 2026-06-10 11:26-11:28 KST as a
   fleet-wide ~60 s stall whose log lines were stamped at write time and
   burst out only after the terminal was released (issue #20684).

   Contract:
   - The console is a convenience MIRROR. The JSONL file sink
     ([Log.Persist.write_to_sink]) and the in-memory ring stay
     authoritative and lossless.
   - Before [start] (tests, CLI one-shots, pre-boot), [write] stays
     synchronous — identical to the historical behavior.
   - After [start], [write] enqueues into a bounded queue drained by a
     dedicated OS thread; the thread alone performs the possibly-blocking
     fd write. When the writer is blocked long enough to fill the queue,
     incoming MIRROR lines are dropped and counted; a marker line
     reporting the drop count is emitted once the writer unblocks. *)

let capacity = 8192
let queue : string Queue.t = Queue.create ()
let mu = Mutex.create ()
let cond = Condition.create ()
let enqueue_active = Atomic.make false
let thread_spawned = Atomic.make false
let dropped = Atomic.make 0

(* Test seam: the possibly-blocking line writer. Production default is
   stderr + flush, matching the historical [Printf.eprintf "%s\n%!"]. *)
let stderr_write line =
  output_string stderr (line ^ "\n");
  flush stderr

let writer_override : (string -> unit) option Atomic.t = Atomic.make None

let current_writer () =
  match Atomic.get writer_override with
  | Some w -> w
  | None -> stderr_write

let write_batch ~last_reported_drops batch =
  Queue.iter
    (fun line ->
       try current_writer () line with
       | _ ->
         (* A failing console writer must never take the process down;
            the file sink still has the record. *)
         ())
    batch;
  let d = Atomic.get dropped in
  if d > !last_reported_drops
  then begin
    (try
       current_writer ()
         (Printf.sprintf
            "[console-sink] dropped %d console line(s) while the console writer \
             was blocked (file sink unaffected)"
            (d - !last_reported_drops))
     with
     | _ -> ());
    last_reported_drops := d
  end

let take_batch_blocking () =
  Mutex.lock mu;
  while Queue.is_empty queue do
    Condition.wait cond mu
  done;
  let batch = Queue.create () in
  Queue.transfer queue batch;
  Mutex.unlock mu;
  batch

let writer_loop () =
  let last_reported_drops = ref 0 in
  while true do
    let batch = take_batch_blocking () in
    write_batch ~last_reported_drops batch
  done

let start () =
  Atomic.set enqueue_active true;
  if Atomic.compare_and_set thread_spawned false true
  then ignore (Thread.create writer_loop () : Thread.t)

let dropped_count () = Atomic.get dropped

let queue_depth () =
  Mutex.lock mu;
  let n = Queue.length queue in
  Mutex.unlock mu;
  n

let write line =
  if not (Atomic.get enqueue_active)
  then current_writer () line
  else begin
    Mutex.lock mu;
    let full = Queue.length queue >= capacity in
    if not full
    then begin
      Queue.add line queue;
      Condition.signal cond
    end;
    Mutex.unlock mu;
    if full then ignore (Atomic.fetch_and_add dropped 1 : int)
  end

module For_testing = struct
  let set_writer w = Atomic.set writer_override w

  (* Enqueue mode without the OS thread, so tests drain deterministically. *)
  let set_enqueue_active v = Atomic.set enqueue_active v

  let queued_count () =
    Mutex.lock mu;
    let n = Queue.length queue in
    Mutex.unlock mu;
    n

  let drain_now () =
    Mutex.lock mu;
    let batch = Queue.create () in
    Queue.transfer queue batch;
    Mutex.unlock mu;
    let n = Queue.length batch in
    write_batch ~last_reported_drops:(ref (Atomic.get dropped)) batch;
    n

  let reset () =
    Mutex.lock mu;
    Queue.clear queue;
    Mutex.unlock mu;
    Atomic.set enqueue_active false;
    Atomic.set dropped 0;
    Atomic.set writer_override None
end
