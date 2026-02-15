(** SSE (Server-Sent Events) module for MCP Streamable HTTP Transport
    MCP Spec 2025-03-26 compliant *)

(** Maximum concurrent SSE clients — prevents connection storm on restart.
    Increased from 50 to 200 to handle Claude.ai MCP client reconnections. *)
let max_clients = 200

(** SSE client state *)
type client = {
  id: int;
  push: string -> unit;
  mutable last_event_id: int;
  created_at: float;
  mutable last_seen_at: float;
}

(** Client registry - maps session_id to client *)
let clients : (string, client) Hashtbl.t = Hashtbl.create 16

let mark_seen (client : client) =
  client.last_seen_at <- Time_compat.now ()

(** Monotonic client id for safe replacement/unregister *)
let client_id_counter = Atomic.make 0

(** Global event counter for resumability *)
let event_counter = Atomic.make 0

(** Event buffer for resumability - stores (event_id, event_string) pairs *)
let max_buffer_size = 100
let event_buffer : (int * string) Queue.t = Queue.create ()

(** Add event to buffer, maintaining max size *)
let buffer_event event_id event_str =
  if Queue.length event_buffer >= max_buffer_size then
    ignore (Queue.pop event_buffer);
  Queue.push (event_id, event_str) event_buffer

(** Get events after given ID for replay (MCP spec MUST) *)
let get_events_after last_id =
  Queue.fold (fun acc (id, ev) ->
    if id > last_id then ev :: acc else acc
  ) [] event_buffer
  |> List.rev

(** Format SSE event with optional ID and event type *)
let format_event ?id ?event_type data =
  (* Atomic fetch_and_add: returns old value, we want new value so +1 *)
  let new_id = Atomic.fetch_and_add event_counter 1 + 1 in
  let id_line = Printf.sprintf "id: %d\n"
    (match id with Some i -> i | None -> new_id) in
  let event_line = match event_type with
    | Some e -> Printf.sprintf "event: %s\n" e
    | None -> ""
  in
  Printf.sprintf "%s%sdata: %s\n\n" id_line event_line data

(** Get current event ID *)
let current_id () = Atomic.get event_counter

(** Allocate next event ID without emitting data. *)
let next_id () =
  (* Atomic fetch_and_add: returns old value, we want new value so +1 *)
  Atomic.fetch_and_add event_counter 1 + 1

(** Register a new SSE client.
    Returns (client_id, evicted_session_id option).
    Evicts the oldest client when at capacity. *)
let register session_id ~push ~last_event_id =
  (* Evict oldest if at capacity *)
  let evicted =
    if Hashtbl.length clients >= max_clients then
      let oldest = Hashtbl.fold (fun sid c acc ->
        match acc with
        | None -> Some (sid, c)
        | Some (_, c2) -> if c.created_at < c2.created_at then Some (sid, c) else acc
      ) clients None in
      match oldest with
      | Some (sid, _) ->
          Printf.eprintf "[SSE] Evicting oldest client %s (at cap %d)\n%!" sid max_clients;
          Hashtbl.remove clients sid; Some sid
      | None -> None
    else None
  in
  let now = Time_compat.now () in
  let new_id = Atomic.fetch_and_add client_id_counter 1 + 1 in
  let client = { id = new_id; push; last_event_id; created_at = now; last_seen_at = now } in
  Hashtbl.replace clients session_id client;
  (client.id, evicted)

(** Unregister an SSE client *)
let unregister session_id =
  Hashtbl.remove clients session_id

(** Unregister only if the current client matches the given client_id.
    Prevents an old connection's cleanup from unregistering a newer connection
    that re-used the same session_id. *)
let unregister_if_current session_id client_id =
  match Hashtbl.find_opt clients session_id with
  | Some client when client.id = client_id -> Hashtbl.remove clients session_id
  | _ -> ()

(** Check if client exists *)
let exists session_id =
  Hashtbl.mem clients session_id

(** Mark a client as recently active *)
let touch session_id =
  match Hashtbl.find_opt clients session_id with
  | Some client -> mark_seen client
  | None -> ()

(** Update client's last event ID *)
let update_last_event_id session_id event_id =
  match Hashtbl.find_opt clients session_id with
  | Some client ->
      client.last_event_id <- event_id;
      mark_seen client
  | None -> ()

(** Broadcast event to all connected clients
    Uses snapshot-based iteration to safely remove failed connections *)
let broadcast json =
  let data = Yojson.Safe.to_string json in
  let current_event_id = Atomic.get event_counter + 1 in
  let event = format_event ~id:current_event_id ~event_type:"message" data in
  buffer_event current_event_id event;
  (* Take snapshot first to avoid modifying Hashtbl during iteration *)
  let clients_snapshot = Hashtbl.fold (fun k v acc -> (k, v) :: acc) clients [] in
  let failed = ref [] in
  List.iter (fun (session_id, client) ->
    if current_event_id > client.last_event_id then begin
      match client.push event with
      | () -> update_last_event_id session_id current_event_id
      | exception e ->
        Printf.eprintf "[SSE] Push failed for session %s: %s\n%!" session_id (Printexc.to_string e);
        failed := session_id :: !failed
    end
  ) clients_snapshot;
  (* Remove failed connections after iteration *)
  List.iter (Hashtbl.remove clients) !failed

(** Send a JSON-RPC message to a specific session (legacy SSE transport) *)
let send_to session_id json =
  let data = Yojson.Safe.to_string json in
  let current_event_id = Atomic.get event_counter + 1 in
  let event = format_event ~id:current_event_id ~event_type:"message" data in
  buffer_event current_event_id event;
  match Hashtbl.find_opt clients session_id with
  | None -> ()
  | Some client ->
      (match client.push event with
       | () -> update_last_event_id session_id current_event_id
       | exception e ->
         Printf.eprintf "[SSE] Push to %s failed: %s\n%!" session_id (Printexc.to_string e))

(** Get client count *)
let client_count () =
  Hashtbl.length clients

(** Close all SSE clients - for graceful shutdown
    Returns the number of clients that were closed *)
let close_all_clients () =
  let sessions = Hashtbl.fold (fun sid _ acc -> sid :: acc) clients [] in
  List.iter (Hashtbl.remove clients) sessions;
  List.length sessions

(** Remove clients idle longer than max_age_s (default 30 min).
    Returns list of evicted session_ids so caller can clean up writers. *)
let cleanup_stale ?(max_age_s=1800.0) () =
  let now = Time_compat.now () in
  let stale = Hashtbl.fold (fun sid c acc ->
    if now -. c.last_seen_at > max_age_s then sid :: acc else acc
  ) clients [] in
  List.iter (fun sid ->
    Printf.eprintf "[SSE] idle evict: %s (idle %.0fs)\n%!"
      sid (now -. (Hashtbl.find clients sid).last_seen_at);
    Hashtbl.remove clients sid
  ) stale;
  stale
