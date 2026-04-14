(** SSE (Server-Sent Events) module for MCP Streamable HTTP Transport
    MCP Spec 2025-03-26 compliant

    Concurrency model (per-session stream):
    Each registered client owns an [Eio.Stream.t] mailbox.
    [broadcast] and [send_to] push formatted SSE strings into per-client
    streams under a read-only registry snapshot -- no global write-lock
    during fan-out.  Each SSE connection fiber drains its own stream via
    [pop], calling the transport-layer write independently.

    The registry mutex ([registry_mutex]) only serialises Hashtbl
    add/remove, not broadcast writes.

    Session kinds:
    [Observer] sessions receive dashboard snapshots but not agent
    coordination traffic.  [Coordinator] sessions receive heartbeats
    and task events but not dashboard snapshots.  [broadcast_to All]
    reaches every session (backward-compatible with the old [broadcast]).

    Signal handler safety: [broadcast] and [close_all_clients] use
    try/with around mutex acquisition; if the mutex cannot be acquired
    (e.g. signal interrupted a fiber holding it), they fall back to
    best-effort lock-free execution since the process is shutting down. *)

(** Classification of an SSE session's traffic role. *)
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
let stream_capacity =
  match Sys.getenv_opt "MASC_SSE_STREAM_CAPACITY" with
  | Some s -> (match int_of_string_opt (String.trim s) with Some v -> max 8 (min 1024 v) | None -> 64)
  | None -> 64

(** SSE client state.
    [event_stream] is the per-session mailbox.  [broadcast] pushes here;
    the SSE connection fiber pops and writes to the HTTP body writer. *)
type client = {
  id: int;
  kind: session_kind;
  event_stream: string Eio.Stream.t;
  push: string -> unit;  (** legacy direct-push callback (used by drain) *)
  mutable last_event_id: int;
  created_at: float;
  mutable last_seen_at: float;
}

(** Client registry - maps session_id to client *)
let clients : (string, client) Hashtbl.t = Hashtbl.create 16

(** Registry mutex -- protects all [clients] Hashtbl mutations.
    Pattern: mcp_agent_queue.ml, agent_identity.ml *)
let registry_mutex = Eio.Mutex.create ()

(** Atomic client count -- mirrors Hashtbl.length for signal-handler-safe reads.
    Kept in sync inside [registry_mutex] critical sections. *)
let client_count_atomic = Atomic.make 0

(** Run [f] inside the registry mutex.
    Falls back to lock-free [f ()] when Eio effects are unavailable
    (e.g. POSIX signal handler context, module init, or test harness
    running outside [Eio_main.run]).

    Two exception classes to handle:
    - [Effect.Unhandled _]: no Eio scheduler installed at all.
    - [Eio.Mutex.Poisoned _]: mutex created but scheduler not running
      (e.g. Alcotest without [Eio_main.run] wrapper). *)
let with_registry_rw f = Eio_guard.with_mutex registry_mutex f
let with_registry_ro f = Eio_guard.with_mutex_ro registry_mutex f

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
    with_registry_ro (fun () ->
      Hashtbl.fold (fun sid client acc -> (sid, client) :: acc) clients [])
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
          last_event_id = client.last_event_id;
          idle_seconds = max 0.0 (now -. client.last_seen_at);
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
  client.last_seen_at <- Time_compat.now ()

(** Monotonic client id for safe replacement/unregister *)
let client_id_counter = Atomic.make 0

(** Global event counter for resumability *)
let event_counter = Atomic.make 0

(** Event buffer for resumability - stores (event_id, event_string, timestamp)

    [event_buffer] is written by every [broadcast_impl] / [send_to] and
    drained by the periodic [cleanup_expired_events] background fiber;
    [get_events_after] folds over it from the HTTP transport handler
    when a client reconnects with [Last-Event-ID].  [Stdlib.Queue] is
    not domain-safe, and even within a single Eio domain the
    "[length]+[pop]+[push]" sequence in [buffer_event] is three
    operations that must stay paired.  Serialise every access through
    [event_buffer_mutex]; the same pattern already protects [clients]
    and [ext_subs] above.  Kept separate from [registry_mutex] because
    broadcast fan-out deliberately holds the registry mutex read-only,
    and the buffer write does not need to wait for client snapshots. *)
let max_buffer_size = 100
let buffer_ttl_seconds = Env_config.InternalTimers.sse_buffer_ttl_sec
let event_buffer : (int * string * float) Queue.t = Queue.create ()
let event_buffer_mutex = Eio.Mutex.create ()

let with_event_buffer_rw f = Eio_guard.with_mutex event_buffer_mutex f
let with_event_buffer_ro f = Eio_guard.with_mutex_ro event_buffer_mutex f

(** Add event to buffer, maintaining max size *)
let buffer_event event_id event_str =
  with_event_buffer_rw (fun () ->
    if Queue.length event_buffer >= max_buffer_size then
      ignore (Queue.pop event_buffer);
    Queue.push (event_id, event_str, Time_compat.now ()) event_buffer)

(** Get events after given ID for replay (MCP spec MUST) *)
let get_events_after last_id =
  with_event_buffer_ro (fun () ->
    Queue.fold (fun acc (id, ev, _ts) ->
      if id > last_id then ev :: acc else acc
    ) [] event_buffer
    |> List.rev)

(** Remove events older than [buffer_ttl_seconds] from the front of the buffer.
    Returns count of evicted events. *)
let cleanup_expired_events () =
  with_event_buffer_rw (fun () ->
    let now = Time_compat.now () in
    let count = ref 0 in
    let keep_popping = ref true in
    while !keep_popping && not (Queue.is_empty event_buffer) do
      let (_id, _ev, ts) = Queue.peek event_buffer in
      if now -. ts > buffer_ttl_seconds then begin
        ignore (Queue.pop event_buffer);
        incr count
      end else
        keep_popping := false
    done;
    !count)

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
    capacity.  ID generation + add are atomic under [registry_mutex].
    [kind] defaults to [Coordinator] for backward compatibility. *)
