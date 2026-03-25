(** Keeper_registry — Single source of truth for keeper state.

    Consolidates keeper_keepalive Hashtbl, keeper_resident_supervisor
    Hashtbl, and file-based meta into one registry.

    All operations are serialized via Eio.Mutex (allows other fibers
    to run while waiting, unlike Stdlib.Mutex which blocks the domain).
    Falls back to unprotected access in non-Eio test contexts. *)

open Keeper_types

type keeper_state =
  | Running
  | Paused
  | Stopped

type registry_entry = {
  base_path : string;
  name : string;
  mutable meta : keeper_meta;
  mutable state : keeper_state;
  fiber_stop : bool ref;
  fiber_wakeup : bool ref;
  started_at : float;
  grpc_close : (unit -> unit) option ref;
  done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t;
  done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u;
  mutable restart_count : int;
  mutable last_restart_ts : float;
  mutable crash_log : (float * string) list;
  mutable last_error : string option;
}

let state_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Stopped -> "stopped"

let registry : (string, registry_entry) Hashtbl.t = Hashtbl.create 16
let mu = Eio.Mutex.create ()

let registry_key ~base_path name =
  base_path ^ "\x1f" ^ name

let with_lock_rw f =
  try Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())
  with Stdlib.Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

let with_lock_ro f =
  try Eio.Mutex.use_ro mu (fun () -> f ())
  with Stdlib.Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

let max_crash_log_entries = 5

let register ~base_path name meta =
  with_lock_rw (fun () ->
    let done_p, done_r = Eio.Promise.create () in
    let entry = {
      base_path;
      name;
      meta;
      state = Running;
      fiber_stop = ref false;
      fiber_wakeup = ref false;
      started_at = Time_compat.now ();
      grpc_close = ref None;
      done_p;
      done_r;
      restart_count = 0;
      last_restart_ts = 0.0;
      crash_log = [];
      last_error = None;
    } in
    Hashtbl.replace registry (registry_key ~base_path name) entry;
    entry)

let unregister ~base_path name =
  with_lock_rw (fun () -> Hashtbl.remove registry (registry_key ~base_path name))

let get ~base_path name =
  with_lock_ro (fun () -> Hashtbl.find_opt registry (registry_key ~base_path name))

let get_exn ~base_path name =
  match get ~base_path name with
  | Some e -> e
  | None -> raise Not_found

let all ?base_path () =
  with_lock_ro (fun () ->
    Hashtbl.fold
      (fun _k v acc ->
        match base_path with
        | Some expected when not (String.equal expected v.base_path) -> acc
        | _ -> v :: acc)
      registry [])

let update_meta ~base_path name meta =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.meta <- meta
    | None -> ())

let set_state ~base_path name state =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.state <- state
    | None -> ())

let record_restart ~base_path name =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry ->
        entry.restart_count <- entry.restart_count + 1;
        entry.last_restart_ts <- Time_compat.now ()
    | None -> ())

let record_error ~base_path name err =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.last_error <- Some err
    | None -> ())

let is_running ~base_path name =
  match get ~base_path name with
  | Some { state = Running; _ } -> true
  | _ -> false

let count_running ?base_path () =
  with_lock_ro (fun () ->
    Hashtbl.fold
      (fun _k v acc ->
        match base_path with
        | Some expected when not (String.equal expected v.base_path) -> acc
        | _ -> if v.state = Running then acc + 1 else acc)
      registry 0)

let record_crash ~base_path name ts msg =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry ->
        let log = (ts, msg) :: entry.crash_log in
        entry.crash_log <-
          (if List.length log <= max_crash_log_entries then log
           else List.filteri (fun i _ -> i < max_crash_log_entries) log)
    | None -> ())

let set_grpc_close ~base_path name close_fn =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.grpc_close := close_fn
    | None -> ())

let started_at ~base_path name =
  match get ~base_path name with
  | Some entry -> Some entry.started_at
  | None -> None

let spawn_slots_available () =
  let max_keepers = Env_config.KeeperBootstrap.max_active_keepers in
  max_keepers <= 0
  || with_lock_ro (fun () -> Hashtbl.length registry < max_keepers)

let wakeup ~base_path name =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry (registry_key ~base_path name) with
    | Some entry -> entry.fiber_wakeup := true
    | None -> ())

let wakeup_all ?base_path () =
  with_lock_rw (fun () ->
    Hashtbl.iter (fun _k entry ->
      (match base_path with
       | Some expected when not (String.equal expected entry.base_path) -> ()
       | _ -> if entry.state = Running then entry.fiber_wakeup := true)
    ) registry)

let fiber_health_of ~base_path name =
  match get ~base_path name with
  | None -> Fiber_unknown
  | Some entry ->
      match Eio.Promise.peek entry.done_p with
      | None -> Fiber_alive
      | Some `Stopped -> Fiber_unknown
      | Some (`Crashed _) ->
          let max_restarts = Env_config.KeeperResidentSupervisor.max_restarts in
          if entry.restart_count >= max_restarts
          then Fiber_dead
          else Fiber_zombie

let crash_log_of ~base_path name =
  match get ~base_path name with
  | Some entry -> entry.crash_log
  | None -> []

let clear () =
  with_lock_rw (fun () -> Hashtbl.clear registry)
