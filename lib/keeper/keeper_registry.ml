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
  name : string;
  mutable meta : keeper_meta;
  mutable state : keeper_state;
  fiber_stop : bool ref;
  fiber_wakeup : bool ref;
  started_at : float;
  mutable restart_count : int;
  mutable last_error : string option;
}

let state_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Stopped -> "stopped"

let registry : (string, registry_entry) Hashtbl.t = Hashtbl.create 16
let mu = Eio.Mutex.create ()

let with_lock_rw f =
  try Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())
  with Stdlib.Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

let with_lock_ro f =
  try Eio.Mutex.use_ro mu (fun () -> f ())
  with Stdlib.Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

let register name meta =
  with_lock_rw (fun () ->
    let entry = {
      name;
      meta;
      state = Running;
      fiber_stop = ref false;
      fiber_wakeup = ref false;
      started_at = Time_compat.now ();
      restart_count = 0;
      last_error = None;
    } in
    Hashtbl.replace registry name entry;
    entry)

let unregister name =
  with_lock_rw (fun () -> Hashtbl.remove registry name)

let get name =
  with_lock_ro (fun () -> Hashtbl.find_opt registry name)

let get_exn name =
  match get name with
  | Some e -> e
  | None -> raise Not_found

let all () =
  with_lock_ro (fun () ->
    Hashtbl.fold (fun _k v acc -> v :: acc) registry [])

let update_meta name meta =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry name with
    | Some entry -> entry.meta <- meta
    | None -> ())

let set_state name state =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry name with
    | Some entry -> entry.state <- state
    | None -> ())

let record_restart name =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry name with
    | Some entry -> entry.restart_count <- entry.restart_count + 1
    | None -> ())

let record_error name err =
  with_lock_rw (fun () ->
    match Hashtbl.find_opt registry name with
    | Some entry -> entry.last_error <- Some err
    | None -> ())

let is_running name =
  match get name with
  | Some { state = Running; _ } -> true
  | _ -> false

let count_running () =
  with_lock_ro (fun () ->
    Hashtbl.fold
      (fun _k v acc -> if v.state = Running then acc + 1 else acc)
      registry 0)

let clear () =
  with_lock_rw (fun () -> Hashtbl.clear registry)
