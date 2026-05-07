(** Keeper_recurring — In-memory recurring task registry.

    Thread-safe via Eio.Mutex guarded by Eio_guard (falls through
    without locking when Eio runtime is not yet active, e.g. in
    non-Eio tests or module init).

    @since #3190 *)

type action =
  | Broadcast of string

type recurring_task = {
  id : string;
  keeper_name : string;
  label : string;
  interval_sec : int;
  action : action;
  mutable last_run_ts : float;
  mutable run_count : int;
  mutable failure_count : int;
  max_failures : int;
  mutable enabled : bool;
}

(* ================================================================ *)
(* Storage                                                           *)
(* ================================================================ *)

let tasks : (string, recurring_task) Hashtbl.t = Hashtbl.create 16

(** Mutex protecting [tasks] and [id_counter].  The module header and
    [.mli] advertise thread-safety, but the previous implementation had
    no serialisation — [Hashtbl.replace]/[remove]/[fold] ran from every
    keeper heartbeat loop concurrently, and [id_counter] used the
    [incr; !] split pattern that lets two fibers observe the same
    post-increment value and emit duplicate task IDs.  Use
    [Eio_guard.with_mutex] so code paths that run before [Eio_main.run]
    (module init, non-Eio tests) still work without triggering
    [Effect.Unhandled]. *)
let tasks_mu = Eio.Mutex.create ()
let with_tasks_rw f = Eio_guard.with_mutex tasks_mu f
let with_tasks_ro f = Eio_guard.with_mutex_ro tasks_mu f

(* ================================================================ *)
(* ID generation                                                     *)
(* ================================================================ *)

let id_counter = Atomic.make 0

let generate_id () =
  (* [fetch_and_add] returns the pre-increment value; +1 gives the
     fresh ticket.  Prevents the [incr; !] race where two fibers read
     the same post-increment value and produce duplicate IDs within
     the same millisecond. *)
  let seq = Atomic.fetch_and_add id_counter 1 + 1 in
  let ts = int_of_float (Unix.gettimeofday () *. 1000.0) mod 100_000 in
  Printf.sprintf "loop-%d-%d" ts seq

(* ================================================================ *)
(* CRUD                                                              *)
(* ================================================================ *)

let add ~keeper_name ~label ~interval_sec ?(max_failures = 5) action =
  let id = generate_id () in
  let task = {
    id; keeper_name; label; interval_sec; action;
    last_run_ts = 0.0; run_count = 0; failure_count = 0;
    max_failures; enabled = true;
  } in
  with_tasks_rw (fun () -> Hashtbl.replace tasks id task);
  task

let remove ~id =
  with_tasks_rw (fun () ->
    if Hashtbl.mem tasks id then begin
      Hashtbl.remove tasks id; true
    end else false)

let list ~keeper_name =
  with_tasks_ro (fun () ->
    Hashtbl.fold (fun _id task acc ->
      if task.keeper_name = keeper_name then task :: acc else acc
    ) tasks [])

let list_all () =
  with_tasks_ro (fun () ->
    Hashtbl.fold (fun _id task acc -> task :: acc) tasks [])

let record_failure ~task ~phase =
  Prometheus.inc_counter
    Prometheus.metric_keeper_recurring_failures
    ~labels:[("task", task.id); ("phase", phase)]
    ()

(* ================================================================ *)
(* Dispatch                                                          *)
(* ================================================================ *)

let dispatch_due ~keeper_name ~now_ts ~dispatch =
  (* Snapshot due tasks under the lock so [add]/[remove] cannot mutate
     the table while we iterate; then release the lock before invoking
     [dispatch], which runs arbitrary user code that may yield or call
     back into this module. *)
  let due_tasks =
    with_tasks_ro (fun () ->
      Hashtbl.fold (fun _id task acc ->
        if task.keeper_name = keeper_name
           && task.enabled
           && now_ts -. task.last_run_ts >= float_of_int task.interval_sec
        then task :: acc
        else acc
      ) tasks [])
  in
  let count = ref 0 in
  List.iter (fun task ->
    match dispatch task task.action with
    | Ok () ->
      task.last_run_ts <- now_ts;
      task.run_count <- task.run_count + 1;
      task.failure_count <- 0;
      incr count
    | Error _msg ->
      task.failure_count <- task.failure_count + 1;
      if task.max_failures > 0
         && task.failure_count >= task.max_failures
      then begin
        task.enabled <- false;
        record_failure ~task ~phase:"auto_disable"
      end
  ) due_tasks;
  !count

(* ================================================================ *)
(* Re-enable                                                         *)
(* ================================================================ *)

(* Re-enable disabled recurring tasks for [keeper_name] whose
   [last_run_ts] is older than [2 * interval_sec].  Without this,
   tasks auto-disabled by [dispatch_due]'s [max_failures] guard
   never return to [enabled = true] within the process lifetime,
   permanently silencing the keeper's heartbeat broadcasts and
   eventually triggering stale-kill cascades across dependent
   keepers. *)
let reenable_due_tasks ~keeper_name ~now_ts =
  let count = ref 0 in
  with_tasks_rw (fun () ->
    Hashtbl.iter (fun _id task ->
      if task.keeper_name = keeper_name && not task.enabled then begin
        let cooldown = float_of_int task.interval_sec *. 2.0 in
        if now_ts -. task.last_run_ts >= cooldown then begin
          task.enabled <- true;
          task.failure_count <- 0;
          incr count
        end
      end
    ) tasks);
  !count

(* ================================================================ *)
(* Serialization                                                     *)
(* ================================================================ *)

let action_to_json = function
  | Broadcast msg -> `Assoc [("type", `String "broadcast"); ("message", `String msg)]

let task_to_json (t : recurring_task) : Yojson.Safe.t =
  `Assoc [
    ("id", `String t.id);
    ("keeper_name", `String t.keeper_name);
    ("label", `String t.label);
    ("interval_sec", `Int t.interval_sec);
    ("action", action_to_json t.action);
    ("last_run_ts", `Float t.last_run_ts);
    ("run_count", `Int t.run_count);
    ("failure_count", `Int t.failure_count);
    ("max_failures", `Int t.max_failures);
    ("enabled", `Bool t.enabled);
  ]

(* ================================================================ *)
(* Testing                                                           *)
(* ================================================================ *)

let clear () =
  with_tasks_rw (fun () -> Hashtbl.clear tasks)
