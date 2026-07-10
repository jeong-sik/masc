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
    workspace traffic.  [Agent_stream] sessions receive heartbeats
    and task events but not dashboard snapshots.  [Presence] sessions
    receive ephemeral liveness/awareness updates through the bufferless
    presence channel.  [broadcast_to All] reaches every durable session
    (backward-compatible with the old [broadcast]).

    Signal handler safety: registry operations avoid [Eio.Mutex] and rely on
    immutable snapshots plus CAS, so readers can inspect counts without
    waiting on a lock held by another fiber. *)

(** Authentication context supplied by SSE transport callers. *)
type registration_auth = {
  config : string;
  token : string option;
}

(** Failure modes for SSE registration. *)
type registration_error =
  | Missing_token
  | Invalid_token of { reason : string }
  | Token_expired of { agent_name : string }
  | Auth_lookup_error of { reason : Masc_domain.masc_error }
  | Unknown_session of { session_id : string }
  | Session_expired of { session_id : string }
  | Session_owner_mismatch of { session_agent : string; token_agent : string }

let registration_error_to_string = function
  | Missing_token -> "SSE registration failed: bearer token is required"
  | Invalid_token { reason } ->
      Printf.sprintf "SSE registration failed: invalid token (%s)" reason
  | Token_expired { agent_name } ->
      Printf.sprintf "SSE registration failed: token for %s has expired" agent_name
  | Auth_lookup_error { reason } ->
      Printf.sprintf "SSE registration failed: auth lookup error (%s)"
        (Masc_domain.masc_error_to_string reason)
  | Unknown_session { session_id } ->
      Printf.sprintf "SSE registration failed: unknown session %s" session_id
  | Session_expired { session_id } ->
      Printf.sprintf "SSE registration failed: session %s has expired" session_id
  | Session_owner_mismatch { session_agent; token_agent } ->
      Printf.sprintf
        "SSE registration failed: session belongs to %s but token belongs to %s"
        session_agent token_agent

