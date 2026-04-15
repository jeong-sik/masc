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

(** Run [f] under [Eio.Mutex] if an Eio context is available, otherwise run
    [f] directly.  This keeps heartbeat operations safe in production (Eio
    scheduler running) while allowing tests that execute outside
    [Eio_main.run] to proceed without [Effect.Unhandled]. *)
let with_mu_safe mode f =
  match mode with
  | `RW -> Eio_guard.with_mutex mu f
  | `RO -> Eio_guard.with_mutex_ro mu f

let generate_id () =
  (* [fetch_and_add] instead of [incr; get] pair — the split version lets two
     fibers both observe the same post-increment counter and produce duplicate
     heartbeat IDs. *)
  let seq = Atomic.fetch_and_add heartbeat_counter 1 + 1 in
  Printf.sprintf "hb-%d-%d" (int_of_float (Time_compat.now ())) seq

let start ~agent_name ~interval ~message =
  with_mu_safe `RW (fun () ->
    let id = generate_id () in
    let hb = { id; agent_name; interval; message; active = true; created_at = Time_compat.now () } in
    Hashtbl.add heartbeats id hb;
    id)

let stop id =
  with_mu_safe `RW (fun () ->
    match Hashtbl.find_opt heartbeats id with
    | Some hb ->
        hb.active <- false;
        Hashtbl.remove heartbeats id;
        true
    | None -> false)

let list () =
  with_mu_safe `RO (fun () ->
    Hashtbl.fold (fun _ hb acc -> hb :: acc) heartbeats [])

let get id =
  with_mu_safe `RO (fun () ->
    Hashtbl.find_opt heartbeats id)

let stop_by_agent ~agent_name =
  with_mu_safe `RW (fun () ->
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
