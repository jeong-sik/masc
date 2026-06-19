(** WebSocket Transport for MASC MCP.

    Provides bidirectional JSON-RPC messaging over WebSocket,
    replacing SSE for dashboard/agent connections that need
    full-duplex communication.

    Upgrade path: GET /ws with Connection: Upgrade header.
    Uses httpun-ws for the WebSocket protocol on top of httpun.

    Outbound events: registered as an Sse external subscriber,
    so all broadcast events are forwarded to WebSocket clients.

    Inbound messages: JSON-RPC requests are dispatched to the
    same tool dispatcher used by the MCP HTTP transport. *)

(** SHA1 function required by httpun-ws handshake. *)
let sha1 s =
  Digestif.SHA1.(digest_string s |> to_raw_string)

(** Dashboard authentication state for a WebSocket session.  Set once by
    [dashboard_hello] and then read on the SSE forward hot path and the
    dashboard RPC auth gates.  Held in an [Atomic.t] on the session
    ([dashboard_auth]) so the single write and the many reads stay tear-free
    if dashboard serving moves off the main Eio domain (RFC-0204 §8.4,
    Phase 1).  [Authenticated] carries the resolved agent name, or [None]
    when the auth config permits tokenless dashboard reads. *)
type dashboard_auth_state =
  | Unauthenticated
  | Authenticated of { agent : string option }

