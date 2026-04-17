(** SSE (Server-Sent Events) module for MCP Streamable HTTP Transport
    MCP Spec 2025-03-26 compliant

    Concurrency model (per-session stream):
    Each registered client owns an [Eio.Stream.t] mailbox.
    [broadcast] and [send_to] push formatted SSE strings into per-client
    streams under a read-only registry snapshot -- no global write-lock
    during fan-out.  Each SSE connection fiber drains its own stream via
    [pop], calling the transport-layer write independently.

    Session registries use immutable maps behind [Atomic.t] CAS loops.
    Broadcast fan-out runs over a snapshot and never holds a global lock
    while enqueueing per-client events.

    Session kinds:
    [Observer] sessions receive dashboard snapshots but not agent
    coordination traffic.  [Coordinator] sessions receive heartbeats
    and task events but not dashboard snapshots.  [broadcast_to All]
    reaches every session (backward-compatible with the old [broadcast]).

    Signal handler safety: registry operations avoid [Eio.Mutex] and rely on
    immutable snapshots plus CAS, so readers can inspect counts without
    waiting on a lock held by another fiber. *)

(** Classification of an SSE session's traffic role. *)
module SMap = Map.Make(String)

type ('state, 'result) atomic_commit = {
  next_state : 'state;
  result : 'result;
}

let rec atomic_update_result atomic f =
  let old_state = Atomic.get atomic in
  let { next_state; result } = f old_state in
  if Atomic.compare_and_set atomic old_state next_state then result
  else atomic_update_result atomic f

type session_kind =
  | Observer     (** Dashboard / read-only viewers *)
  | Coordinator  (** MCP agent connections *)

(** Broadcast targeting selector. *)
type broadcast_target =
  | All          (** Every connected session (backward-compatible default) *)
  | Observers    (** Only [Observer] sessions *)
  | Coordinators (** Only [Coordinator] sessions *)

(** Maximum concurrent SSE clients -- prevents connection storm on restart.
    Increased from 50 to 200 to handle Claude.ai MCP client reconnections. *)
let max_clients = 200

(** Per-client event stream capacity.
    Must be > 0 to avoid synchronous rendez-vous semantics
    (Eio.Stream.create 0 blocks add until a matching take).
    64 events at 3-10s intervals covers 3-10 minutes of buffering.
    A client that falls this far behind should reconnect. *)
let stream_capacity = 64

(** SSE client state.
    [event_stream] is the per-session mailbox.  [broadcast] pushes here;
    the SSE connection fiber pops and writes to the HTTP body writer. *)
type client = {
  id: int;
  kind: session_kind;
  event_stream: string Eio.Stream.t;
  push: string -> unit;  (** legacy direct-push callback (used by drain) *)
  last_event_id: int Atomic.t;
  created_at: float;
  last_seen_at: float Atomic.t;
}

type client_registry_state = {
  entries : client SMap.t;
  count : int;
}

(** Client registry - maps session_id to client plus a linearized count. *)
let empty_client_registry_state = {
  entries = SMap.empty;
  count = 0;
}

let clients : client_registry_state Atomic.t =
  Atomic.make empty_client_registry_state

type session_snapshot = {
  session_id : string;
  kind : session_kind;
  queue_depth : int;
  last_event_id : int;
  idle_seconds : float;
}

let session_kind_to_string = function
  | Observer -> "observer"
  | Coordinator -> "coordinator"

let take n xs =
  let rec loop acc remaining items =
    match (remaining, items) with
    | remaining, _ when remaining <= 0 -> List.rev acc
    | _, [] -> List.rev acc
    | remaining, x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n xs

let sync_transport_snapshot () =
  let now = Time_compat.now () in
  let snapshot =
    SMap.fold
      (fun sid client acc -> (sid, client) :: acc)
      (Atomic.get clients).entries []
  in
  let observer = ref 0 in
  let coordinator = ref 0 in
  let queue_sum = ref 0 in
  let max_queue_depth = ref 0 in
  let sessions =
    List.map
      (fun (session_id, client) ->
        let queue_depth = Eio.Stream.length client.event_stream in
        queue_sum := !queue_sum + queue_depth;
        max_queue_depth := max !max_queue_depth queue_depth;
        (match client.kind with
         | Observer -> incr observer
         | Coordinator -> incr coordinator);
        {
          session_id;
          kind = client.kind;
          queue_depth;
          last_event_id = Atomic.get client.last_event_id;
          idle_seconds = max 0.0 (now -. Atomic.get client.last_seen_at);
        })
      snapshot
  in
  let total_sessions = List.length sessions in
  let avg_depth =
    if total_sessions = 0 then 0.0
    else float_of_int !queue_sum /. float_of_int total_sessions
  in
  let hot_sessions =
    sessions
    |> List.sort (fun left right ->
         let by_queue = compare right.queue_depth left.queue_depth in
         if by_queue <> 0 then by_queue
         else
           let by_idle = Float.compare right.idle_seconds left.idle_seconds in
           if by_idle <> 0 then by_idle
           else String.compare left.session_id right.session_id)
    |> take 3
    |> List.map (fun (session : session_snapshot) ->
         {
           Transport_metrics.session_id = session.session_id;
           kind = session_kind_to_string session.kind;
           queue_depth = session.queue_depth;
           last_event_id = session.last_event_id;
           idle_seconds = session.idle_seconds;
         })
  in
  Transport_metrics.set_sse_sessions ~kind:"observer" !observer;
  Transport_metrics.set_sse_sessions ~kind:"coordinator" !coordinator;
  Transport_metrics.set_sse_queue_snapshot ~avg_depth
    ~max_depth:!max_queue_depth ~hot_sessions

let mark_seen (client : client) =
  Atomic.set client.last_seen_at (Time_compat.now ())

(** Monotonic client id for safe replacement/unregister *)
let client_id_counter = Atomic.make 0

(** Global event counter for resumability *)
let event_counter = Atomic.make 0

(** Event buffer for resumability - stores (event_id, event_string, timestamp)

    [event_buffer] is written by every [broadcast_impl] / [send_to] and
    drained by the periodic [cleanup_expired_events] background fiber.
    The buffer is a newest-first persistent list behind [Atomic.t];
    all mutations are pure list rewrites committed via CAS. *)
let max_buffer_size = 100
let buffer_ttl_seconds = Env_config.InternalTimers.sse_buffer_ttl_sec
let event_buffer : (int * string * float) list Atomic.t = Atomic.make []

(** Add event to buffer, maintaining max size *)
let buffer_event event_id event_str =
  let timestamp = Time_compat.now () in
  atomic_update_result event_buffer (fun lst ->
    let next = (event_id, event_str, timestamp) :: lst in
    let trimmed =
      if List.length next > max_buffer_size then take max_buffer_size next
      else next
    in
    { next_state = trimmed; result = () })

(** Get events after given ID for replay (MCP spec MUST) *)
let get_events_after last_id =
  let lst = Atomic.get event_buffer in
  List.fold_left (fun acc (id, ev, _ts) ->
    if id > last_id then ev :: acc else acc
  ) [] (List.rev lst)
  |> List.rev

(** Remove events older than [buffer_ttl_seconds] from the front of the buffer.
    Returns count of evicted events. *)
let cleanup_expired_events () =
  let now = Time_compat.now () in
  atomic_update_result event_buffer (fun lst ->
    let remaining_oldest_first, evicted =
      List.fold_left
        (fun (kept, evicted) (((_id, _ev, ts) as item) : int * string * float) ->
          if now -. ts > buffer_ttl_seconds then
            (kept, evicted + 1)
          else
            (item :: kept, evicted))
        ([], 0) lst
    in
    {
      next_state = List.rev remaining_oldest_first;
      result = evicted;
    })

(** Format SSE event with optional ID and event type.

    When [~id] is supplied the caller has already allocated the event
    ID (typically via {!next_id}); this function must NOT touch the
    counter, or the caller's allocation + this call's
    [fetch_and_add] would leave [event_counter] 2× the number of
    emitted events.  That drift also widens the window for the
    broadcast_impl / send_to peek-then-format pattern: two fibers
    that both peek the counter, both get the same value, and then
    both pass it as [~id] would emit events with the **same** id,
    breaking MCP SSE resumability (the [last_event_id] filter in
    [get_events_after] skips by id, so a duplicate would be
    dropped).

    When [~id] is omitted (external callers in
    [server_mcp_transport_http] / [server_mcp_transport_http_agui])
    this function still allocates a fresh id atomically, preserving
    their contract. *)
let format_event ?id ?event_type data =
  let effective_id =
    match id with
    | Some i -> i
    | None ->
        (* Atomic fetch_and_add: returns old value, we want new value so +1 *)
        Atomic.fetch_and_add event_counter 1 + 1
  in
  let id_line = Printf.sprintf "id: %d\n" effective_id in
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
    Returns (client_id, event_stream, evicted_session_id option).
    The caller should spawn a fiber that drains [event_stream] and
    writes events to the transport.  Evicts the oldest client when at
    capacity.  The client stream/id are allocated once; map installation
    is linearized via CAS over the immutable registry state.
    [kind] defaults to [Coordinator] for backward compatibility. *)
