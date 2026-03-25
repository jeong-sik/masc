(** Keeper_registry — Single source of truth for keeper state.

    Consolidates keeper_keepalive Hashtbl, keeper_resident_supervisor
    Hashtbl, and file-based meta into one registry.

    All operations are serialized via Stdlib.Mutex (safe in Eio's
    cooperative scheduler since operations are non-blocking Hashtbl
    lookups — no I/O under lock). *)

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
let mu = Mutex.create ()

let with_lock f =
  Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock mu) f

let register name meta =
  with_lock (fun () ->
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
  with_lock (fun () -> Hashtbl.remove registry name)

let get name =
  with_lock (fun () -> Hashtbl.find_opt registry name)

let get_exn name =
  match get name with
  | Some e -> e
  | None -> raise Not_found

let all () =
  with_lock (fun () ->
    Hashtbl.fold (fun _k v acc -> v :: acc) registry [])

let update_meta name meta =
  with_lock (fun () ->
    match Hashtbl.find_opt registry name with
    | Some entry -> entry.meta <- meta
    | None -> ())

let set_state name state =
  with_lock (fun () ->
    match Hashtbl.find_opt registry name with
    | Some entry -> entry.state <- state
    | None -> ())

let record_restart name =
  with_lock (fun () ->
    match Hashtbl.find_opt registry name with
    | Some entry -> entry.restart_count <- entry.restart_count + 1
    | None -> ())

let record_error name err =
  with_lock (fun () ->
    match Hashtbl.find_opt registry name with
    | Some entry -> entry.last_error <- Some err
    | None -> ())

let is_running name =
  match get name with
  | Some { state = Running; _ } -> true
  | _ -> false

let count_running () =
  with_lock (fun () ->
    Hashtbl.fold
      (fun _k v acc -> if v.state = Running then acc + 1 else acc)
      registry 0)

let clear () =
  with_lock (fun () -> Hashtbl.clear registry)