(** Active WebSocket session state. *)
type ws_session = {
  id: string;
  wsd: Httpun_ws.Wsd.t;
  closed: bool Atomic.t;
  (** All writes to [wsd] (text frames, pings, pongs, close) are serialized
      through [write_mutex] so fibers sharing one connection cannot interleave
      frames or race with a concurrent close. *)
  write_mutex: Eio.Mutex.t;
  (** Last time a WebSocket pong frame was received from the client (or the
      time the connection opened, before any pong).  The heartbeat closes the
      session once it has gone [threshold] whole intervals without a pong; a
      client that keeps answering refreshes this and is never closed.  This is
      the single liveness signal — there is no separate tick counter that a
      responsive client could accumulate against (#21509). *)
  last_pong_at: float Atomic.t;
  dashboard_auth: dashboard_auth_state Atomic.t;
  mutable dashboard_route: string option;
  dashboard_slices: (string, unit) Hashtbl.t;
  mutable dashboard_seq: int;
  (** Last seq value the client has acknowledged.  0 until the first ack
      arrives.  Paired with {!dashboard_last_buffered_amount} so the server
      can reason about client liveness without touching the wire. *)
  mutable dashboard_last_ack_seq: int;
  (** Last [WebSocket.bufferedAmount] the client reported in a
      [dashboard/ack] notification.  A growing value is a leading indicator
      that the client cannot drain deltas as fast as the server pushes them;
      sustained growth should eventually gate further sends.  Observability
      lands first — gating is a follow-up once thresholds are established
      from production distributions. *)
  mutable dashboard_last_buffered_amount: int;
  (** Last wall-clock time a [dashboard/ack] notification arrived.  A
      subscribed dashboard that stops ACKing can keep a low bufferedAmount
      forever. *)
  mutable dashboard_last_ack_at: float;
  (** Last dashboard/delta seq that expects a browser [dashboard/ack].  Snapshot
      seqs are intentionally excluded because the browser only ACKs deltas. *)
  mutable dashboard_last_delta_seq: int;
  mutable dashboard_last_delta_at: float;
  mutable inbound_partial_text: Buffer.t option;
  mutable inbound_partial_text_bytes: int;
}

(** [true] when the dashboard handshake has completed for this state. *)
let dashboard_auth_is_authenticated = function
  | Unauthenticated -> false
  | Authenticated _ -> true

(** Resolved agent name for an authenticated state, [None] otherwise. *)
let dashboard_auth_agent = function
  | Unauthenticated -> None
  | Authenticated { agent } -> agent

(** Reads a session's current dashboard auth state (wait-free). *)
let dashboard_auth session = Atomic.get session.dashboard_auth

(** Registry of active WebSocket sessions. *)
let sessions : (string, ws_session) Hashtbl.t = Hashtbl.create 16
let sessions_mutex = Eio.Mutex.create ()

let with_sessions_rw f = Eio_guard.with_mutex sessions_mutex f

(** Side index mapping each dashboard slice to the set of session IDs
    currently subscribed to it.  Phase 1 of the slice-indexed fanout RFC
    (#10119): the index is maintained at subscribe / unsubscribe / cleanup
    time but the broadcast fanout still iterates every session.  Phase 2
    consults this index to skip raw-SSE-forwards to sessions whose route
    does not subscribe to the event's slice.

    Inner [Hashtbl.t] is keyed by [session_id] with [unit] values — a set.
    Mutated only under [sessions_mutex], so the consistency invariant
    matches [sessions]: a session present in [slice_index.(s)] is present
    in [sessions] until [cleanup_session] runs. *)
let slice_index : (string, (string, unit) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 8

let slice_index_add_locked ~session_id ~slice =
  let set =
    match Hashtbl.find_opt slice_index slice with
    | Some s -> s
    | None ->
        let s = Hashtbl.create 4 in
        Hashtbl.add slice_index slice s;
        s
  in
  Hashtbl.replace set session_id ()

let slice_index_remove_locked ~session_id ~slice =
  match Hashtbl.find_opt slice_index slice with
  | None -> ()
  | Some set ->
      Hashtbl.remove set session_id;
      if Hashtbl.length set = 0 then Hashtbl.remove slice_index slice

let slice_index_remove_session_locked session_id =
  Hashtbl.iter
    (fun _slice set -> Hashtbl.remove set session_id)
    slice_index;
  Hashtbl.filter_map_inplace
    (fun _slice set -> if Hashtbl.length set = 0 then None else Some set)
    slice_index

(** Test/debug helper: return the session IDs currently indexed under
    [slice], in unspecified order.  Acquires [sessions_mutex]. *)
let slice_index_subscribers slice =
  with_sessions_rw (fun () ->
      match Hashtbl.find_opt slice_index slice with
      | None -> []
      | Some set -> Hashtbl.fold (fun sid () acc -> sid :: acc) set [])

(** Test/debug helper: total (slice × session) entries across all slices.
    Equals the sum of subscribed-slice counts over every session. *)
let slice_index_size () =
  with_sessions_rw (fun () ->
      Hashtbl.fold
        (fun _slice set acc -> acc + Hashtbl.length set)
        slice_index 0)

(** Test-only: drive the slice index without needing a fully constructed
    WS session.  Production code paths reach the same helpers via
    [dashboard_subscribe] / [dashboard_unsubscribe] / [cleanup_session]. *)
let __test_slice_index_add ~session_id ~slice =
  with_sessions_rw (fun () -> slice_index_add_locked ~session_id ~slice)

let __test_slice_index_remove ~session_id ~slice =
  with_sessions_rw (fun () -> slice_index_remove_locked ~session_id ~slice)

let __test_slice_index_remove_session session_id =
  with_sessions_rw (fun () -> slice_index_remove_session_locked session_id)

(** Generate a unique session ID. *)
let next_id =
  let counter = Atomic.make 0 in
  fun () ->
    let n = Atomic.fetch_and_add counter 1 in
    Printf.sprintf "ws-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) n

let log_ws_delivery_dropped ~context session_id =
  Log.Transport.warn "WS %s not delivered for session=%s" context session_id

let new_session ~id ~wsd =
  (* NDT-OK: session creation stamps wall-clock liveness/ACK metadata only;
     message ordering and protocol output still come from explicit sequence IDs. *)
  let now = Unix.gettimeofday () in
  {
    id;
    wsd;
    closed = Atomic.make false;
    write_mutex = Eio.Mutex.create ();
    last_pong_at = Atomic.make now;
    dashboard_auth = Atomic.make Unauthenticated;
    dashboard_route = None;
    dashboard_slices = Hashtbl.create 8;
    dashboard_seq = 0;
    dashboard_last_ack_seq = 0;
    dashboard_last_buffered_amount = 0;
    dashboard_last_ack_at = now;
    dashboard_last_delta_seq = 0;
    dashboard_last_delta_at = now;
    inbound_partial_text = None;
    inbound_partial_text_bytes = 0;
  }

(** [true] when the session has been closed locally or the httpun-ws writer has
    shut down.  Reads the atomic [closed] flag and the WSD state; safe from any
    fiber. *)
let is_session_closed session =
  Atomic.get session.closed || Httpun_ws.Wsd.is_closed session.wsd

(** Record a client pong: refresh [last_pong_at].  Called from the WS frame
    handler on every [Pong] frame; this is the liveness signal the heartbeat
    reads via {!heartbeat_should_close} (#21509). *)
let record_pong session =
  Atomic.set session.last_pong_at (Unix.gettimeofday ())
(* NDT-OK: wall-clock used only for liveness, not deterministic output. *)

(** Send a pre-allocated frame to a WebSocket client.

    The caller owns the [bytes] buffer; this function only reads it.  In
    server mode httpun-ws does not mask (see httpun-ws 0.2.0
    [Serialize.serialize_bytes]: [apply_mask_bytes] is only called when
    [mode = `Client]), and [Faraday.write_bytes] copies into its internal
    buffer synchronously, so the same [bytes] value can safely be passed
    to multiple sessions in one broadcast without re-allocation. *)
let send_frame_bytes session bytes ~len =
  if is_session_closed session then begin
    Atomic.set session.closed true;
    false
  end else begin
    Eio_guard.with_mutex session.write_mutex (fun () ->
      if is_session_closed session then false
      else begin
        try
          Httpun_ws.Wsd.send_bytes session.wsd
            ~kind:`Text bytes ~off:0 ~len;
          Transport_metrics.inc_ws_bytes_sent ~bytes:len;
          Transport_metrics.observe_ws_message_bytes_sent len;
          true
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Transport.warn "WS text send failed for session=%s: %s" session.id
            (Printexc.to_string exn);
          Atomic.set session.closed true;
          false
      end)
  end

(** WebSocket text frames must contain valid UTF-8.  Raw SSE broadcasts can
    include tool/provider output bytes that are valid for local persistence but
    invalid as browser WebSocket text, so repair at the final wire boundary. *)
let websocket_text_payload text =
  Inference_utils.sanitize_text_utf8 text

(** Send a text frame to a WebSocket client.
    Allocates [Bytes.t] per call — fine for single-destination sends.
    Multicast paths should go through [send_text_shared] instead so the
    bytes allocation is paid once per broadcast, not once per session. *)
let send_text session text =
  let bytes = Bytes.of_string (websocket_text_payload text) in
  send_frame_bytes session bytes ~len:(Bytes.length bytes)

(** Module-local cache of the last [Bytes.of_string sse_event] result.

    [Sse.notify_external_subscribers] delivers the same [event: string]
    reference to every subscribed WS session in sequence.  Before this
    cache, every session ran [Bytes.of_string] independently in the
    raw-SSE-forward path, producing O(sessions) identical allocations.
    Keyed by physical equality so a fresh broadcast invalidates it. *)
let bytes_cache : (string * Bytes.t) Atomic.t =
  Atomic.make ("", Bytes.empty)

let bytes_of_shared_text text =
  let cached_str, cached_bytes = Atomic.get bytes_cache in
  if cached_str == text then begin
    Transport_metrics.inc_ws_bytes_cache_hit ();
    cached_bytes
  end
  else begin
    Transport_metrics.inc_ws_bytes_cache_miss ();
    let bytes = Bytes.of_string (websocket_text_payload text) in
    Atomic.set bytes_cache (text, bytes);
    bytes
  end

(** Send a text frame that will also be sent to other sessions in this
    broadcast.  Allocates [Bytes.of_string text] once per unique string
    reference; subsequent sessions in the same fanout reuse the bytes. *)
let send_text_shared session text =
  let bytes = bytes_of_shared_text text in
  send_frame_bytes session bytes ~len:(Bytes.length bytes)

let send_text_checked ~context session text =
  let sent = send_text session text in
  if not sent then log_ws_delivery_dropped ~context session.id;
  sent

let send_text_shared_checked ~context session text =
  let sent = send_text_shared session text in
  if not sent then log_ws_delivery_dropped ~context session.id;
  sent

let send_json_checked ~context session json =
  send_text_checked ~context session (Yojson.Safe.to_string json)

let jsonrpc_notification method_ params =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("method", `String method_);
      ("params", params);
    ]

let next_dashboard_seq session =
  session.dashboard_seq <- session.dashboard_seq + 1;
  session.dashboard_seq

let valid_dashboard_slice = function
  | "shell"
  | "execution"
  | "operator"
  | "transport"
  | "namespace"
  | "composite"
  | "board"
  | "goals" ->
      true
  | _ -> false

let dashboard_slice_for_sse_type = function
  | "project_snapshot" | "namespace_truth_snapshot" ->
      Some "namespace"
  | "execution_snapshot" ->
      Some "execution"
  | "operator_snapshot" | "operator_digest" ->
      Some "operator"
  | "transport_health_snapshot" ->
      Some "transport"
  | "keeper_composite_changed" ->
      Some "composite"
  | _ -> None

let dashboard_session_result session =
  let slices =
    Hashtbl.fold (fun slice () acc -> `String slice :: acc)
      session.dashboard_slices []
    |> List.sort compare
  in
  let auth = dashboard_auth session in
  `Assoc
    [
      ("protocol", `String "dashboard-ws.v1");
      ("session_id", `String session.id);
      ("authenticated", `Bool (dashboard_auth_is_authenticated auth));
      ( "agent", Json_util.string_opt_to_json (dashboard_auth_agent auth) );
      ( "route", Json_util.string_opt_to_json session.dashboard_route );
      ("slices", `List slices);
      ("seq", `Int session.dashboard_seq);
    ]

let find_session session_id =
  with_sessions_rw (fun () -> Hashtbl.find_opt sessions session_id)

let dashboard_snapshot_provider : (string -> Yojson.Safe.t option) ref =
  ref (fun _slice -> None)

let set_dashboard_snapshot_provider provider =
  dashboard_snapshot_provider := provider

let dashboard_auth_success_payload session =
  `Assoc
    [
      ("protocol", `String "dashboard-ws.v1");
      ("session", dashboard_session_result session);
      ( "capabilities",
        `Assoc
          [
            ("snapshot", `Bool true);
            ("delta", `Bool true);
            ("mode_snapshot", `Bool true);
          ] );
    ]

let verify_dashboard_token ~base_path token =
  let auth_cfg = Auth.load_auth_config base_path in
  if not auth_cfg.Masc_domain.enabled then
    Ok None
  else
    match token with
    | None when not auth_cfg.require_token ->
        (match Auth.check_permission base_path ~agent_name:"dashboard"
                 ~token:None ~permission:Masc_domain.CanReadState with
         | Ok () -> Ok None
         | Error err -> Error (Masc_domain.masc_error_to_string err))
    | None ->
        Error "dashboard/hello requires a bearer token"
    | Some raw_token -> (
        match Auth.find_credential_by_token base_path ~token:raw_token with
        | Error err -> Error (Masc_domain.masc_error_to_string err)
        | Ok cred -> (
            match
              Auth.check_permission base_path ~agent_name:cred.Masc_domain.agent_name
                ~token:(Some raw_token) ~permission:Masc_domain.CanReadState
            with
            | Ok () -> Ok (Some cred.Masc_domain.agent_name)
            | Error err -> Error (Masc_domain.masc_error_to_string err)))

let dashboard_hello ~base_path ~session_id ?token () =
  let start_time = Unix.gettimeofday () in
  let result =
    match find_session session_id with
    | None -> Error "WebSocket session not found"
    | Some session -> (
        match verify_dashboard_token ~base_path token with
        | Error msg -> Error msg
        | Ok agent ->
            (* Single writer per session: dashboard_hello is the only site
               that sets the auth state, so Atomic.set (not compare_and_set)
               is sufficient.  Revisit if a second writer is introduced. *)
            Atomic.set session.dashboard_auth (Authenticated { agent });
            Ok (dashboard_auth_success_payload session))
  in
  Transport_metrics.observe_ws_dashboard_hello_latency
    ~success:(match result with Ok _ -> true | Error _ -> false)
    (Unix.gettimeofday () -. start_time);
  result

let dashboard_snapshot session =
  let slices =
    Hashtbl.fold
      (fun slice () acc ->
        match !dashboard_snapshot_provider slice with
        | Some json -> (slice, json) :: acc
        | None -> acc)
      session.dashboard_slices []
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  `Assoc
    [
      ("protocol", `String "dashboard-ws.v1");
      ("seq", `Int (next_dashboard_seq session));
      ( "route", Json_util.string_opt_to_json session.dashboard_route );
      ("slices", `Assoc slices);
    ]

let dashboard_subscribe ~session_id ?route ~slices () =
  match find_session session_id with
  | None -> Error "WebSocket session not found"
  | Some session ->
      if not (dashboard_auth_is_authenticated (dashboard_auth session)) then
        Error "dashboard/subscribe requires dashboard/hello first"
      else begin
        let invalid =
          List.filter (fun slice -> not (valid_dashboard_slice slice)) slices
        in
        match invalid with
        | bad :: _ ->
            Error (Printf.sprintf "unsupported dashboard slice: %s" bad)
        | [] ->
            with_sessions_rw (fun () ->
                slice_index_remove_session_locked session_id;
                Hashtbl.clear session.dashboard_slices;
                List.iter
                  (fun slice ->
                    Hashtbl.replace session.dashboard_slices slice ();
                    slice_index_add_locked ~session_id ~slice)
                  slices);
            session.dashboard_route <- route;
            Ok
              (`Assoc
                [
                  ("session", dashboard_session_result session);
                  ("snapshot", dashboard_snapshot session);
                ])
      end

let dashboard_unsubscribe ~session_id ?slices () =
  match find_session session_id with
  | None -> Error "WebSocket session not found"
  | Some session ->
      if not (dashboard_auth_is_authenticated (dashboard_auth session)) then
        Error "dashboard/unsubscribe requires dashboard/hello first"
      else begin
        with_sessions_rw (fun () ->
            match slices with
            | None ->
                Hashtbl.clear session.dashboard_slices;
                slice_index_remove_session_locked session_id
            | Some slices ->
                List.iter
                  (fun slice ->
                    Hashtbl.remove session.dashboard_slices slice;
                    slice_index_remove_locked ~session_id ~slice)
                  slices);
        Ok (`Assoc [ ("session", dashboard_session_result session) ])
      end

let dashboard_ping ~session_id () =
  match find_session session_id with
  | None -> Error "WebSocket session not found"
  | Some session ->
      if not (dashboard_auth_is_authenticated (dashboard_auth session)) then
        Error "dashboard/ping requires dashboard/hello first"
      else
        Ok
          (`Assoc
            [
              ("ok", `Bool true);
              ("session_id", `String session.id);
              ("seq", `Int session.dashboard_seq);
            ])