let register ?(kind = Coordinator) session_id ~push ~last_event_id =
  let now = Time_compat.now () in
  let client = {
    id = Atomic.fetch_and_add client_id_counter 1 + 1;
    kind;
    event_stream = Eio.Stream.create stream_capacity;
    push;
    last_event_id = Atomic.make last_event_id;
    created_at = now;
    last_seen_at = Atomic.make now;
  } in
  let evicted =
    atomic_update_result clients (fun state ->
      let evicted =
        if state.count >= max_clients && not (SMap.mem session_id state.entries) then
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
        else
          None
      in
      let entries_after_eviction =
        match evicted with
        | Some sid -> SMap.remove sid state.entries
        | None -> state.entries
      in
      let next_entries = SMap.add session_id client entries_after_eviction in
      {
        next_state = {
          entries = next_entries;
          count = SMap.cardinal next_entries;
        };
        result = evicted;
      })
  in
  (match evicted with
   | Some sid ->
       Log.Server.info "Evicting oldest client %s (at cap %d)" sid max_clients
   | None ->
       ());
  sync_transport_snapshot ();
  (client.id, client.event_stream, evicted)

(** Unregister an SSE client *)
let unregister session_id =
  let removed =
    atomic_update_result clients (fun state ->
      if SMap.mem session_id state.entries then
        let next_entries = SMap.remove session_id state.entries in
        {
          next_state = {
            entries = next_entries;
            count = SMap.cardinal next_entries;
          };
          result = true;
        }
      else
        {
          next_state = state;
          result = false;
        })
  in
  if removed then
    sync_transport_snapshot ()

