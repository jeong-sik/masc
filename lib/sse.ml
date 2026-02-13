(** SSE (Server-Sent Events) module for MCP Streamable HTTP Transport
    MCP Spec 2025-03-26 compliant *)

(** Maximum concurrent SSE clients — prevents connection storm on restart.
    Increased from 50 to 200 to handle Claude.ai MCP client reconnections. *)
let max_clients = 200

(** SSE reconnect storm guard defaults.
    - session cooldown: minimum time between reconnects per session_id
    - global window: max accepted new SSE connections per window *)
let parse_float_env ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      (try float_of_string (String.trim raw) with _ -> default)

let parse_int_env ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      (try int_of_string (String.trim raw) with _ -> default)

let reconnect_min_interval_s =
  max 0.0
    (parse_float_env
       ~name:"MASC_SSE_RECONNECT_MIN_INTERVAL_S"
       ~default:1.0)

let connect_rate_window_s =
  max 0.1
    (parse_float_env
       ~name:"MASC_SSE_CONNECT_WINDOW_S"
       ~default:10.0)

let connect_rate_max_in_window =
  max 1
    (parse_int_env
       ~name:"MASC_SSE_CONNECT_MAX_IN_WINDOW"
       ~default:120)

type admission_reject_reason =
  | Session_cooldown
  | Global_rate_limit

type admission =
  | Allowed
  | Rejected of {
      reason: admission_reject_reason;
      retry_ms: int;
    }

(** Sliding window for accepted SSE connections (storm guard) *)
let accepted_connect_timestamps : float Queue.t = Queue.create ()

(** Last accepted connection time per session_id *)
let last_connect_by_session : (string, float) Hashtbl.t = Hashtbl.create 128

let admission_reason_to_string = function
  | Session_cooldown -> "session_cooldown"
  | Global_rate_limit -> "global_rate_limit"

let retry_ms_of_seconds s =
  max 250 (int_of_float (ceil (s *. 1000.0)))

let rec trim_connect_window ~now ~window_s =
  match Queue.peek_opt accepted_connect_timestamps with
  | Some ts when now -. ts > window_s ->
      ignore (Queue.pop accepted_connect_timestamps);
      trim_connect_window ~now ~window_s
  | _ -> ()

let prune_old_session_connects ~now ~ttl_s =
  if Hashtbl.length last_connect_by_session > (max_clients * 4) then begin
    let stale = Hashtbl.fold (fun sid ts acc ->
      if now -. ts > ttl_s then sid :: acc else acc
    ) last_connect_by_session [] in
    List.iter (Hashtbl.remove last_connect_by_session) stale
  end

let admit_connection_at
    ?(min_interval_s = reconnect_min_interval_s)
    ?(window_s = connect_rate_window_s)
    ?(max_in_window = connect_rate_max_in_window)
    ~now
    session_id
  =
  trim_connect_window ~now ~window_s;
  let prune_ttl_s = max 60.0 (4.0 *. max min_interval_s window_s) in
  prune_old_session_connects ~now ~ttl_s:prune_ttl_s;
  match Hashtbl.find_opt last_connect_by_session session_id with
  | Some last_ts when min_interval_s > 0.0 && now -. last_ts < min_interval_s ->
      let wait_s = min_interval_s -. (now -. last_ts) in
      Rejected { reason = Session_cooldown; retry_ms = retry_ms_of_seconds wait_s }
  | _ when Queue.length accepted_connect_timestamps >= max_in_window ->
      let retry_ms =
        match Queue.peek_opt accepted_connect_timestamps with
        | None -> retry_ms_of_seconds window_s
        | Some oldest_ts ->
            let wait_s = window_s -. (now -. oldest_ts) in
            retry_ms_of_seconds (max 0.0 wait_s)
      in
      Rejected { reason = Global_rate_limit; retry_ms }
  | _ ->
      Queue.push now accepted_connect_timestamps;
      Hashtbl.replace last_connect_by_session session_id now;
      Allowed

let admit_connection session_id =
  admit_connection_at ~now:(Time_compat.now ()) session_id

(** Test helper: clears in-memory storm guard state. *)
let reset_admission_state_for_test () =
  Queue.clear accepted_connect_timestamps;
  Hashtbl.clear last_connect_by_session

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
    (match Hashtbl.find_opt clients sid with
     | Some client ->
         Printf.eprintf "[SSE] idle evict: %s (idle %.0fs)\n%!"
           sid (now -. client.last_seen_at)
     | None -> ());
    Hashtbl.remove clients sid
  ) stale;
  stale
