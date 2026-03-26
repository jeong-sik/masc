(** Keeper_recurring — In-memory recurring task registry.

    Thread-safe via Eio_guard.with_mutex (uses Eio.Mutex when runtime
    is active, runs unguarded in single-threaded contexts such as tests).

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

let mu = Eio.Mutex.create ()
let tasks : (string, recurring_task) Hashtbl.t = Hashtbl.create 16

let with_lock f =
  Eio_guard.with_mutex mu f

(* ================================================================ *)
(* ID generation                                                     *)
(* ================================================================ *)

let id_counter = ref 0

let generate_id () =
  incr id_counter;
  let ts = int_of_float (Unix.gettimeofday () *. 1000.0) mod 100_000 in
  Printf.sprintf "loop-%d-%d" ts !id_counter

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
  with_lock (fun () -> Hashtbl.replace tasks id task);
  task

let remove ~id =
  with_lock (fun () ->
    if Hashtbl.mem tasks id then begin
      Hashtbl.remove tasks id; true
    end else false)

let list ~keeper_name =
  with_lock (fun () ->
    Hashtbl.fold (fun _id task acc ->
      if task.keeper_name = keeper_name then task :: acc else acc
    ) tasks [])

let list_all () =
  with_lock (fun () ->
    Hashtbl.fold (fun _id task acc -> task :: acc) tasks [])

(* ================================================================ *)
(* Dispatch                                                          *)
(* ================================================================ *)

let dispatch_due ~keeper_name ~now_ts ~dispatch =
  let due_tasks = with_lock (fun () ->
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
      with_lock (fun () ->
        task.last_run_ts <- now_ts;
        task.run_count <- task.run_count + 1;
        task.failure_count <- 0);
      incr count
    | Error _msg ->
      with_lock (fun () ->
        task.failure_count <- task.failure_count + 1;
        if task.max_failures > 0
           && task.failure_count >= task.max_failures
        then task.enabled <- false)
  ) due_tasks;
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
  with_lock (fun () -> Hashtbl.clear tasks)