(** Unregister only if the current client matches the given client_id.
    Prevents an old connection's cleanup from unregistering a newer connection
    that re-used the same session_id. *)
let unregister_if_current session_id client_id =
  let removed =
    atomic_update_result clients (fun state ->
      match SMap.find_opt session_id state.entries with
      | Some client when client.id = client_id ->
          let next_entries = SMap.remove session_id state.entries in
          {
            next_state = {
              entries = next_entries;
              count = SMap.cardinal next_entries;
            };
            result = true;
          }
      | _ ->
          {
            next_state = state;
            result = false;
          })
  in
  if removed then
    sync_transport_snapshot ()

(** Check if client exists *)
let exists session_id =
  SMap.mem session_id (Atomic.get clients).entries

(** Mark a client as recently active *)
let touch session_id =
  match SMap.find_opt session_id (Atomic.get clients).entries with
  | Some client -> mark_seen client
  | None -> ()

(** Update client's last event ID *)
let update_last_event_id session_id event_id =
  match SMap.find_opt session_id (Atomic.get clients).entries with
  | Some client ->
      Atomic.set client.last_event_id event_id;
      mark_seen client
  | None -> ()

(** Eio clock ref for per-client push timeout.
    Set during startup via [set_clock]. Without a clock, push has no timeout. *)
let clock_ref : float Eio.Time.clock_ty Eio.Resource.t option ref = ref None

let set_clock (clock : float Eio.Time.clock_ty Eio.Resource.t) =
  clock_ref := Some clock

(** Per-client push timeout (seconds).
    5s is generous for a local TCP write; slow clients beyond this are dropped. *)
let push_timeout_s = 5.0

(** Test whether a client matches a broadcast target. *)
let client_matches_target target (client : client) =
  match target with
  | All -> true
  | Observers -> client.kind = Observer
  | Coordinators -> client.kind = Coordinator

(** {1 External Subscriber Hook}

    Allows non-SSE consumers (e.g. gRPC Subscribe streams) to receive
    broadcast events without registering as an SSE client.  Subscribers
    are called synchronously after SSE fan-out completes, receiving the
    formatted SSE event string. *)

type external_subscriber = {
  sub_id: string;
  callback: string -> unit;
  is_alive: unit -> bool;
  (** Returns false if the subscriber should be removed.
      Called before each broadcast delivery. *)
}

type external_subscriber_registry_state = {
  subscribers : external_subscriber SMap.t;
  count : int;
}

let empty_external_subscriber_registry_state = {
  subscribers = SMap.empty;
  count = 0;
}

let external_subscribers : external_subscriber_registry_state Atomic.t =
  Atomic.make empty_external_subscriber_registry_state

let current_external_subscriber_count () =
  (Atomic.get external_subscribers).count

let current_external_subscriber_count_with_prefix prefix =
  SMap.fold
    (fun sub_id _ acc ->
      if String.starts_with ~prefix sub_id then acc + 1 else acc)
    (Atomic.get external_subscribers).subscribers 0

(** Register an external subscriber that receives formatted SSE events
    on every broadcast.  The [callback] must not block (use best-effort).

    [is_alive] is called before each delivery; returning [false] triggers
    automatic unsubscription, preventing resource leaks when the consumer
    disconnects without an explicit [unsubscribe_external] call. *)
let subscribe_external ~id ~callback ?(is_alive = fun () -> true) () =
  let subscriber = { sub_id = id; callback; is_alive } in
  let replaced, count =
    atomic_update_result external_subscribers (fun state ->
      let replaced = SMap.mem id state.subscribers in
      let next_subscribers = SMap.add id subscriber state.subscribers in
      let next_count = if replaced then state.count else state.count + 1 in
      {
        next_state = {
          subscribers = next_subscribers;
          count = next_count;
        };
        result = (replaced, next_count);
      })
  in
  if replaced then
    Log.Misc.warn "External subscriber %s replaced (duplicate ID)" id;
  Transport_metrics.set_sse_external_subscribers count

(** Remove a previously registered external subscriber. *)
let unsubscribe_external id =
  let removed, count =
    atomic_update_result external_subscribers (fun state ->
      if SMap.mem id state.subscribers then
        let next_subscribers = SMap.remove id state.subscribers in
        let next_count = state.count - 1 in
        {
          next_state = {
            subscribers = next_subscribers;
            count = next_count;
          };
          result = (true, next_count);
        }
      else
        {
          next_state = state;
          result = (false, state.count);
        })
  in
  if removed then
    Transport_metrics.set_sse_external_subscribers count

(** Number of external subscribers (for diagnostics). *)
let external_subscriber_count () =
  current_external_subscriber_count ()

let external_subscriber_count_with_prefix prefix =
  current_external_subscriber_count_with_prefix prefix

let remove_external_subscribers ids =
  atomic_update_result external_subscribers (fun state ->
    let removed_ids, next_subscribers =
      List.fold_left
        (fun (removed, acc) id ->
          if SMap.mem id acc then
            (id :: removed, SMap.remove id acc)
          else
            (removed, acc))
        ([], state.subscribers) ids
    in
    match removed_ids with
    | [] ->
        {
          next_state = state;
          result = ([], state.count);
        }
    | _ ->
        let removed_ids = List.rev removed_ids in
        let next_count = state.count - List.length removed_ids in
        {
          next_state = {
            subscribers = next_subscribers;
            count = next_count;
          };
          result = (removed_ids, next_count);
        })

(** Fan out an event string to all external subscribers.
    Dead subscribers (where [is_alive] returns [false]) are automatically
    removed during iteration, preventing resource leaks. *)
let notify_external_subscribers event =
  let snapshot =
    SMap.fold
      (fun _ v acc -> v :: acc)
      (Atomic.get external_subscribers).subscribers []
  in
  let dead = ref [] in
  List.iter (fun (sub : external_subscriber) ->
    if not (sub.is_alive ()) then
      dead := sub.sub_id :: !dead
    else begin
      try sub.callback event
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Misc.warn "External subscriber %s failed: %s"
          sub.sub_id (Printexc.to_string exn)
    end
  ) snapshot;
  (* Remove dead subscribers *)
  if !dead <> [] then begin
    let removed_ids, count = remove_external_subscribers !dead in
    List.iter
      (fun id -> Log.Misc.info "Auto-removed dead external subscriber: %s" id)
      removed_ids;
    if removed_ids <> [] then
      Transport_metrics.set_sse_external_subscribers count
  end

(** Actively reap dead external subscribers.
    Unlike [notify_external_subscribers] which only checks [is_alive] during
    broadcast delivery, this function proactively scans all subscribers and
    removes dead ones.  Call periodically from the background maintenance loop
    to prevent stale subscribers from accumulating when no broadcasts occur. *)
let reap_dead_external_subscribers () =
  let snapshot =
    SMap.fold
      (fun _ v acc -> v :: acc)
      (Atomic.get external_subscribers).subscribers []
  in
  let dead = ref [] in
  List.iter (fun (sub : external_subscriber) ->
    if not (sub.is_alive ()) then
      dead := sub.sub_id :: !dead
  ) snapshot;
  let removed_ids =
    if !dead <> [] then begin
      let removed_ids, count = remove_external_subscribers !dead in
      List.iter
        (fun id -> Log.Misc.info "Reaped dead external subscriber: %s" id)
        removed_ids;
      if removed_ids <> [] then
        Transport_metrics.set_sse_external_subscribers count;
      removed_ids
    end else
      []
  in
  List.length removed_ids

(** Internal broadcast implementation shared by [broadcast] and [broadcast_to].
    Pushes the formatted event string into each matching client's
    [event_stream].  The registry snapshot is immutable; the per-stream
    [Eio.Stream.add] calls happen outside any global lock.

    [Eio.Stream.add] on a bounded (capacity 64) stream returns
    immediately as long as the stream is not full.  The per-client drain
    fiber (see [pop]) delivers events to the transport writer
    independently, so broadcast is decoupled from per-connection I/O.

    After SSE fan-out, external subscribers (gRPC streams, etc.) are
    also notified with the same formatted event string. *)
let broadcast_impl target json =
  let t0 = Time_compat.now () in
  let data = Yojson.Safe.to_string json in
  (* Atomically allocate the event id so two concurrent broadcasts
     cannot observe the same peeked counter value and emit duplicates. *)
  let current_event_id = next_id () in
  let event = format_event ~id:current_event_id ~event_type:"message" data in
  buffer_event current_event_id event;
  (* Snapshot under read-lock *)
  let clients_snapshot =
    SMap.fold (fun k v acc -> (k, v) :: acc) (Atomic.get clients).entries []
  in
  let failed = ref [] in
  List.iter (fun (session_id, client) ->
    if client_matches_target target client
       && current_event_id > Atomic.get client.last_event_id then begin
      (* Pre-check stream capacity to avoid blocking broadcast.
         No TOCTOU risk: single-domain Eio cooperative scheduling has no
         yield point between Stream.length and Stream.add, so no other
         fiber can modify the stream in between.  try/catch kept as
         defense-in-depth for unexpected failures.
         See TLA+ SSEBroadcastBlock spec. *)
      (let queue_len = Eio.Stream.length client.event_stream in
       if queue_len >= stream_capacity then begin
         Log.Server.warn "Broadcast skip: session %s stream full (%d/%d)"
           session_id queue_len stream_capacity;
         failed := session_id :: !failed
       end else
         try
           Eio.Stream.add client.event_stream event;
           Atomic.set client.last_event_id current_event_id;
           mark_seen client
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | e ->
             Log.Server.error "Broadcast enqueue failed for session %s: %s"
               session_id (Printexc.to_string e);
             failed := session_id :: !failed)
    end
  ) clients_snapshot;
  (* Remove failed connections *)
  List.iter (fun sid -> unregister sid) !failed;
  (* Record broadcast duration for transport observability *)
  let elapsed = Time_compat.now () -. t0 in
  Transport_metrics.observe_broadcast_duration elapsed;
  sync_transport_snapshot ();
  (* Notify external subscribers (gRPC streams, etc.) *)
  notify_external_subscribers event

(** Broadcast event to all connected clients (backward-compatible). *)
let broadcast json = broadcast_impl All json

(** Broadcast event to sessions matching [target].
    - [All]: every session (same as [broadcast])
    - [Observers]: dashboard / read-only viewers only
    - [Coordinators]: MCP agent sessions only *)
let broadcast_to target json = broadcast_impl target json

(** Send a JSON-RPC message to a specific session.
    Enqueues the event in the session's stream for asynchronous delivery. *)
let send_to session_id json =
  let data = Yojson.Safe.to_string json in
  (* Atomic allocation — see [broadcast_impl] for rationale. *)
  let current_event_id = next_id () in
  let event = format_event ~id:current_event_id ~event_type:"message" data in
  buffer_event current_event_id event;
  let client_opt = SMap.find_opt session_id (Atomic.get clients).entries in
  match client_opt with
  | None -> ()
  | Some client ->
      (try
        Eio.Stream.add client.event_stream event;
        Atomic.set client.last_event_id current_event_id;
        mark_seen client;
        sync_transport_snapshot ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e ->
          Log.Server.error "Enqueue to %s failed: %s"
            session_id (Printexc.to_string e))

(** Pop the next event from a client's stream.
    Blocks the calling fiber until an event is available.
    Returns [None] if the session does not exist (connection was closed).

    The SSE connection fiber should call this in a loop:
    {[
      let rec drain () =
        match Sse.pop session_id with
        | None -> ()  (* session gone, stop *)
        | Some event ->
            send_raw info event;
            drain ()
      in
      drain ()
    ]} *)
let pop session_id =
  let client_opt = SMap.find_opt session_id (Atomic.get clients).entries in
  match client_opt with
  | None -> None
  | Some client -> Some (Eio.Stream.take client.event_stream)

(** Non-blocking pop. Returns [Some event] if one is queued, [None] otherwise. *)
let try_pop session_id =
  let client_opt = SMap.find_opt session_id (Atomic.get clients).entries in
  match client_opt with
  | None -> None
  | Some client -> Eio.Stream.take_nonblocking client.event_stream

(** Get client count.
    Uses [Atomic.get] so it is safe to call from signal handlers. *)
let client_count () =
  (Atomic.get clients).count

(** Return list of session_ids for all connected clients.
    Used by transport metrics to report session count by kind. *)
let all_session_ids () =
  SMap.fold (fun sid _client acc -> sid :: acc) (Atomic.get clients).entries []

(** Close all SSE clients - for graceful shutdown.
    Returns the number of clients that were closed. *)
let close_all_clients () =
  let sessions =
    atomic_update_result clients (fun state ->
      let sessions = SMap.fold (fun sid _ acc -> sid :: acc) state.entries [] in
      {
        next_state = empty_client_registry_state;
        result = sessions;
      })
  in
  sync_transport_snapshot ();
  List.length sessions

(** Remove clients idle longer than max_age_s (default 30 min).
    Returns list of evicted session_ids so caller can clean up writers. *)
let cleanup_stale ?(max_age_s=1800.0) () =
  let now = Time_compat.now () in
  let stale =
    SMap.fold (fun sid c acc ->
      let last_seen = Atomic.get c.last_seen_at in
      if now -. last_seen > max_age_s then (sid, last_seen) :: acc else acc
    ) (Atomic.get clients).entries []
  in
  (* Remove under lock, one by one *)
  List.iter (fun (sid, last_seen) ->
    Log.Server.info "idle evict: %s (idle %.0fs)" sid (now -. last_seen);
    unregister sid
  ) stale;
  List.map fst stale