let register ?(kind = Coordinator) session_id ~push ~last_event_id =
  let result =
    with_registry_rw (fun () ->
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
            Log.Server.info "Evicting oldest client %s (at cap %d)" sid max_clients;
            Hashtbl.remove clients sid;
            Atomic.decr client_count_atomic;
            Some sid
        | None -> None
      else None
    in
    let now = Time_compat.now () in
    let new_id = Atomic.fetch_and_add client_id_counter 1 + 1 in
    let event_stream = Eio.Stream.create stream_capacity in
    let client = {
      id = new_id;
      kind;
      event_stream;
      push;
      last_event_id;
      created_at = now;
      last_seen_at = now;
    } in
    (* If session_id already exists, replace does not change count *)
    let was_present = Hashtbl.mem clients session_id in
    Hashtbl.replace clients session_id client;
    if not was_present then Atomic.incr client_count_atomic;
    (client.id, client.event_stream, evicted))
  in
  sync_transport_snapshot ();
  result

(** Unregister an SSE client *)
let unregister session_id =
  let removed =
    with_registry_rw (fun () ->
    if Hashtbl.mem clients session_id then begin
      Hashtbl.remove clients session_id;
      Atomic.decr client_count_atomic;
      true
    end else
      false)
  in
  if removed then sync_transport_snapshot ()

(** Unregister only if the current client matches the given client_id.
    Prevents an old connection's cleanup from unregistering a newer connection
    that re-used the same session_id. *)
let unregister_if_current session_id client_id =
  let removed =
    with_registry_rw (fun () ->
    match Hashtbl.find_opt clients session_id with
    | Some client when client.id = client_id ->
        Hashtbl.remove clients session_id;
        Atomic.decr client_count_atomic;
        true
    | _ -> false)
  in
  if removed then sync_transport_snapshot ()

(** Check if client exists *)
let exists session_id =
  with_registry_ro (fun () ->
    Hashtbl.mem clients session_id)

(** Mark a client as recently active *)
let touch session_id =
  with_registry_rw (fun () ->
    match Hashtbl.find_opt clients session_id with
    | Some client -> mark_seen client
    | None -> ())