(** Classification of an SSE session's traffic role. *)
module SMap = Set_util.StringMap
module IntMap = Map.Make (Int)

(* Test-only hooks for forcing a CAS retry in white-box unit tests. *)
let register_commit_test_hook : (unit -> unit) option Atomic.t = Atomic.make None
let buffer_commit_test_hook : (unit -> unit) option Atomic.t = Atomic.make None

let run_test_hook hook =
  match Atomic.get hook with
  | Some fn -> fn ()
  | None -> ()

type session_kind =
  | Observer [@tla.symbol "observer"]    (** Dashboard / read-only viewers *)
  | Agent_stream [@tla.symbol "agent_stream"] (** MCP agent connections *)
  | Presence [@tla.symbol "presence"]    (** Ephemeral liveness / awareness channel *)
[@@deriving tla]

(** Broadcast targeting selector. *)
type broadcast_target =
  | All          (** Every connected session (backward-compatible default) *)
  | Observers    (** Only [Observer] sessions *)
  | Agent_streams (** Only [Agent_stream] sessions *)
  | Presence_only (** Only [Presence] sessions; never replay-buffered *)

(** Maximum concurrent SSE clients -- prevents connection storm on restart.
    Increased from 50 to 200 to handle Claude.ai MCP client reconnections. *)
let max_clients = 200

(** Per-client event stream capacity.

    Must be > 0 to avoid synchronous rendez-vous semantics
    ([Eio.Stream.create 0] blocks add until a matching take).

    Read from [MASC_SSE_STREAM_CAPACITY] (catalog: clamped 8-1024,
    default 256).  256 events at 3-10s intervals covers 13-43 minutes of
    buffering.  A client that falls this far behind should reconnect.
    Cap exists because broadcast fan-out at 64+ keepers + multiple
    dashboard tabs accumulates faster than slow consumers can drain;
    the default is sized so silent eviction does not coincide with the
    operator's keeper count.

    The catalog entry in [Env_config_snapshot.sse_entries] documents the
    same clamp range; keep them in sync. *)
let stream_capacity =
  let default = 256 in
  let lower = 8 and upper = 1024 in
  let clamp n = max lower (min upper n) in
  clamp
    (Env_config_core.get_int ~default "MASC_SSE_STREAM_CAPACITY")

(** SSE client state.
    [event_stream] is the per-session mailbox.  [broadcast] pushes here;
    the SSE connection fiber pops and writes to the HTTP body writer. *)
type client = {
  id: int;
  kind: session_kind;
  event_stream: string Eio.Stream.t;
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
  | Agent_stream -> "agent_stream"
  | Presence -> "presence"

(** Minimum interval between full transport snapshot computations (seconds).
    The snapshot iterates all SSE clients and builds per-session records;
    at ~9 broadcasts/sec this path accounts for most allocation on the
    broadcast hot path.  Throttling to ~0.2/sec cuts allocation by ~97%
    while keeping dashboard metrics within 5 seconds of reality.
    Configurable via [MASC_SNAPSHOT_INTERVAL_SEC] env var (default 5.0). *)
let snapshot_min_interval_sec =
  (* Route through the validated helper (same idiom as [MASC_SSE_*] above):
     a malformed value (e.g. "abc") previously raised [Failure] -- the
     hand-rolled [with Not_found] only caught the unset case, so a typo in
     this env var crashed the module at load. [get_float_nonneg] also maps
     negative / NaN / +-inf to the default, which is correct for an
     interval-seconds knob. *)
  Env_config_core.get_float_nonneg ~default:5.0 "MASC_SNAPSHOT_INTERVAL_SEC"

(** Timestamp of the last completed snapshot.  CAS-guarded so that
    concurrent [broadcast_impl] fibers racing to snapshot after the
    interval expires do not duplicate work — only one fiber wins the
    compare-and-set and runs the full iteration. *)
let last_snapshot_time : float Atomic.t = Atomic.make 0.0

let sync_transport_snapshot ?(force = false) () =
  let now = Time_compat.now () in
  let last = Atomic.get last_snapshot_time in
  if (not force) && now -. last < snapshot_min_interval_sec then ()
  else if not (Atomic.compare_and_set last_snapshot_time last now) then ()
  else begin
  (* Single-pass aggregation: previously [SMap.fold] built a
     [(sid, client)] tuple list, then [List.map] re-walked it to
     produce [session_snapshot] records.  [SMap.iter] over the
     immutable map snapshot folds both passes into one, dropping
     the per-client tuple cons cell.  Counters and the [sessions]
     accumulator share the iteration; [total_sessions] is also
     counted in-line, avoiding a trailing [List.length].  Called
     on every [broadcast_impl] invocation, so the saved allocation
     compounds with the fan-out itself. *)
  let observer = ref 0 in
  let agent_stream = ref 0 in
  let presence = ref 0 in
  let queue_sum = ref 0 in
  let max_queue_depth = ref 0 in
  let sessions_acc = ref [] in
  let total_sessions_acc = ref 0 in
  SMap.iter (fun session_id client ->
    let queue_depth = Eio.Stream.length client.event_stream in
    queue_sum := !queue_sum + queue_depth;
    max_queue_depth := max !max_queue_depth queue_depth;
    (match client.kind with
     | Observer -> incr observer
     | Agent_stream -> incr agent_stream
     | Presence -> incr presence);
    incr total_sessions_acc;
    sessions_acc :=
      {
        session_id;
        kind = client.kind;
        queue_depth;
        last_event_id = Atomic.get client.last_event_id;
        idle_seconds = max 0.0 (now -. Atomic.get client.last_seen_at);
      } :: !sessions_acc
  ) (Atomic.get clients).entries;
  let sessions = !sessions_acc in
  let total_sessions = !total_sessions_acc in
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
    |> List.take 3
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
  Transport_metrics.set_sse_sessions ~kind:"agent_stream" !agent_stream;
  Transport_metrics.set_sse_sessions ~kind:"presence" !presence;
  Transport_metrics.set_sse_queue_snapshot ~avg_depth
    ~max_depth:!max_queue_depth ~hot_sessions
  end

let mark_seen (client : client) =
  Atomic.set client.last_seen_at (Time_compat.now ())

(** Monotonic client id for safe replacement/unregister *)
let client_id_counter = Atomic.make 0

(** Global event counter for resumability *)
let event_counter = Atomic.make 0

(** Event buffer for resumability - stores (event_id, event_string, timestamp)

    [event_buffer] is written by every [broadcast_impl] / [send_to] and
    drained by the periodic [cleanup_expired_events] background fiber.
    The buffer is an immutable [event_id -> event] map plus a linearized
    count behind one [Atomic.t]; all mutations are pure map rewrites committed
    via CAS.

    Read from [MASC_SSE_REPLAY_BUFFER_SIZE] (default 1000, clamped 50..1000).
    Sized to bound replay work for clients reconnecting with [Last-Event-Id]
    after a network blip; previously fixed at 100, which was too small to
    cover transient disconnects under 64+ keeper broadcast load and forced
    operators to manually refresh the dashboard.  The upper bound matches
    [test/test_sse_coverage.ml] expectations. *)
let max_buffer_size =
  let default = 1000 in
  let lower = 50 and upper = 1000 in
  let clamp n = max lower (min upper n) in
  clamp
    (Env_config_core.get_int ~default "MASC_SSE_REPLAY_BUFFER_SIZE")
let buffer_ttl_seconds = Env_config.InternalTimers.sse_buffer_ttl_sec

type buffered_event = int * string * float

type event_buffer_state = {
  events_by_id : buffered_event IntMap.t;
  count : int;
}

let empty_event_buffer_state = { events_by_id = IntMap.empty; count = 0 }

let event_buffer : event_buffer_state Atomic.t =
  Atomic.make empty_event_buffer_state

let event_buffer_state_of_events events =
  let events_by_id =
    List.fold_left
      (fun acc (((event_id, _, _) as event) : buffered_event) ->
         IntMap.add event_id event acc)
      IntMap.empty events
  in
  { events_by_id; count = IntMap.cardinal events_by_id }

let event_buffer_events_newest_first state =
  state.events_by_id |> IntMap.bindings |> List.rev_map snd

let event_buffer_events_for_test () =
  Atomic.get event_buffer |> event_buffer_events_newest_first

let set_event_buffer_for_test events =
  Atomic.set event_buffer (event_buffer_state_of_events events)

let rewrite_event_buffer_for_test () =
  Lockfree_atomic.update event_buffer (fun state ->
    { state with count = state.count })

(** Add event to buffer, maintaining max size *)
let buffer_event event_id event_str =
  Lockfree_atomic.update_with_commit event_buffer (fun state ->
    run_test_hook buffer_commit_test_hook;
    let timestamp = Time_compat.now () in
    let event = (event_id, event_str, timestamp) in
    let replacing = IntMap.mem event_id state.events_by_id in
    let events_by_id = IntMap.add event_id event state.events_by_id in
    let count = if replacing then state.count else state.count + 1 in
    let events_by_id, count =
      if count <= max_buffer_size then events_by_id, count
      else
        let oldest_id, _oldest = IntMap.min_binding events_by_id in
        IntMap.remove oldest_id events_by_id, count - 1
    in
    { next_state = { events_by_id; count }; result = () })

let event_matches_session_kind kind event =
  match kind with
  | Observer -> true
  | Agent_stream -> Sse_jsonrpc_filter.event_string_jsonrpc_message_for_agent_stream event
  | Presence -> false

(** Get events after given ID for replay (MCP spec MUST) *)
let get_events_after last_id =
  let state = Atomic.get event_buffer in
  let _older_or_equal, _at_last_id, newer = IntMap.split last_id state.events_by_id in
  newer |> IntMap.bindings |> List.map (fun (_id, (_event_id, ev, _ts)) -> ev)

let get_events_after_for_kind kind last_id =
  get_events_after last_id
  |> List.filter (event_matches_session_kind kind)

(** Remove events older than [buffer_ttl_seconds] from the front of the buffer.
    Returns count of evicted events. *)
let cleanup_expired_events () =
  let now = Time_compat.now () in
  Lockfree_atomic.update_with_commit event_buffer (fun state ->
    let events_by_id, evicted =
      IntMap.fold
        (fun id (((_event_id, _ev, ts) as item) : buffered_event) (kept, evicted) ->
          if now -. ts > buffer_ttl_seconds then
            (kept, evicted + 1)
          else
            (IntMap.add id item kept, evicted))
        state.events_by_id
        (IntMap.empty, 0)
    in
    {
      next_state = { events_by_id; count = IntMap.cardinal events_by_id };
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
  (* Hot path: every broadcast goes through here once.  The previous
     three [Printf.sprintf] calls each ran the format interpreter and
     allocated an intermediate string ([id_line], [event_line], the
     concat), so a single broadcast paid for three string allocations
     plus the [%d]/[%s] dispatch overhead before the result string was
     produced.  A single [Buffer] accumulator with primitive
     [string_of_int] sidesteps the format interpreter entirely and
     emits exactly the bytes the SSE wire format requires (id-line +
     optional event-line + data-line + blank).  The output string is
     byte-for-byte identical to what [Printf.sprintf] produced. *)
  let buf = Buffer.create 64 in
  Buffer.add_string buf "id: ";
  Buffer.add_string buf (string_of_int effective_id);
  Buffer.add_char buf '\n';
  (match event_type with
   | Some e ->
       Buffer.add_string buf "event: ";
       Buffer.add_string buf e;
       Buffer.add_char buf '\n'
   | None -> ());
  Buffer.add_string buf "data: ";
  Buffer.add_string buf data;
  Buffer.add_string buf "\n\n";
  Buffer.contents buf

(** Format SSE event from a [Yojson.Safe.t] value without the intermediate
    [to_string] allocation.  Writes JSON bytes directly into the SSE event
    buffer via [Yojson.Safe.to_buffer], cutting one string allocation per
    broadcast (~9/sec → ~9 fewer short-lived strings/sec for GC to collect). *)
let format_event_yojson ?id ?event_type json =
  let effective_id =
    match id with
    | Some i -> i
    | None -> Atomic.fetch_and_add event_counter 1 + 1
  in
  let buf = Buffer.create 128 in
  Buffer.add_string buf "id: ";
  Buffer.add_string buf (string_of_int effective_id);
  Buffer.add_char buf '\n';
  (match event_type with
   | Some e ->
       Buffer.add_string buf "event: ";
       Buffer.add_string buf e;
       Buffer.add_char buf '\n'
   | None -> ());
  Buffer.add_string buf "data: ";
  Yojson.Safe.to_buffer buf json;
  Buffer.add_string buf "\n\n";
  Buffer.contents buf

(** Get current event ID *)
let current_id () = Atomic.get event_counter

(** Allocate next event ID without emitting data. *)
let next_id () =
  (* Atomic fetch_and_add: returns old value, we want new value so +1 *)
  Atomic.fetch_and_add event_counter 1 + 1

(** Per-session disconnect hook registry.

    A disconnect hook fires when [unregister] / [unregister_if_current]
    removes a session from [clients].  Its purpose is to wake the
    transport-layer drain fiber that is otherwise blocked on
    [Eio.Stream.take]: removing the session from the broadcast registry
    stops new events from arriving, but the drain fiber holds the HTTP
    connection's [info.stop] flag and must be signalled separately.

    Without this hook, queue-overflow [unregister] calls (broadcast skip
    fixup at [broadcast_impl]) leak HTTP connections with stale drain
    fibers — manifesting as "WS events stop arriving but the browser
    still shows connected" until keep-alive timeout reaps the socket
    minutes later.  This was the silent half of the
    [Transport_metrics.inc_broadcast_failure] path.

    The hook is invoked exactly once: it is removed from the registry
    inside the same atomic update that observes its presence, so even
    racing [unregister] / [unregister_if_current] calls cannot double-fire.
    Hook callbacks are wrapped in try/with — exceptions are logged and
    swallowed (except [Eio.Cancel.Cancelled]) so a misbehaving callback
    cannot strand the broadcast fan-out. *)
let session_disconnect_hooks : (unit -> unit) SMap.t Atomic.t =
  Atomic.make SMap.empty

let set_disconnect_hook session_id hook =
  Lockfree_atomic.update_with_commit session_disconnect_hooks (fun map ->
    { next_state = SMap.add session_id hook map; result = () })

let clear_disconnect_hook session_id =
  Lockfree_atomic.update_with_commit session_disconnect_hooks (fun map ->
    { next_state = SMap.remove session_id map; result = () })

let take_disconnect_hook session_id =
  let hook_ref = ref None in
  Lockfree_atomic.update_with_commit session_disconnect_hooks (fun map ->
    match SMap.find_opt session_id map with
    | None -> { next_state = map; result = () }
    | Some hook ->
        hook_ref := Some hook;
        { next_state = SMap.remove session_id map; result = () });
  !hook_ref

let invoke_disconnect_hook_for session_id =
  match take_disconnect_hook session_id with
  | None -> ()
  | Some hook ->
      (try hook () with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Server.error "SSE disconnect hook failed for %s: %s"
             session_id (Printexc.to_string exn))

(** Validate the bearer token and MCP session pair for an SSE registration.
    Token resolution is delegated to [Auth.find_credential_by_token]; session
    existence and expiry are checked via [Session.McpSessionStore.peek] so
    the validation read does not refresh the session's activity window.

    Session creation is intentionally not performed here: an SSE registration
    must reference a session already issued by the initialize handler
    (RFC-0099 § session lifecycle; credential surface RFC-0008 / RFC-0019). *)
let validate_registration ~(auth : registration_auth) session_id : (Masc_domain.agent_credential, registration_error) result =
  let open Masc_domain in
  match auth.token with
  | None ->
      Error Missing_token
  | Some token ->
    match Auth.find_credential_by_token auth.config ~token with
    | Error (Auth (Auth_error.InvalidToken reason)) ->
        Error (Invalid_token { reason })
    | Error (Auth (Auth_error.TokenExpired agent_name)) ->
        Error (Token_expired { agent_name })
    | Error e ->
        Log.Server.warn "SSE registration auth lookup failed: %s"
          (masc_error_to_string e);
        Error (Auth_lookup_error { reason = e })
    | Ok credential ->
        match Session.McpSessionStore.peek session_id with
        | None ->
            Error (Unknown_session { session_id })
        | Some session ->
            let now = Time_compat.now () in
            if now -. session.last_activity > Env_config.Session.max_age_seconds then
              Error (Session_expired { session_id })
            else
              match session.agent_name with
              | Some session_agent when not (String.equal session_agent credential.agent_name) ->
                  Error (Session_owner_mismatch { session_agent; token_agent = credential.agent_name })
              | _ ->
                  Ok credential

(** Register a new SSE client.
    Returns (client_id, event_stream, evicted_session_id option).
    [?on_disconnect], if supplied, is installed BEFORE the client is
    published to [clients] — closes the race window where a concurrent
    [broadcast] could observe the new entry, hit queue overflow, fire
    [unregister], and find no hook to wake the drain fiber. *)
let register ?(kind = Agent_stream) ?on_disconnect ~(auth : registration_auth) session_id ~last_event_id =
  match validate_registration ~auth session_id with
  | Error e -> Error e
  | Ok _credential ->
  let client_id = Atomic.fetch_and_add client_id_counter 1 + 1 in
  let last_event_id = Atomic.make last_event_id in
  let event_stream = Eio.Stream.create stream_capacity in
  Option.iter (fun hook -> set_disconnect_hook session_id hook) on_disconnect;
  let base_client = {
    id = client_id;
    kind;
    event_stream;
    last_event_id;
    created_at = 0.0;
    last_seen_at = Atomic.make 0.0;
  } in
  let evicted =
    Lockfree_atomic.update_with_commit clients (fun state ->
      run_test_hook register_commit_test_hook;
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
      let install_time = Time_compat.now () in
      let client = {
        base_client with
        created_at = install_time;
        last_seen_at = Atomic.make install_time;
      } in
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
       Transport_metrics.inc_sse_client_evicted ();
       Log.Server.info "Evicting oldest client %s (at cap %d)" sid max_clients;
       (* Eviction is a form of disconnect: the broadcast-registry entry
          is gone, so the evicted session's drain fiber will block on
          [Eio.Stream.take] forever unless we wake it.  Callers also
          invoke [stop_sse_session evicted_sid] explicitly today (legacy
          path); that double-invocation is idempotent because
          [close_sse_conn] guards on [info.closed]. *)
       invoke_disconnect_hook_for sid
   | None ->
       ());
  sync_transport_snapshot ~force:true ();
  Ok (client_id, event_stream, evicted)

(** Unregister an SSE client *)
let unregister session_id =
  let removed =
    Lockfree_atomic.update_with_commit clients (fun state ->
      if SMap.mem session_id state.entries then
        let next_entries = SMap.remove session_id state.entries in
        (* [state.count] is the authoritative cardinality maintained
           by every other [update_with_commit] in this module, so
           re-walking [next_entries] with [SMap.cardinal] (O(N) for
           [Stdlib.Map]) is wasted work.  Slow-client storms that
           fire [unregister] for each dropped session in
           [broadcast_impl]'s failed list paid this O(N) cost per
           call: N dropped × O(N) sweep = O(N²). *)
        {
          next_state = {
            entries = next_entries;
            count = state.count - 1;
          };
          result = true;
        }
      else
        {
          next_state = state;
          result = false;
        })
  in
  if removed then begin
    (* Invoke the per-session disconnect hook BEFORE [sync_transport_snapshot].
       The hook typically calls back into [Server_mcp_transport_http_conn.
       stop_sse_session], which closes the HTTP body writer and re-enters
       [unregister_if_current].  That re-entry is a no-op here because we
       already removed the entry above, so there is no double-decrement risk
       and no infinite-loop risk.  Snapshot recording is sequenced AFTER the
       hook so observers see [info.closed = true] in the same tick. *)
    invoke_disconnect_hook_for session_id;
    sync_transport_snapshot ~force:true ()
  end else
    (* Even on no-op unregister we still clear any orphaned hook to avoid
       slow leaks across reconnects.  [clear_disconnect_hook] is idempotent. *)
    clear_disconnect_hook session_id

(** Unregister only if the current client matches the given client_id.
    Prevents an old connection's cleanup from unregistering a newer connection
    that re-used the same session_id. *)
let unregister_if_current session_id client_id =
  let removed =
    Lockfree_atomic.update_with_commit clients (fun state ->
      match SMap.find_opt session_id state.entries with
      | Some client when client.id = client_id ->
          let next_entries = SMap.remove session_id state.entries in
          (* Same rationale as [unregister]: state.count is
             authoritative, [SMap.cardinal] is O(N) and unnecessary. *)
          {
            next_state = {
              entries = next_entries;
              count = state.count - 1;
            };
            result = true;
          }
      | _ ->
          {
            next_state = state;
            result = false;
          })
  in
  if removed then begin
    (* See [unregister] for the hook ordering rationale. *)
    invoke_disconnect_hook_for session_id;
    sync_transport_snapshot ~force:true ()
  end

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

let client_matches_target target ~jsonrpc_payload (client : client) =
  match target with
  | All -> (
      match client.kind with
      | Observer -> true
      | Agent_stream -> jsonrpc_payload
      | Presence -> false)
  | Observers -> client.kind = Observer
  | Agent_streams -> client.kind = Agent_stream && jsonrpc_payload
  | Presence_only -> client.kind = Presence

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
    Lockfree_atomic.update_with_commit external_subscribers (fun state ->
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
    Lockfree_atomic.update_with_commit external_subscribers (fun state ->
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
  Lockfree_atomic.update_with_commit external_subscribers (fun state ->
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
  let t0 = Time_compat.now () in
  let record_duration () =
    Transport_metrics.observe_external_subscriber_fanout_duration
      (Time_compat.now () -. t0)
  in
  try
    (* [Atomic.get] returns an immutable [SMap.t] snapshot — concurrent
       subscribe/unsubscribe builds a new map via [Lockfree_atomic.update_with_commit]
       and never mutates the one we hold here. So we can iterate the map
       directly without first materializing it as a list, saving one [cons]
       per subscriber per broadcast. At fleet sizes (14 keepers × dashboard
       subs ≈ 30-50) and high event rates this trims sustained allocation
       pressure on the hot fanout path. *)
    let subscribers = (Atomic.get external_subscribers).subscribers in
    let dead = ref [] in
    SMap.iter
      (fun _ (sub : external_subscriber) ->
        if not (sub.is_alive ())
        then dead := sub.sub_id :: !dead
        else
          try sub.callback event with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              (* P1 silent-failure fix: previously only logged.  Increment a
                 counter so dashboards distinguish "all subscribers healthy"
                 from "subscribers exist but every callback throws." *)
              Transport_metrics.inc_external_subscriber_callback_failure ();
              Log.Misc.warn "External subscriber %s failed: %s" sub.sub_id
                (Printexc.to_string exn))
      subscribers;
    (* Remove dead subscribers *)
    if !dead <> [] then begin
      let removed_ids, count = remove_external_subscribers !dead in
      List.iter
        (fun id -> Log.Misc.info "Auto-removed dead external subscriber: %s" id)
        removed_ids;
      if removed_ids <> [] then
        Transport_metrics.set_sse_external_subscribers count
    end;
    record_duration ()
  with
  | Eio.Cancel.Cancelled _ as e ->
      record_duration ();
      raise e

(** Actively reap dead external subscribers.
    Unlike [notify_external_subscribers] which only checks [is_alive] during
    broadcast delivery, this function proactively scans all subscribers and
    removes dead ones.  Call periodically from the background maintenance loop
    to prevent stale subscribers from accumulating when no broadcasts occur. *)
let reap_dead_external_subscribers () =
  (* Same rationale as [notify_external_subscribers]: the [SMap.t] from
     [Atomic.get] is immutable, so we iterate it directly instead of
     allocating a list snapshot first. *)
  let subscribers = (Atomic.get external_subscribers).subscribers in
  let dead = ref [] in
  SMap.iter (fun _ (sub : external_subscriber) ->
    if not (sub.is_alive ()) then
      dead := sub.sub_id :: !dead
  ) subscribers;
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
let broadcast_impl ?(buffer = true) ?(notify_external = true)
    ?(event_type = "message") target json =
  let t0 = Time_compat.now () in
  let jsonrpc_payload =
    Sse_jsonrpc_filter.jsonrpc_message_for_agent_stream json
  in
  (* Atomically allocate the event id so two concurrent broadcasts
     cannot observe the same peeked counter value and emit duplicates. *)
  let current_event_id = next_id () in
  (* Write JSON directly into the SSE event buffer, avoiding the
     intermediate [Yojson.Safe.to_string] allocation.  The output
     is byte-for-byte identical to the previous two-step approach. *)
  let event = format_event_yojson ~id:current_event_id ~event_type json in
  if buffer then
    buffer_event current_event_id event;
  (* The [SMap.t] returned by [Atomic.get] is immutable
     (Lockfree_atomic.update_with_commit replaces it wholesale on
     subscribe/unsubscribe), so we iterate it directly with [SMap.iter].
     Skipping the [(k, v) :: acc] fold trims one tuple + cons cell per
     client per broadcast on this hot fan-out path. *)
  let target_label = match target with
    | All -> "all"
    | Observers -> "observers"
    | Agent_streams -> "agent_streams"
    | Presence_only -> "presence"
  in
  let clients_entries = (Atomic.get clients).entries in
  let failed = ref [] in
  SMap.iter (fun session_id client ->
    if client_matches_target target ~jsonrpc_payload client
       && current_event_id > Atomic.get client.last_event_id then begin
      (* Pre-check stream capacity to avoid blocking broadcast.
         No TOCTOU risk: single-domain Eio cooperative scheduling has no
         yield point between Stream.length and Stream.add, so no other
         fiber can modify the stream in between.  try/catch kept as
         defense-in-depth for unexpected failures.
         See TLA+ SSEBroadcastBlock spec. *)
      (let queue_len = Eio.Stream.length client.event_stream in
       if queue_len >= stream_capacity then begin
         (* Tier-A perf fix: queue overflow is now a {b disconnect}
            signal, not a silent drop.  The session is added to
            [failed] (so [unregister] runs below); the disconnect hook
            installed at register-time wakes the drain fiber via
            [stop_sse_session], closing the HTTP writer.  The client's
            EventSource will reconnect with [Last-Event-Id]; the bumped
            [max_buffer_size] (1000 vs. previous 100) covers the gap.

            Previously the [unregister] removed the broadcast entry but
            left the drain fiber blocked on [Eio.Stream.take], holding
            the HTTP socket open until keep-alive timeout — operators
            saw "WS events stop arriving" with no error indication and
            had to manually refresh.  See plan
            [planning/claude-plans/me-workspace-yousleepwhen-masc-radiant-piglet.md]. *)
         Transport_metrics.inc_broadcast_failure ~target:target_label ();
         Log.Server.warn
           "Broadcast skip: session %s stream full (%d/%d) — disconnecting"
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
             (* Same P1 fix on the unexpected-exception defense path. *)
             Transport_metrics.inc_broadcast_failure ~target:target_label ();
             Log.Server.error "Broadcast enqueue failed for session %s: %s"
               session_id (Printexc.to_string e);
             failed := session_id :: !failed)
    end
  ) clients_entries;
  (* Remove failed connections *)
  List.iter (fun sid -> unregister sid) !failed;
  (* Record broadcast duration for transport observability *)
  let elapsed = Time_compat.now () -. t0 in
  Transport_metrics.observe_broadcast_duration ~target:target_label elapsed;
  sync_transport_snapshot ();
  (* Notify external subscribers (gRPC streams, etc.) for durable broadcast
     traffic only. Presence is intentionally live-only and bufferless. *)
  if notify_external then
    notify_external_subscribers event

(** Broadcast event to all connected clients (backward-compatible). *)
let broadcast json = broadcast_impl All json

(** Broadcast event to sessions matching [target].
    - [All]: every session (same as [broadcast])
    - [Observers]: dashboard / read-only viewers only
    - [Agent_streams]: MCP agent sessions only *)
let broadcast_to target json = broadcast_impl target json

(** Broadcast an ephemeral presence/awareness event. Presence events are live
    only: they are not replay-buffered and do not fan out through generic
    external subscribers. Durable consumers continue to receive the caller's
    normal [broadcast] / [broadcast_to] emission. *)
let broadcast_presence json =
  broadcast_impl ~buffer:false ~notify_external:false ~event_type:"presence"
    Presence_only json

(** Send a JSON-RPC message to a specific session.
    Enqueues the event in the session's stream for asynchronous delivery. *)
let send_to session_id json =
  if not (Sse_jsonrpc_filter.jsonrpc_message_for_agent_stream json) then
    Log.Server.warn
      "Dropping non-JSON-RPC payload sent via Sse.send_to for session %s"
      session_id
  else
  let current_event_id = next_id () in
  let event = format_event_yojson ~id:current_event_id ~event_type:"message" json in
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

let client_count_by_kind kind =
  SMap.fold
    (fun _session_id (client : client) count ->
       if client.kind = kind then count + 1 else count)
    (Atomic.get clients).entries
    0

(** Return list of session_ids for all connected clients.
    Used by transport metrics to report session count by kind. *)
let all_session_ids () =
  SMap.fold (fun sid _client acc -> sid :: acc) (Atomic.get clients).entries []

(** Close all SSE clients - for graceful shutdown.
    Returns the number of clients that were closed. *)
let close_all_clients () =
  let sessions =
    Lockfree_atomic.update_with_commit clients (fun state ->
      let sessions = SMap.fold (fun sid _ acc -> sid :: acc) state.entries [] in
      {
        next_state = empty_client_registry_state;
        result = sessions;
      })
  in
  sync_transport_snapshot ~force:true ();
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
    Transport_metrics.inc_sse_idle_evicted ();
    unregister sid
  ) stale;
  List.map fst stale

let () =
  Dashboard_oas_bridge.set_broadcast_hook (fun json ->
    broadcast_to Observers json)
