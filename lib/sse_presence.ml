(** Sse_presence — independent SSE channel for awareness/presence traffic.

    Mirrors the lock-free registry + per-session mailbox + bounded ring
    buffer pattern from {!Sse}, but owns separate state.  Heartbeat-class
    publishers in PR-1.7a-2 will dual-emit to both channels; this module
    is the consumer-side half.  Until the HTTP route in PR-1.7a-1-β
    wires up actual subscribers, [register] / [broadcast] are exercised
    only by tests, which is intentional — see RFC sec 4.4 stage 1. *)

module SMap = Map.Make (String)

type client = {
  id : int;
  event_stream : string Eio.Stream.t;
  last_event_id : int Atomic.t;
  created_at : float;
  last_seen_at : float Atomic.t;
}

type client_registry_state = {
  entries : client SMap.t;
  count : int;
}

(** Reuse the same operational caps as {!Sse}.  Presence has lighter
    payload (heartbeat tick) so a tighter limit is possible later, but
    matching the main channel keeps capacity-planning predictable. *)
let max_clients = 200

let stream_capacity = 64

let max_buffer_size = 100

let buffer_ttl_seconds = Env_config.InternalTimers.sse_buffer_ttl_sec

let empty_client_registry_state = { entries = SMap.empty; count = 0 }

let clients : client_registry_state Atomic.t =
  Atomic.make empty_client_registry_state

let client_id_counter = Atomic.make 0

(** Independent of {!Sse.event_counter}: presence subscribers track
    their own [Last-Event-Id]. *)
let event_counter = Atomic.make 0

let event_buffer : (int * string * float) list Atomic.t = Atomic.make []

let take n xs =
  let rec loop acc remaining items =
    match (remaining, items) with
    | remaining, _ when remaining <= 0 -> List.rev acc
    | _, [] -> List.rev acc
    | _, x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n xs

let buffer_event event_id event_str =
  Lockfree_atomic.update_with_commit event_buffer (fun lst ->
      let timestamp = Time_compat.now () in
      let next = (event_id, event_str, timestamp) :: lst in
      let trimmed =
        if List.length next > max_buffer_size then take max_buffer_size next
        else next
      in
      { next_state = trimmed; result = () })

let get_events_after last_id =
  let lst = Atomic.get event_buffer in
  List.fold_left
    (fun acc (id, ev, _ts) -> if id > last_id then ev :: acc else acc)
    [] lst

let cleanup_expired_events () =
  let now = Time_compat.now () in
  Lockfree_atomic.update_with_commit event_buffer (fun lst ->
      let remaining_oldest_first, evicted =
        List.fold_left
          (fun (kept, evicted) (((_id, _ev, ts) as item) : int * string * float) ->
            if now -. ts > buffer_ttl_seconds then (kept, evicted + 1)
            else (item :: kept, evicted))
          ([], 0) lst
      in
      { next_state = List.rev remaining_oldest_first; result = evicted })

let current_id () = Atomic.get event_counter

let next_id () = Atomic.fetch_and_add event_counter 1 + 1

let mark_seen (client : client) =
  Atomic.set client.last_seen_at (Time_compat.now ())

let register session_id ~last_event_id =
  let client_id = Atomic.fetch_and_add client_id_counter 1 + 1 in
  let last_event_id = Atomic.make last_event_id in
  let event_stream = Eio.Stream.create stream_capacity in
  let base_client =
    {
      id = client_id;
      event_stream;
      last_event_id;
      created_at = 0.0;
      last_seen_at = Atomic.make 0.0;
    }
  in
  let evicted =
    Lockfree_atomic.update_with_commit clients (fun state ->
        let evicted =
          if state.count >= max_clients
             && not (SMap.mem session_id state.entries)
          then
            let oldest =
              SMap.fold
                (fun sid existing acc ->
                  match acc with
                  | None -> Some (sid, existing)
                  | Some (_, current_oldest) ->
                      if existing.created_at < current_oldest.created_at
                      then Some (sid, existing)
                      else acc)
                state.entries None
            in
            Option.map fst oldest
          else None
        in
        let entries_after_eviction =
          match evicted with
          | Some sid -> SMap.remove sid state.entries
          | None -> state.entries
        in
        let install_time = Time_compat.now () in
        let client =
          {
            base_client with
            created_at = install_time;
            last_seen_at = Atomic.make install_time;
          }
        in
        let next_entries =
          SMap.add session_id client entries_after_eviction
        in
        {
          next_state =
            {
              entries = next_entries;
              count = SMap.cardinal next_entries;
            };
          result = evicted;
        })
  in
  (match evicted with
   | Some sid ->
       Log.Server.info
         "Evicting oldest presence client %s (at cap %d)" sid max_clients
   | None -> ());
  (client_id, event_stream, evicted)

let unregister session_id =
  Lockfree_atomic.update_with_commit clients (fun state ->
      if SMap.mem session_id state.entries then
        let next_entries = SMap.remove session_id state.entries in
        {
          next_state = { entries = next_entries; count = state.count - 1 };
          result = ();
        }
      else { next_state = state; result = () })

let unregister_if_current session_id client_id =
  Lockfree_atomic.update_with_commit clients (fun state ->
      match SMap.find_opt session_id state.entries with
      | Some client when client.id = client_id ->
          let next_entries = SMap.remove session_id state.entries in
          {
            next_state =
              { entries = next_entries; count = state.count - 1 };
            result = ();
          }
      | _ -> { next_state = state; result = () })

let exists session_id = SMap.mem session_id (Atomic.get clients).entries

let touch session_id =
  match SMap.find_opt session_id (Atomic.get clients).entries with
  | Some client -> mark_seen client
  | None -> ()

let update_last_event_id session_id event_id =
  match SMap.find_opt session_id (Atomic.get clients).entries with
  | Some client -> Atomic.set client.last_event_id event_id
  | None -> ()

let all_session_ids () =
  SMap.fold
    (fun sid _client acc -> sid :: acc)
    (Atomic.get clients).entries []

let client_count () = (Atomic.get clients).count

let close_all_clients () =
  Lockfree_atomic.update_with_commit clients (fun state ->
      let count = state.count in
      { next_state = empty_client_registry_state; result = count })

let broadcast json =
  let data = Yojson.Safe.to_string json in
  let current_event_id = next_id () in
  let event = Sse.format_event ~id:current_event_id ~event_type:"message" data in
  buffer_event current_event_id event;
  let clients_entries = (Atomic.get clients).entries in
  let failed = ref [] in
  SMap.iter
    (fun session_id client ->
      if current_event_id > Atomic.get client.last_event_id then
        let queue_len = Eio.Stream.length client.event_stream in
        if queue_len >= stream_capacity then begin
          Log.Server.warn
            "Presence broadcast skip: session %s stream full (%d/%d)"
            session_id queue_len stream_capacity;
          failed := session_id :: !failed
        end
        else
          try
            Eio.Stream.add client.event_stream event;
            Atomic.set client.last_event_id current_event_id;
            mark_seen client
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | e ->
              Log.Server.error
                "Presence broadcast enqueue failed for session %s: %s"
                session_id (Printexc.to_string e);
              failed := session_id :: !failed)
    clients_entries;
  List.iter (fun sid -> unregister sid) !failed

let pop session_id =
  match SMap.find_opt session_id (Atomic.get clients).entries with
  | None -> None
  | Some client -> Some (Eio.Stream.take client.event_stream)

let try_pop session_id =
  match SMap.find_opt session_id (Atomic.get clients).entries with
  | None -> None
  | Some client -> Eio.Stream.take_nonblocking client.event_stream