(** Update client's last event ID *)
let update_last_event_id session_id event_id =
  with_registry_rw (fun () ->
    match Hashtbl.find_opt clients session_id with
    | Some client ->
        client.last_event_id <- event_id;
        mark_seen client
    | None -> ())

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

let external_subscribers : (string, external_subscriber) Hashtbl.t = Hashtbl.create 8
let ext_sub_mutex = Eio.Mutex.create ()

let with_ext_sub_rw f = Eio_guard.with_mutex ext_sub_mutex f
let with_ext_sub_ro f = Eio_guard.with_mutex_ro ext_sub_mutex f

let current_external_subscriber_count () =
  with_ext_sub_ro (fun () -> Hashtbl.length external_subscribers)

(** Register an external subscriber that receives formatted SSE events
    on every broadcast.  The [callback] must not block (use best-effort).

    [is_alive] is called before each delivery; returning [false] triggers
    automatic unsubscription, preventing resource leaks when the consumer
    disconnects without an explicit [unsubscribe_external] call. *)
let subscribe_external ~id ~callback ?(is_alive = fun () -> true) () =
  with_ext_sub_rw (fun () ->
    if Hashtbl.mem external_subscribers id then
      Log.Misc.warn "External subscriber %s replaced (duplicate ID)" id;
    Hashtbl.replace external_subscribers id { sub_id = id; callback; is_alive });
  Transport_metrics.set_sse_external_subscribers (current_external_subscriber_count ())

(** Remove a previously registered external subscriber. *)
let unsubscribe_external id =
  with_ext_sub_rw (fun () ->
    Hashtbl.remove external_subscribers id);
  Transport_metrics.set_sse_external_subscribers (current_external_subscriber_count ())

(** Number of external subscribers (for diagnostics). *)
let external_subscriber_count () =
  current_external_subscriber_count ()

(** Fan out an event string to all external subscribers.
    Dead subscribers (where [is_alive] returns [false]) are automatically
    removed during iteration, preventing resource leaks. *)
let notify_external_subscribers event =
  let snapshot =
    with_ext_sub_ro (fun () ->
      Hashtbl.fold (fun _ v acc -> v :: acc) external_subscribers [])
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
    List.iter (fun id ->
      with_ext_sub_rw (fun () -> Hashtbl.remove external_subscribers id);
      Log.Misc.info "Auto-removed dead external subscriber: %s" id
    ) !dead;
    Transport_metrics.set_sse_external_subscribers (current_external_subscriber_count ())
  end

(** Actively reap dead external subscribers.
    Unlike [notify_external_subscribers] which only checks [is_alive] during
    broadcast delivery, this function proactively scans all subscribers and
    removes dead ones.  Call periodically from the background maintenance loop
    to prevent stale subscribers from accumulating when no broadcasts occur. *)
let reap_dead_external_subscribers () =
  let snapshot =
    with_ext_sub_ro (fun () ->
      Hashtbl.fold (fun _ v acc -> v :: acc) external_subscribers [])
  in
  let dead = ref [] in
  List.iter (fun (sub : external_subscriber) ->
    if not (sub.is_alive ()) then
      dead := sub.sub_id :: !dead
  ) snapshot;
  if !dead <> [] then
    List.iter (fun id ->
      with_ext_sub_rw (fun () -> Hashtbl.remove external_subscribers id);
      Log.Misc.info "Reaped dead external subscriber: %s" id
    ) !dead;
  if !dead <> [] then
    Transport_metrics.set_sse_external_subscribers (current_external_subscriber_count ());
  List.length !dead

(** Internal broadcast implementation shared by [broadcast] and [broadcast_to].
    Pushes the formatted event string into each matching client's
    [event_stream].  The registry read-lock is held only for the Hashtbl
    snapshot; the per-stream [Eio.Stream.add] calls happen outside any
    global lock.

    [Eio.Stream.add] on a bounded (capacity 1024) stream returns
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
    with_registry_ro (fun () ->
      Hashtbl.fold (fun k v acc -> (k, v) :: acc) clients [])
  in
  let failed = ref [] in
  List.iter (fun (session_id, client) ->
    if client_matches_target target client
       && current_event_id > client.last_event_id then begin
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
           client.last_event_id <- current_event_id;
           client.last_seen_at <- Time_compat.now ()
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
  let client_opt =
    with_registry_ro (fun () ->
      Hashtbl.find_opt clients session_id)
  in
  match client_opt with
  | None -> ()
  | Some client ->
      (try
        Eio.Stream.add client.event_stream event;
        client.last_event_id <- current_event_id;
        client.last_seen_at <- Time_compat.now ();
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
  let client_opt =
    with_registry_ro (fun () ->
      Hashtbl.find_opt clients session_id)
  in
  match client_opt with
  | None -> None
  | Some client -> Some (Eio.Stream.take client.event_stream)

(** Non-blocking pop. Returns [Some event] if one is queued, [None] otherwise. *)
let try_pop session_id =
  let client_opt =
    with_registry_ro (fun () ->
      Hashtbl.find_opt clients session_id)
  in
  match client_opt with
  | None -> None
  | Some client -> Eio.Stream.take_nonblocking client.event_stream

(** Get client count.
    Uses [Atomic.get] so it is safe to call from signal handlers. *)
let client_count () =
  Atomic.get client_count_atomic

(** Return list of session_ids for all connected clients.
    Used by transport metrics to report session count by kind. *)
let all_session_ids () =
  with_registry_ro (fun () ->
    Hashtbl.fold (fun sid _client acc -> sid :: acc) clients [])

(** Close all SSE clients - for graceful shutdown.
    Returns the number of clients that were closed.
    Signal-handler safe via [with_registry_rw] fallback. *)
let close_all_clients () =
  let sessions =
    with_registry_rw (fun () ->
      let ss = Hashtbl.fold (fun sid _ acc -> sid :: acc) clients [] in
      Hashtbl.clear clients;
      Atomic.set client_count_atomic 0;
      ss)
  in
  sync_transport_snapshot ();
  List.length sessions

(** Remove clients idle longer than max_age_s (default 30 min).
    Returns list of evicted session_ids so caller can clean up writers. *)
let cleanup_stale ?(max_age_s=1800.0) () =
  let now = Time_compat.now () in
  (* Snapshot stale candidates under lock *)
  let stale =
    with_registry_ro (fun () ->
      Hashtbl.fold (fun sid c acc ->
        if now -. c.last_seen_at > max_age_s then (sid, c.last_seen_at) :: acc else acc
      ) clients [])
  in
  (* Remove under lock, one by one *)
  List.iter (fun (sid, last_seen) ->
    Log.Server.info "idle evict: %s (idle %.0fs)" sid (now -. last_seen);
    unregister sid
  ) stale;
  List.map fst stale