let dashboard_ack ~session_id ~seq ?buffered_amount () =
  match find_session session_id with
  | None -> Error "WebSocket session not found"
  | Some session ->
      if not (dashboard_auth_is_authenticated (dashboard_auth session)) then
        Error "dashboard/ack requires dashboard/hello first"
      else begin
        session.dashboard_last_ack_at <- Time_compat.now ();
        if seq > session.dashboard_last_ack_seq then
          session.dashboard_last_ack_seq <- seq;
        (match buffered_amount with
         | Some n when n >= 0 ->
             session.dashboard_last_buffered_amount <- n;
             Transport_metrics.observe_ws_client_buffered_bytes n
         | _ -> ());
        Ok
          (`Assoc
            [
              ("session_id", `String session.id);
              ("ack", `Int seq);
              ("server_last_ack_seq", `Int session.dashboard_last_ack_seq);
              ("server_last_buffered_amount",
                `Int session.dashboard_last_buffered_amount);
            ])
      end

(** Shape of an SSE event after dashboard-oriented parsing.
    [slice] is [None] when the event does not map to a dashboard slice,
    in which case delivery falls through to raw SSE forwarding.
    [broadcast_ts] is sampled once at parse-cache miss and reused for
    every session in the same fanout, so all deltas built from one
    broadcast carry identical [ts_unix].  This is semantic correctness
    (one logical emission moment) and a prerequisite for future
    per-broadcast delta-template caching. *)
type parsed_sse_event = {
  event_type: string;
  slice: string option;
  payload: Yojson.Safe.t;
  broadcast_ts: float;
}

(** Per-broadcast parse cache.

    [Sse.notify_external_subscribers] passes the same [event: string]
    reference to each subscriber callback in sequence, so consecutive
    WS sessions all see the identical pointer for one broadcast.  Caching
    the parse result keyed by physical equality collapses O(sessions)
    JSON parses per event down to 1.

    Correctness: on miss we parse and replace; no torn state is possible
    (Atomic write is atomic).  A concurrent broadcast at worst wastes one
    parse — it never yields a wrong result for a different [sse_event].
    Physical equality is safe here because the snapshot loop holds the
    event string alive for the duration of fanout. *)
let parse_cache : (string * parsed_sse_event option) Atomic.t =
  Atomic.make ("", None)

(** Extract the JSON body from an SSE-formatted event string.

    [Sse.format_event] emits [data: <body>] today, but the parser should
    not depend on that line staying in a fixed position.  External
    subscribers receive the full SSE-formatted string (gRPC stuffs it
    into payload_json verbatim and lets the gRPC client re-parse), so the
    WS callback must peel the SSE wrapper before feeding
    [Yojson.Safe.from_string].

    The earlier implementation skipped this step, so every production
    parse failed and dashboard_delta_for_sse always fell through to
    raw-SSE-forward — defeating the parse cache, slice-aware fanout
    (Phase 2 of #10119), and delta-built counter.  Pure-JSON inputs
    (the unit-test path) still work via the [_ -> Some sse_event]
    fallback. *)
let sse_data_prefix = "data:"

let extract_sse_data_payload_line line =
  if String.starts_with ~prefix:sse_data_prefix line then
    let line_len = String.length line in
    let prefix_len = String.length sse_data_prefix in
    (* Per RFC: a single optional space follows "data:". Fold the skip
       into the same [String.sub] to avoid an intermediate allocation
       on the dashboard fanout hot path (~1 alloc per SSE data line). *)
    let start =
      if line_len > prefix_len && Char.equal line.[prefix_len] ' '
      then prefix_len + 1
      else prefix_len
    in
    Some (String.sub line start (line_len - start))
  else None

let extract_sse_data_line sse_event =
  match
    String.split_on_char '\n' sse_event
    |> List.filter_map extract_sse_data_payload_line
  with
  | [] ->
      (* Not an SSE data event — pass through as-is so unit tests that
         hand us pure JSON keep working. *)
      Some sse_event
  | data_lines -> Some (String.concat "\n" data_lines)

let parse_sse_dashboard_event sse_event =
  let cached_str, cached_val = Atomic.get parse_cache in
  if cached_str == sse_event then begin
    Transport_metrics.inc_ws_parse_cache_hit ();
    cached_val
  end
  else begin
    Transport_metrics.inc_ws_parse_cache_miss ();
    let result =
      match extract_sse_data_line sse_event with
      | None -> None
      | Some json_body ->
        match Yojson.Safe.from_string json_body with
        | exception (Yojson.Json_error msg) ->
            (* Iter 28: previously silently dropped — now emit a counter
               and a warn with a size-bounded body preview so operators
               can detect malformed frames from clients. Behavior is
               preserved (still returns None). *)
            let preview_len = min 200 (String.length json_body) in
            Log.Server.warn
              "[mcp-ws] dropping incoming frame: malformed JSON (%s); \
               body_preview=%s"
              msg
              (String.sub json_body 0 preview_len);
            Transport_metrics.inc_ws_frame_json_parse_failure
              ~error_kind:Transport_metrics.Yojson_parse_error;
            None
        | exception Eio.Cancel.Cancelled e -> raise (Eio.Cancel.Cancelled e)
        | exception exn ->
            let preview_len = min 200 (String.length json_body) in
            Log.Server.warn
              "[mcp-ws] dropping incoming frame: %s; body_preview=%s"
              (Printexc.to_string exn)
              (String.sub json_body 0 preview_len);
            Transport_metrics.inc_ws_frame_json_parse_failure
              ~error_kind:Transport_metrics.Other_ws_frame_json_parse_error;
            None
        | `Assoc fields as event_json -> (
            match List.assoc_opt "type" fields with
            | Some (`String event_type) ->
                let payload =
                  match List.assoc_opt "payload" fields with
                  | Some payload -> payload
                  | None -> event_json
                in
                let slice = dashboard_slice_for_sse_type event_type in
                let broadcast_ts = Time_compat.now () in
                Some { event_type; slice; payload; broadcast_ts }
            | _ -> None)
        | _ -> None
    in
    Atomic.set parse_cache (sse_event, result);
    result
  end

(** Build a dashboard/delta notification from an already-parsed SSE
    event when the session subscribes to its slice.  Pulled out of the
    earlier [dashboard_delta_for_sse] so callers that already have the
    parsed event in hand do not re-enter [parse_sse_dashboard_event]
    just to feed it back through; see [send_dashboard_or_raw_sse]. *)
let dashboard_delta_for_parsed session parsed =
  match parsed with
  | Some { event_type; slice = Some slice; payload; broadcast_ts }
    when Hashtbl.mem session.dashboard_slices slice ->
      Transport_metrics.inc_ws_delta_built ();
      let seq = next_dashboard_seq session in
      session.dashboard_last_delta_seq <- seq;
      session.dashboard_last_delta_at <- Time_compat.now ();
      Some
        (jsonrpc_notification "dashboard/delta"
           (`Assoc
             [
               ("protocol", `String "dashboard-ws.v1");
               ("seq", `Int seq);
               ("slice", `String slice);
               ("event_type", `String event_type);
               ("mode", `String "snapshot");
               ("payload", payload);
               ("ts_unix", `Float broadcast_ts);
             ]))
  | _ -> None

let dashboard_delta_for_sse session sse_event =
  dashboard_delta_for_parsed session (parse_sse_dashboard_event sse_event)

(** TTL cache for env-var reads on the fan-out hot path.

    [client_buffer_limit_bytes] and [slice_index_enabled] are both
    invoked once per session per broadcast, so a 100-session fanout
    at 1000 broadcasts/sec produced 200k [Sys.getenv_opt] calls per
    second per var.  The earlier docstring claimed the read was
    "atomic hash lookup", but [Env_config_core.raw_value_opt] runs
    [Sys.getenv_opt] which on glibc is a linear search of the
    process [environ] array — far from free.

    Cache the resolved value with a short TTL ([env_cache_ttl_s])
    so an operator-initiated retune still takes effect within the
    next half-second, while steady-state fanout pays the full env
    read at most twice per second per var.  CAS races on
    [Atomic.set] are benign because the env value did not change
    in the cached window — both racers compute the same number. *)
let env_cache_ttl_s = 0.5

let client_buffer_limit_cache : (float * int) Atomic.t =
  Atomic.make (Float.neg_infinity, 0)

let client_buffer_limit_bytes () =
  let now = Time_compat.now () in
  let last_at, cached = Atomic.get client_buffer_limit_cache in
  if now -. last_at < env_cache_ttl_s then cached
  else begin
    let value =
      Env_config_core.get_int ~default:1048576
        "MASC_WS_CLIENT_BUFFER_LIMIT_BYTES"
    in
    Atomic.set client_buffer_limit_cache (now, value);
    value
  end

let dashboard_ack_stale_threshold_s () =
  Env_config_core.get_float_nonneg ~default:30.0
    "MASC_WS_ACK_STALE_THRESHOLD_SEC"

let dashboard_ack_is_stale
    ~now
    ~last_delta_at
    ~last_delta_seq
    ~last_ack_seq
    ~threshold_s =
  last_delta_seq > last_ack_seq && threshold_s > 0.0
  && now -. last_delta_at > threshold_s

(** True when the session has reported enough outstanding bytes that
    another push will only grow the client's buffer further, or when the
    dashboard has stopped sending ACKs for too long.  Only authenticated
    dashboard sessions participate; anonymous sessions always pass. *)
let session_is_backpressured session =
  if not (dashboard_auth_is_authenticated (dashboard_auth session)) then false
  else
    let limit = client_buffer_limit_bytes () in
    let buffered_limit_exceeded =
      limit > 0 && session.dashboard_last_buffered_amount >= limit
    in
    let ack_stale =
      dashboard_ack_is_stale
        ~now:(Time_compat.now ())
        ~last_delta_at:session.dashboard_last_delta_at
        ~last_delta_seq:session.dashboard_last_delta_seq
        ~last_ack_seq:session.dashboard_last_ack_seq
        ~threshold_s:(dashboard_ack_stale_threshold_s ())
    in
    buffered_limit_exceeded || ack_stale

(** RFC #10119 Phase 2 gate.  When enabled (default since the bandwidth
    burst hardening pass), slice-scoped events skip the raw-SSE-forward
    to authenticated sessions whose route does not subscribe to the
    event's slice.  Catch-all events (no slice mapping) still reach
    every session.  Set [MASC_WS_SLICE_INDEX_ENABLED=false] only as an
    emergency rollback.  TTL-cached so a fanout pays at most one env
    resolution per [env_cache_ttl_s] window; same CAS-race semantics
    as [client_buffer_limit_bytes]. *)
