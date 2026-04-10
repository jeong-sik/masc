(** Activity_graph_registry — SSE client registry (Hashtbl + Eio.Mutex). *)

open Activity_graph_types

type client = {
  client_id : int;
  push : string -> unit;
  kind_filters : string list;
  mutable last_seq : int;
  created_at : float;
}

let clients : (string, client) Hashtbl.t = Hashtbl.create 16
let registry_mutex = Eio.Mutex.create ()
let client_count_atomic = Atomic.make 0
let client_id_counter = Atomic.make 0

let with_registry_rw f =
  if Eio_guard.is_ready () then
    (try Eio.Mutex.use_rw ~protect:true registry_mutex f
     with Eio.Cancel.Cancelled _ as exn -> raise exn)
  else f ()

let with_registry_ro f =
  if Eio_guard.is_ready () then
    (try Eio.Mutex.use_ro registry_mutex f
     with Eio.Cancel.Cancelled _ as exn -> raise exn)
  else f ()

let client_matches (client : client) (value : event) =
  match client.kind_filters with
  | [] -> true
  | filters -> List.mem value.kind filters

let register session_id ~push ~last_seq ?(kind_filters = []) () =
  with_registry_rw (fun () ->
      let created_at = Time_compat.now () in
      let client_id = Atomic.fetch_and_add client_id_counter 1 + 1 in
      let client =
        {
          client_id;
          push;
          kind_filters;
          last_seq;
          created_at;
        }
      in
      let existed = Hashtbl.mem clients session_id in
      Hashtbl.replace clients session_id client;
      if not existed then Atomic.incr client_count_atomic;
      client_id)

let unregister session_id =
  with_registry_rw (fun () ->
      if Hashtbl.mem clients session_id then begin
        Hashtbl.remove clients session_id;
        Atomic.decr client_count_atomic
      end)

let unregister_if_current session_id client_id =
  with_registry_rw (fun () ->
      match Hashtbl.find_opt clients session_id with
      | Some client when client.client_id = client_id ->
          Hashtbl.remove clients session_id;
          Atomic.decr client_count_atomic
      | _ -> ())

let client_count () = Atomic.get client_count_atomic
