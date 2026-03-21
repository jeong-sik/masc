(** Heartbeat - Agent health monitoring

    Extracted from mcp_server_eio.ml for testability.
*)

type t = {
  id: string;
  agent_name: string;
  interval: int;
  message: string;
  mutable active: bool;
  created_at: float;
}

let heartbeats : (string, t) Hashtbl.t = Hashtbl.create 16
let heartbeat_counter = Atomic.make 0
let mu = Eio.Mutex.create ()
let stdlib_mu = Stdlib.Mutex.create ()

let with_lock f =
  try Eio.Mutex.use_rw ~protect:true mu f
  with Effect.Unhandled _ | Eio.Mutex.Poisoned _ ->
    Stdlib.Mutex.lock stdlib_mu;
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock stdlib_mu) f

let generate_id () =
  Atomic.incr heartbeat_counter;
  Printf.sprintf "hb-%d-%d" (int_of_float (Time_compat.now ())) (Atomic.get heartbeat_counter)

let start ~agent_name ~interval ~message =
  with_lock (fun () ->
    let id = generate_id () in
    let hb = { id; agent_name; interval; message; active = true; created_at = Time_compat.now () } in
    Hashtbl.add heartbeats id hb;
    id)

let stop id =
  with_lock (fun () ->
    match Hashtbl.find_opt heartbeats id with
    | Some hb ->
        hb.active <- false;
        Hashtbl.remove heartbeats id;
        true
    | None -> false)

let list () =
  with_lock (fun () ->
    Hashtbl.fold (fun _ hb acc -> hb :: acc) heartbeats [])

let get id =
  with_lock (fun () ->
    Hashtbl.find_opt heartbeats id)

let stop_by_agent ~agent_name =
  with_lock (fun () ->
    let ids_to_remove =
      Hashtbl.fold (fun id hb acc ->
        if hb.agent_name = agent_name then id :: acc else acc
      ) heartbeats []
    in
    List.iter (fun id ->
      (match Hashtbl.find_opt heartbeats id with
       | Some hb -> hb.active <- false
       | None -> ());
      Hashtbl.remove heartbeats id
    ) ids_to_remove;
    List.length ids_to_remove)