let slice_index_enabled_cache : (float * bool) Atomic.t =
  Atomic.make (Float.neg_infinity, true)

let slice_index_enabled () =
  let now = Time_compat.now () in
  let last_at, cached = Atomic.get slice_index_enabled_cache in
  if now -. last_at < env_cache_ttl_s then cached
  else begin
    let value =
      Env_config_core.get_bool ~default:true
        "MASC_WS_SLICE_INDEX_ENABLED"
    in
    Atomic.set slice_index_enabled_cache (now, value);
    value
  end

(** Test-only: invalidate the env-var TTL caches above so back-to-back
    tests that flip [Unix.putenv] do not see stale resolved values.
    Production code never calls this. *)
let __test_reset_env_caches () =
  Atomic.set client_buffer_limit_cache (Float.neg_infinity, 0);
  Atomic.set slice_index_enabled_cache (Float.neg_infinity, true)

let send_dashboard_or_raw_sse session sse_event =
  if session_is_backpressured session then begin
    (* Drop the delivery rather than queue it.  Next ack after the client
       drains will let traffic resume; in the meantime [masc_ws_throttled_
       deliveries_total] advances so operators can see the circuit is
       open.  Returning [true] keeps the SSE external-subscriber loop
       from treating this as a fatal send failure — the session is still
       live, just temporarily silenced. *)
    Transport_metrics.inc_ws_throttled_delivery ();
    true
  end
  else if dashboard_auth_is_authenticated (dashboard_auth session) then begin
    (* Parse once and reuse for both the delta-build branch and the
       slice-mismatch decision.  parse_sse_dashboard_event hits a
       single-slot Atomic cache after the broadcast's first call, but
       even the cache-hit path costs an Atomic.get + physical eq +
       counter increment per invocation — so calling it twice per
       session per broadcast doubles those constants for no signal
       difference.  At fanout fleet scale (100+ authenticated dashboard
       sessions) the second call is pure overhead. *)
    let parsed = parse_sse_dashboard_event sse_event in
    match dashboard_delta_for_parsed session parsed with
    | Some delta ->
        (* Delta carries a per-session [seq], so the encoded text is unique
           per session and cannot be shared. *)
        send_json_checked ~context:"dashboard-delta" session delta
    | None ->
        (* Two sub-cases lead here:
           1. The event has a parsed slice but this session's route is
              not subscribed.  Today we raw-forward anyway so the client
              can hydrate its store via [handleRawPush].  With the
              slice-index gate enabled (RFC #10119 Phase 2) we skip
              instead, since the client cannot do anything useful with
              a slice it did not request and the wire write is pure
              waste at the dashboard fleet's scale.
           2. The event has no slice mapping (parse miss or unknown
              event_type).  This is the catch-all path and must still
              raw-forward so events outside the slice vocabulary still
              reach authenticated sessions.

           [parsed] (captured above) is the source of truth for which
           case applies.  A [Some _] result with a [Some slice] field
           means case 1 (slice known, session did not subscribe —
           [dashboard_delta_for_parsed] would have returned [Some]
           otherwise).  Anything else is case 2. *)
        let is_slice_mismatch =
          match parsed with
          | Some { slice = Some _; _ } -> true
          | _ -> false
        in
        if is_slice_mismatch && slice_index_enabled () then begin
          Transport_metrics.inc_ws_slice_fanout_skipped ();
          true
        end
        else
          (* Same event string is forwarded verbatim to every session that
             does not match a subscribed dashboard slice; the shared cache
             collapses N identical [Bytes.of_string] allocations into 1. *)
          send_text_shared_checked ~context:"sse-forward" session sse_event
  end
  else begin
    (* Unauthenticated session: drop SSE events until dashboard/hello
       completes.  Forwarding before hello floods the client with SSE
       frames that can bury the JSON-RPC hello response, causing the
       browser RPC timeout to fire and triggering a reconnect loop. *)
    true
  end

let read_payload_string payload ~len ~on_complete =
  let buffer = Bytes.create len in
  let offset = ref 0 in
  let completed = ref false in
  let complete () =
    if not !completed then begin
      completed := true;
      let text =
        if !offset = len then Bytes.unsafe_to_string buffer
        else Bytes.sub_string buffer 0 !offset
      in
      on_complete text
    end
  in
  let rec schedule () =
    if !completed then ()
    else if !offset >= len then complete ()
    else
      Httpun_ws.Payload.schedule_read payload
        ~on_eof:complete
        ~on_read:(fun bs ~off ~len:chunk_len ->
          let remaining = len - !offset in
          let copy_len = min chunk_len remaining in
          Bigstringaf.blit_to_bytes bs ~src_off:off buffer
            ~dst_off:!offset ~len:copy_len;
          offset := !offset + copy_len;
          if !offset >= len then complete () else schedule ())
  in
  if len = 0 then complete () else schedule ()

type inbound_size_rejection = {
  reason: string;
  limit: int;
  actual: int;
}

type inbound_size_decision =
  | Inbound_accept
  | Inbound_reject of inbound_size_rejection

let max_inbound_frame_bytes () =
  Env_config_core.get_int_nonneg ~default:1048576
    "MASC_WS_MAX_INBOUND_FRAME_BYTES"

let max_inbound_message_bytes () =
  Env_config_core.get_int_nonneg ~default:2097152
    "MASC_WS_MAX_INBOUND_MESSAGE_BYTES"

let classify_inbound_frame_size ~len ~max_frame_bytes =
  if len < 0 then
    Inbound_reject
      { reason = "invalid_frame_length"; limit = max_frame_bytes; actual = len }
  else if max_frame_bytes > 0 && len > max_frame_bytes then
    Inbound_reject
      { reason = "frame_too_large"; limit = max_frame_bytes; actual = len }
  else
    Inbound_accept

let add_bounded_or_max a b =
  if a < 0 || b < 0 || b > max_int - a then max_int else a + b

let classify_inbound_message_size ~current_bytes ~chunk_len ~max_message_bytes =
  let actual = add_bounded_or_max current_bytes chunk_len in
  if max_message_bytes > 0 && actual > max_message_bytes then
    Inbound_reject
      { reason = "message_too_large"; limit = max_message_bytes; actual }
  else
    Inbound_accept

let close_session_for_inbound_reject session rejection =
  Log.Transport.warn
    "WS inbound message rejected for session=%s reason=%s actual=%d limit=%d"
    session.id
    rejection.reason
    rejection.actual
    rejection.limit;
  with_sessions_rw (fun () ->
      if Hashtbl.mem sessions session.id then begin
        Atomic.set session.closed true;
        (try
           Eio_guard.with_mutex session.write_mutex (fun () ->
             if not (Httpun_ws.Wsd.is_closed session.wsd) then
               Httpun_ws.Wsd.close ~code:`Message_too_big session.wsd)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Log.Server.warn "WS reject close failed for %s: %s" session.id
               (Printexc.to_string exn));
        Hashtbl.remove sessions session.id;
        slice_index_remove_session_locked session.id
      end);
  Transport_metrics.set_ws_sessions
    (with_sessions_rw (fun () -> Hashtbl.length sessions));
  Sse.unsubscribe_external session.id

let handle_inbound_text session ~on_message ~is_fin text =
  let chunk_len = String.length text in
  let current_bytes =
    match session.inbound_partial_text with
    | None -> 0
    | Some _ -> session.inbound_partial_text_bytes
  in
  match
    classify_inbound_message_size ~current_bytes ~chunk_len
      ~max_message_bytes:(max_inbound_message_bytes ())
  with
  | Inbound_reject rejection ->
      session.inbound_partial_text <- None;
      session.inbound_partial_text_bytes <- 0;
      close_session_for_inbound_reject session rejection
  | Inbound_accept ->
      let message_bytes = add_bounded_or_max current_bytes chunk_len in
      match session.inbound_partial_text, is_fin with
      | None, true ->
          if chunk_len > 0 then
            on_message session.id text
      | None, false ->
          let initial_size =
            if chunk_len > max_int / 2 then chunk_len else chunk_len * 2
          in
          let buffer = Buffer.create (max 16 initial_size) in
          Buffer.add_string buffer text;
          session.inbound_partial_text <- Some buffer;
          session.inbound_partial_text_bytes <- message_bytes
      | Some buffer, _ ->
          Buffer.add_string buffer text;
          if is_fin then begin
            session.inbound_partial_text <- None;
            session.inbound_partial_text_bytes <- 0;
            let message = Buffer.contents buffer in
            if String.length message > 0 then
              on_message session.id message
          end
          else
            session.inbound_partial_text_bytes <- message_bytes

let read_inbound_message_frame session ~on_message ~is_fin ~len payload =
  Transport_metrics.observe_ws_message_bytes_recv len;
  match classify_inbound_frame_size ~len ~max_frame_bytes:(max_inbound_frame_bytes ()) with
  | Inbound_reject rejection ->
      Httpun_ws.Payload.close payload;
      session.inbound_partial_text <- None;
      session.inbound_partial_text_bytes <- 0;
      close_session_for_inbound_reject session rejection
  | Inbound_accept ->
      read_payload_string payload ~len ~on_complete:(fun text ->
          handle_inbound_text session ~on_message ~is_fin text)

(** Remove a session and unsubscribe from SSE. *)
let cleanup_session session_id =
  let removed =
    with_sessions_rw (fun () ->
        match Hashtbl.find_opt sessions session_id with
        | None -> false
        | Some session ->
            Atomic.set session.closed true;
            (try
               Eio_guard.with_mutex session.write_mutex (fun () ->
                 Httpun_ws.Wsd.close session.wsd)
             with Eio.Cancel.Cancelled _ as e -> raise e
                | exn -> Log.Server.warn "WS close failed for %s: %s" session_id (Printexc.to_string exn));
            Hashtbl.remove sessions session_id;
            slice_index_remove_session_locked session_id;
            true)
  in
  Transport_metrics.set_ws_sessions
    (with_sessions_rw (fun () -> Hashtbl.length sessions));
  Sse.unsubscribe_external session_id;
  if removed then
    (* #10875: see server_ws_standalone — per-session lifecycle is DEBUG
       to avoid logging amplification during WS storm (#10701). *)
    Log.Server.debug "WebSocket session %s closed" session_id

(** Number of active WebSocket sessions. *)
let session_count () =
  with_sessions_rw (fun () ->
    Hashtbl.length sessions)

let heartbeat_interval_s = 30.0

(** Whether the heartbeat should close a session for pong-timeout.  Liveness is
    keyed on the last answered pong, not a per-tick counter: a client that keeps
    answering refreshes [last_pong_at] via {!record_pong} and is therefore never
    closed, fixing the conflation where a responsive client sat one tick from
    closure every interval (#21509).  Closes only after [threshold] whole
    [interval_s] periods with no pong.  [threshold = 0] (or negative) disables
    the guard. *)
let heartbeat_should_close ~now ~last_pong_at ~threshold ~interval_s =
  threshold > 0 && now -. last_pong_at > float_of_int threshold *. interval_s
;;

(** Configurable missed-pong threshold for the /ws upgrade heartbeat.

    A value of [0] disables the pong-timeout guard.  Negative values are
    clamped to [0] so they cannot force immediate closure.  The threshold is
    read once per session at creation time; changes to the environment variable
    affect only new sessions. *)
let missed_pong_threshold () =
  max 0 (Env_config_core.get_int ~default:3 "MASC_WS_MISSED_PONG_THRESHOLD")

let __test_missed_pong_threshold = missed_pong_threshold

let start_upgrade_heartbeat ?sw ?clock session_id session =
  match sw, clock with
  | Some server_sw, Some clock ->
    let threshold = missed_pong_threshold () in
    Eio.Fiber.fork ~sw:server_sw (fun () ->
      (* Per-connection switch: the heartbeat fiber must not be anchored to the
         server-wide switch.  When the connection closes the loop exits and this
         switch cleans up with it. *)
      Eio.Switch.run (fun _conn_sw ->
        let rec loop () =
          Eio.Time.sleep clock heartbeat_interval_s;
          if is_session_closed session
          then ()
          else if
            (* NDT-OK: wall-clock compared for liveness only, not output *)
            heartbeat_should_close
              ~now:(Unix.gettimeofday ())
              ~last_pong_at:(Atomic.get session.last_pong_at)
              ~threshold
              ~interval_s:heartbeat_interval_s
          then begin
            Log.Server.debug
              "[ws-upgrade] session %s pong timeout (no pong in %d intervals); closing"
              session_id
              threshold;
            cleanup_session session_id
          end
          else begin
            let send_failed = ref false in
            (try
               Eio_guard.with_mutex session.write_mutex (fun () ->
                 if not (is_session_closed session) then
                   Httpun_ws.Wsd.send_ping session.wsd)
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               send_failed := true;
               (match Http_server_eio.Late_response.classify_write_failure exn with
                | Some _ ->
                  Log.Server.debug
                    "[ws-upgrade] session %s heartbeat skipped (writer closed during \
                     cancel race)"
                    session_id
                | None ->
                  Log.Server.warn
                    "[ws-upgrade] session %s heartbeat send_ping failed: %s"
                    session_id
                    (Printexc.to_string exn)));
            if !send_failed
            then cleanup_session session_id
            else loop ()
          end
        in
        loop ()))
  | _ ->
    Log.Server.debug
      "[ws-upgrade] session %s heartbeat disabled (missing switch or clock)"
      session_id

let send_upgrade_pong session =
  try
    Eio_guard.with_mutex session.write_mutex (fun () ->
      if not (is_session_closed session) then
        Httpun_ws.Wsd.send_pong session.wsd)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    (match Http_server_eio.Late_response.classify_write_failure exn with
     | Some _ ->
       Log.Server.debug
         "[ws-upgrade] session %s send_pong skipped (writer closed during cancel race)"
         session.id
     | None ->
       Log.Server.warn
         "[ws-upgrade] session %s send_pong failed: %s"
         session.id
         (Printexc.to_string exn))

(** Handle an HTTP upgrade request to WebSocket.

    Call this from the httpun request handler when path = "/ws".
    Returns [Ok ()] on successful upgrade, [Error msg] on failure.

    @param reqd The httpun request descriptor.
    @param on_message Optional callback for incoming text messages.
      Default: log and ignore. *)
let upgrade_connection
    ?sw
    ?clock
    ?(on_message = fun _session_id _text -> ())
    (reqd : Httpun.Reqd.t)
  : (unit, string) result =
  let session_id = next_id () in
  Httpun_ws.Handshake.respond_with_upgrade ~sha1 reqd (fun () ->
    (* This callback runs after the HTTP 101 response is sent.
       We now have a live WebSocket connection via [Wsd.t]. *)
    let ws_conn =
      Httpun_ws.Server_connection.create_websocket
        (fun wsd ->
          let session = new_session ~id:session_id ~wsd in
          with_sessions_rw (fun () ->
            Hashtbl.replace sessions session_id session);
          Transport_metrics.set_ws_sessions
            (with_sessions_rw (fun () -> Hashtbl.length sessions));
          (* Register as SSE external subscriber for broadcast events *)
          Sse.subscribe_external ~id:session_id
            ~is_alive:(fun () -> not (is_session_closed session))
            ~callback:(fun sse_event ->
              if not (is_session_closed session)
                 && not (send_dashboard_or_raw_sse session sse_event)
              then
                cleanup_session session_id)
            ();
          start_upgrade_heartbeat ?sw ?clock session_id session;
          (* #10875: see cleanup_session — per-session lifecycle is DEBUG
             to avoid logging amplification during WS storm (#10701). *)
          Log.Server.debug "WebSocket session %s connected (same-origin /ws)" session_id;
          { Httpun_ws.Websocket_connection.
            frame = (fun ~opcode ~is_fin ~len payload ->
              match opcode with
              | `Text | `Binary | `Continuation ->
                read_inbound_message_frame session ~on_message ~is_fin ~len
                  payload
              | `Ping ->
                send_upgrade_pong session;
                Httpun_ws.Payload.close payload
              | `Pong ->
                record_pong session;
                Httpun_ws.Payload.close payload
              | `Connection_close ->
                cleanup_session session_id;
                Httpun_ws.Payload.close payload
              | `Other _ ->
                Httpun_ws.Payload.close payload
            );
            eof = (fun ?error:_ () ->
              cleanup_session session_id)
          })
    in
    (* The ws_conn needs to be driven by the I/O loop.
       httpun-ws handles this internally when using respond_with_upgrade. *)
    ignore ws_conn)

(** Outcome of {!send_to_session_result}.  [Sent] is the happy path;
    [Session_gone] is the expected case where the session has already
    been cleaned up by the transport (client disconnect, no real bug);
    [Send_failed] is a real transport-side failure (broken pipe,
    encoding error, write saturation) and is the only signal that
    warrants operator attention.  #10648. *)
type send_outcome =
  | Sent
  | Session_gone
  | Send_failed

(** Structured variant of {!send_to_session}.  Callers that need to
    distinguish the two failure modes should use this; the boolean
    {!send_to_session} stays for callers that only want a happy/sad
    indicator. *)
let send_to_session_result session_id text =
  let session_opt =
    with_sessions_rw (fun () -> Hashtbl.find_opt sessions session_id)
  in
  match session_opt with
  | None -> Session_gone
  | Some session ->
      let sent = send_text_checked ~context:"send-to-session" session text in
      if sent then Sent
      else begin
        cleanup_session session_id;
        Send_failed
      end

(** Send a text frame to a specific session by ID.
    Returns [false] if the session is not found or the send fails.
    Prefer {!send_to_session_result} when the caller needs to
    distinguish "session gone" (expected) from "send failed" (bug). *)
let send_to_session session_id text =
  match send_to_session_result session_id text with
  | Sent -> true
  | Session_gone | Send_failed -> false

(** Broadcast a JSON string to all WebSocket sessions.
    Independent of SSE -- for WS-only messages. *)
let broadcast_ws json_str =
  let snapshot =
    with_sessions_rw (fun () ->
      Hashtbl.fold (fun _ s acc -> s :: acc) sessions [])
  in
  let failed = ref [] in
  List.iter (fun session ->
    if not (send_text_checked ~context:"broadcast" session json_str) then
      failed := session.id :: !failed
  ) snapshot;
  List.iter cleanup_session !failed

(** Close all WebSocket sessions (for graceful shutdown). *)
let close_all () =
  let ids =
    with_sessions_rw (fun () ->
      Hashtbl.fold (fun k _ acc -> k :: acc) sessions [])
  in
  List.iter cleanup_session ids;
  Transport_metrics.set_ws_sessions 0;
  List.length ids
;;

let () = Shutdown_hooks.register_ws_cleanup (fun () -> close_all (), session_count ())

let () =
  Mcp_server_eio_protocol.register_dashboard_ws_handlers
    ~hello:(fun ~base_path ~session_id ?token () -> dashboard_hello ~base_path ~session_id ?token ())
    ~subscribe:(fun ~session_id ?route ~slices () -> dashboard_subscribe ~session_id ?route ~slices ())
    ~unsubscribe:(fun ~session_id ?slices () -> dashboard_unsubscribe ~session_id ?slices ())
    ~ping:(fun ~session_id () -> dashboard_ping ~session_id ());
  Mcp_server_eio_protocol.register_dashboard_ack dashboard_ack
;;
