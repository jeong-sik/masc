(** WebSocket Transport for MASC MCP.

    Provides bidirectional JSON-RPC messaging over WebSocket,
    replacing SSE for dashboard/agent connections that need
    full-duplex communication.

    Upgrade path: GET /ws with Connection: Upgrade header.
    Uses ws-direct for the WebSocket protocol on top of httpun (RFC-0287):
    the HTTP 101 handshake is written on the httpun reqd, then the post-101
    connection is driven by a ws-direct Endpoint via the gluten adapter.

    Outbound events: registered as an Sse external subscriber,
    so all broadcast events are forwarded to WebSocket clients.

    Inbound messages: JSON-RPC requests are dispatched to the
    same tool dispatcher used by the MCP HTTP transport. *)

module Ws_endpoint = Ws_direct_core.Endpoint
module Ws_wsd = Ws_direct_core.Endpoint.Wsd
module Ws_msg = Ws_direct_core.Connection.Message

(** SHA1 (raw 20-byte digest) for the RFC 6455 §1.3 handshake accept proof. *)
let sha1 s =
  Digestif.SHA1.(digest_string s |> to_raw_string)

(* RFC 6455 §1.3 handshake GUID + the Sec-WebSocket-Accept proof. *)
let websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
let sec_websocket_accept key = Base64.encode_string (sha1 (key ^ websocket_guid))

let inbound_message_handler : (string -> string -> unit) Atomic.t =
  Atomic.make (fun session_id _body ->
      Log.Server.warn
        "WS inbound message received before dispatcher registered: session=%s"
        session_id)

let set_inbound_message_handler handler =
  Atomic.set inbound_message_handler handler

let dispatch_inbound_message session_id body =
  Atomic.get inbound_message_handler session_id body

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

(* RFC-0287: inbound frame reassembly + UTF-8 validation now live in the
   ws-direct Connection layer, which delivers complete messages via the
   Endpoint [on_message] handler. The former [Ws_inbound] reassembler and the
   manual [read_data_frame] / [read_payload_string] machinery are gone; only the
   size-cap knobs survive, fed to [Endpoint.create] as [max_message] /
   [max_frame]. *)

(** Active WebSocket session state. *)
type ws_session = {
  id: string;
  wsd: Ws_wsd.t;
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
  dashboard_route: string option Atomic.t;
  (** Slices this session subscribes to, held as an immutable list inside an
      [Atomic.t].  Subscribe / unsubscribe (under [sessions_mutex]) publish a
      fresh list with [Atomic.set]; the SSE fanout reads it lock-free with
      [Atomic.get].  An immutable snapshot is never mutated in place, so a
      reader on the serving domain cannot observe a torn list or trip a
      [Hashtbl] resize on the keeper-loop broadcast path (RFC-0204 Phase 3). *)
  dashboard_slices: string list Atomic.t;
  dashboard_seq: int Atomic.t;
  (** Last seq value the client has acknowledged.  0 until the first ack
      arrives.  Paired with {!dashboard_last_buffered_amount} so the server
      can reason about client liveness without touching the wire. *)
  dashboard_last_ack_seq: int Atomic.t;
  (** Last [WebSocket.bufferedAmount] the client reported in a
      [dashboard/ack] notification.  A growing value is a leading indicator
      that the client cannot drain deltas as fast as the server pushes them;
      sustained growth should eventually gate further sends.  Observability
      lands first — gating is a follow-up once thresholds are established
      from production distributions. *)
  dashboard_last_buffered_amount: int Atomic.t;
  (** Last wall-clock time a [dashboard/ack] notification arrived.  A
      subscribed dashboard that stops ACKing can keep a low bufferedAmount
      forever. *)
  dashboard_last_ack_at: float Atomic.t;
  (** Last dashboard/delta seq that expects a browser [dashboard/ack].  Snapshot
      seqs are intentionally excluded because the browser only ACKs deltas. *)
  (** [dashboard_last_delta_seq] / [dashboard_last_delta_at] are written
      together on the fanout (one delta) and read together by
      {!session_is_backpressured}.  As independent [Atomic.t]s a cross-domain
      reader may observe a one-tick-stale pair; that is benign for the stale-ACK
      backpressure heuristic, which is monotonic and re-evaluates on the next
      delta (RFC-0204 Phase 3 — deliberate, not an oversight). *)
  dashboard_last_delta_seq: int Atomic.t;
  dashboard_last_delta_at: float Atomic.t;
  inbound_dispatches: int Atomic.t;
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

(** Detach a session from the global registry before doing any wire-level
    shutdown.  Closing [Ws_wsd.t] takes the per-session [write_mutex]
    and may run transport code; doing that while [sessions_mutex] is held can
    stall every session lookup, fanout snapshot, and cleanup path behind one
    slow or wedged socket. *)
let detach_session_for_close session_id =
  with_sessions_rw (fun () ->
      match Hashtbl.find_opt sessions session_id with
      | None -> None
      | Some session ->
          Atomic.set session.closed true;
          Hashtbl.remove sessions session_id;
          slice_index_remove_session_locked session_id;
          Some session)

let close_detached_session_wsd ?(code : int option) ~context session =
  try
    Eio_guard.with_mutex session.write_mutex (fun () ->
        if not (Ws_wsd.is_closed session.wsd) then Ws_wsd.send_close ?code session.wsd ())
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Server.warn "WS %s failed for %s: %s" context session.id
        (Printexc.to_string exn)

let update_ws_session_count_metric () =
  Transport_metrics.set_ws_sessions
    (with_sessions_rw (fun () -> Hashtbl.length sessions))

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
    dashboard_route = Atomic.make None;
    dashboard_slices = Atomic.make [];
    dashboard_seq = Atomic.make 0;
    dashboard_last_ack_seq = Atomic.make 0;
    dashboard_last_buffered_amount = Atomic.make 0;
    dashboard_last_ack_at = Atomic.make now;
    dashboard_last_delta_seq = Atomic.make 0;
    dashboard_last_delta_at = Atomic.make now;
    inbound_dispatches = Atomic.make 0;
  }

(** [true] when the session has been closed locally or the httpun-ws writer has
    shut down.  Reads the atomic [closed] flag and the WSD state; safe from any
    fiber. *)
let is_session_closed session =
  Atomic.get session.closed || Ws_wsd.is_closed session.wsd

(** Record a client pong: refresh [last_pong_at].  Called from the WS frame
    handler on every [Pong] frame; this is the liveness signal the heartbeat
    reads via {!heartbeat_should_close} (#21509). *)
let record_pong session =
  Atomic.set session.last_pong_at (Unix.gettimeofday ())
(* NDT-OK: wall-clock used only for liveness, not deterministic output. *)

(** Send a pre-encoded text payload to a WebSocket client.

    The caller owns the [payload] bigstring and must treat it as immutable after
    passing it here.  ws-direct owns RFC 6455 framing and role-specific masking;
    server-mode fanout can therefore reuse one immutable payload across
    sessions without allocating a per-session payload string. *)
let send_text_bigstring session payload =
  let len = Bigstringaf.length payload in
  if is_session_closed session then begin
    Atomic.set session.closed true;
    false
  end else begin
    Eio_guard.with_mutex session.write_mutex (fun () ->
      if is_session_closed session then false
      else begin
        try
          Ws_wsd.send_text_bigstring session.wsd payload;
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
    Allocates a [Bigstringaf.t] per call — fine for single-destination sends.
    Multicast paths should go through [send_text_shared] instead so the
    payload allocation is paid once per broadcast, not once per session. *)
let send_text session text =
  let payload_text = websocket_text_payload text in
  let payload =
    Bigstringaf.of_string payload_text ~off:0 ~len:(String.length payload_text)
  in
  send_text_bigstring session payload

(** Module-local cache of the last [Bigstringaf.of_string sse_event] result.

    [Sse.notify_external_subscribers] delivers the same [event: string]
    reference to every subscribed WS session in sequence.  Before this
    cache, every session encoded the same payload independently in the
    raw-SSE-forward path, producing O(sessions) identical allocations and
    copies at the WebSocket API boundary.
    Keyed by physical equality so a fresh broadcast invalidates it. *)
let bigstring_cache : (string * Bigstringaf.t) Atomic.t =
  Atomic.make ("", Bigstringaf.empty)

let bigstring_of_shared_text text =
  let cached_str, cached_payload = Atomic.get bigstring_cache in
  if cached_str == text then begin
    Transport_metrics.inc_ws_bytes_cache_hit ();
    cached_payload
  end
  else begin
    Transport_metrics.inc_ws_bytes_cache_miss ();
    let payload_text = websocket_text_payload text in
    let payload =
      Bigstringaf.of_string payload_text ~off:0
        ~len:(String.length payload_text)
    in
    Atomic.set bigstring_cache (text, payload);
    payload
  end

(** Send a text frame that will also be sent to other sessions in this
    broadcast.  Encodes [text] to [Bigstringaf.t] once per unique string
    reference; subsequent sessions in the same fanout reuse that payload. *)
let send_text_shared session text =
  let payload = bigstring_of_shared_text text in
  send_text_bigstring session payload

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

type dashboard_delta_payload_frame = {
  slice: string;
  text: string;
}

(* Cross-domain-safe seq allocator: [fetch_and_add] atomically claims a unique
   slot, so two domains never hand out the same seq.  The old plain
   read-modify-write lost ~half its updates under true parallelism (RFC-0204
   Phase 3 gate). *)
let next_dashboard_seq session = Atomic.fetch_and_add session.dashboard_seq 1 + 1

(* Monotonic-max update for a cross-domain counter: retries until our value
   lands or a concurrent writer has already raised the field to >= v.  Replaces
   the old non-atomic "if v > x then x <- v", which lost concurrent acks. *)
let rec atomic_bump_max a v =
  let cur = Atomic.get a in
  if v > cur && not (Atomic.compare_and_set a cur v) then atomic_bump_max a v

let valid_dashboard_slice = function
  | "shell"
  | "execution"
  | "operator"
  | "transport"
  | "namespace"
  | "composite"
  | "board" ->
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
    Atomic.get session.dashboard_slices
    |> List.sort compare
    |> List.map (fun slice -> `String slice)
  in
  let auth = dashboard_auth session in
  `Assoc
    [
      ("protocol", `String "dashboard-ws.v1");
      ("session_id", `String session.id);
      ("authenticated", `Bool (dashboard_auth_is_authenticated auth));
      ( "agent", Json_util.string_opt_to_json (dashboard_auth_agent auth) );
      ( "route", Json_util.string_opt_to_json (Atomic.get session.dashboard_route) );
      ("slices", `List slices);
      ("seq", `Int (Atomic.get session.dashboard_seq));
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
    Atomic.get session.dashboard_slices
    |> List.filter_map (fun slice ->
           match !dashboard_snapshot_provider slice with
           | Some json -> Some (slice, json)
           | None -> None)
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  `Assoc
    [
      ("protocol", `String "dashboard-ws.v1");
      ("seq", `Int (next_dashboard_seq session));
      ( "route", Json_util.string_opt_to_json (Atomic.get session.dashboard_route) );
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
                Atomic.set session.dashboard_slices
                  (List.sort_uniq compare slices);
                List.iter
                  (fun slice -> slice_index_add_locked ~session_id ~slice)
                  slices);
            Atomic.set session.dashboard_route route;
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
                Atomic.set session.dashboard_slices [];
                slice_index_remove_session_locked session_id
            | Some slices ->
                Atomic.set session.dashboard_slices
                  (List.filter
                     (fun s -> not (List.mem s slices))
                     (Atomic.get session.dashboard_slices));
                List.iter
                  (fun slice -> slice_index_remove_locked ~session_id ~slice)
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
              ("seq", `Int (Atomic.get session.dashboard_seq));
            ])

let dashboard_ack ~session_id ~seq ?buffered_amount () =
  match find_session session_id with
  | None -> Error "WebSocket session not found"
  | Some session ->
      if not (dashboard_auth_is_authenticated (dashboard_auth session)) then
        Error "dashboard/ack requires dashboard/hello first"
      else begin
        Atomic.set session.dashboard_last_ack_at (Time_compat.now ());
        atomic_bump_max session.dashboard_last_ack_seq seq;
        (match buffered_amount with
         | Some n when n >= 0 ->
             Atomic.set session.dashboard_last_buffered_amount n;
             Transport_metrics.observe_ws_client_buffered_bytes n
         | _ -> ());
        Ok
          (`Assoc
            [
              ("session_id", `String session.id);
              ("ack", `Int seq);
              ("server_last_ack_seq",
                `Int (Atomic.get session.dashboard_last_ack_seq));
              ("server_last_buffered_amount",
                `Int (Atomic.get session.dashboard_last_buffered_amount));
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
    parse failed and send_dashboard_delta_for_sse always fell through to
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

(** Shared dashboard/delta payload-frame cache.

    The per-session [seq] is intentionally excluded from [text].  That keeps
    the expensive payload serialization keyed by the physical SSE broadcast
    reference instead of by recipient, so a fan-out pays one
    [Yojson.Safe.to_string] for the payload frame. *)
let dashboard_delta_payload_text_cache :
    (string * dashboard_delta_payload_frame option) Atomic.t =
  Atomic.make ("", None)

let dashboard_delta_payload_text_for_parsed sse_event parsed =
  let cached_event, cached_payload =
    Atomic.get dashboard_delta_payload_text_cache
  in
  if cached_event == sse_event then cached_payload
  else begin
    let payload_frame =
      match parsed with
      | Some { event_type; slice = Some slice; payload; broadcast_ts } ->
          Transport_metrics.inc_ws_delta_payload_serialization ();
          Some
            {
              slice;
              text =
                Yojson.Safe.to_string
                  (jsonrpc_notification "dashboard/delta"
                     (`Assoc
                       [
                         ("protocol", `String "dashboard-ws.v1");
                         ("slice", `String slice);
                         ("event_type", `String event_type);
                         ("mode", `String "snapshot");
                         ("payload", payload);
                         ("ts_unix", `Float broadcast_ts);
                       ]));
            }
      | _ -> None
    in
    Atomic.set dashboard_delta_payload_text_cache (sse_event, payload_frame);
    payload_frame
  end

let dashboard_delta_seq_notification seq =
  jsonrpc_notification "dashboard/delta"
    (`Assoc [ ("protocol", `String "dashboard-ws.v1"); ("seq", `Int seq) ])

let send_dashboard_delta_frame session { slice; text } =
  if not (List.mem slice (Atomic.get session.dashboard_slices)) then false
  else begin
    Transport_metrics.inc_ws_delta_built ();
    let seq = next_dashboard_seq session in
    if send_text_shared_checked ~context:"dashboard-delta-payload" session text
    then begin
      Atomic.set session.dashboard_last_delta_seq seq;
      Atomic.set session.dashboard_last_delta_at (Time_compat.now ());
      send_json_checked ~context:"dashboard-delta-seq" session
        (dashboard_delta_seq_notification seq)
    end
    else false
  end

let send_dashboard_delta_for_parsed session sse_event parsed =
  match dashboard_delta_payload_text_for_parsed sse_event parsed with
  | Some frame -> send_dashboard_delta_frame session frame
  | None -> false

let send_dashboard_delta_for_sse session sse_event =
  send_dashboard_delta_for_parsed session sse_event
    (parse_sse_dashboard_event sse_event)

(** TTL cache for env-var reads on the fan-out hot path.

    [client_buffer_limit_bytes], [dashboard_ack_stale_threshold_s],
    and [slice_index_enabled] are invoked once per session per broadcast,
    so a 100-session fanout at 1000 broadcasts/sec produced hundreds of
    thousands of [Sys.getenv_opt] calls per second.  The earlier docstring
    claimed the read was
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

let dashboard_ack_stale_threshold_cache : (float * float) Atomic.t =
  Atomic.make (Float.neg_infinity, 30.0)

let dashboard_ack_stale_threshold_s () =
  let now = Time_compat.now () in
  let last_at, cached = Atomic.get dashboard_ack_stale_threshold_cache in
  if now -. last_at < env_cache_ttl_s then cached
  else begin
    let value =
      Env_config_core.get_float_nonneg ~default:30.0
        "MASC_WS_ACK_STALE_THRESHOLD_SEC"
    in
    Atomic.set dashboard_ack_stale_threshold_cache (now, value);
    value
  end

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
      limit > 0 && Atomic.get session.dashboard_last_buffered_amount >= limit
    in
    let ack_stale =
      dashboard_ack_is_stale
        ~now:(Time_compat.now ())
        ~last_delta_at:(Atomic.get session.dashboard_last_delta_at)
        ~last_delta_seq:(Atomic.get session.dashboard_last_delta_seq)
        ~last_ack_seq:(Atomic.get session.dashboard_last_ack_seq)
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
  Atomic.set dashboard_ack_stale_threshold_cache
    (Float.neg_infinity, 30.0);
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
    match parsed with
    | Some { slice = Some slice; _ }
      when List.mem slice (Atomic.get session.dashboard_slices) ->
        send_dashboard_delta_for_parsed session sse_event parsed
    | _ ->
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
           [send_dashboard_delta_for_parsed] would have sent the split delta
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
             collapses N identical payload encodings into 1. *)
          send_text_shared_checked ~context:"sse-forward" session sse_event
  end
  else begin
    (* Unauthenticated session: drop SSE events until dashboard/hello
       completes.  Forwarding before hello floods the client with SSE
       frames that can bury the JSON-RPC hello response, causing the
       browser RPC timeout to fire and triggering a reconnect loop. *)
    true
  end

let max_inbound_frame_bytes () =
  Env_config_core.get_int_nonneg ~default:1048576
    "MASC_WS_MAX_INBOUND_FRAME_BYTES"

let max_inbound_message_bytes () =
  Env_config_core.get_int_nonneg ~default:2097152
    "MASC_WS_MAX_INBOUND_MESSAGE_BYTES"

let max_inbound_dispatches_per_session () =
  Env_config_core.get_int_nonneg ~default:32
    "MASC_WS_MAX_INBOUND_DISPATCHES_PER_SESSION"

type inbound_dispatch_rejection = {
  reason: string;
  limit: int;
  in_flight: int;
}

type inbound_dispatch_admission =
  | Inbound_dispatch_admitted of ws_session
  | Inbound_dispatch_rejected of inbound_dispatch_rejection
  | Inbound_dispatch_session_gone

let try_begin_inbound_dispatch session_id =
  let session_opt =
    with_sessions_rw (fun () -> Hashtbl.find_opt sessions session_id)
  in
  match session_opt with
  | None -> Inbound_dispatch_session_gone
  | Some session ->
      if Atomic.get session.closed then Inbound_dispatch_session_gone
      else
        let limit = max_inbound_dispatches_per_session () in
        let rec loop () =
          let in_flight = Atomic.get session.inbound_dispatches in
          if limit > 0 && in_flight >= limit then
            Inbound_dispatch_rejected
              { reason = "too_many_inbound_dispatches";
                limit;
                in_flight }
          else if
            Atomic.compare_and_set session.inbound_dispatches in_flight
              (in_flight + 1)
          then Inbound_dispatch_admitted session
          else loop ()
        in
        loop ()

let finish_inbound_dispatch session =
  let rec loop () =
    let in_flight = Atomic.get session.inbound_dispatches in
    let next = if in_flight <= 0 then 0 else in_flight - 1 in
    if not (Atomic.compare_and_set session.inbound_dispatches in_flight next)
    then loop ()
  in
  loop ()

(** Remove a session and unsubscribe from SSE. *)
let cleanup_session session_id =
  let detached = detach_session_for_close session_id in
  update_ws_session_count_metric ();
  Sse.unsubscribe_external session_id;
  match detached with
  | None -> ()
  | Some session ->
    close_detached_session_wsd ~context:"close" session;
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

(* Exposed for the cross-domain delivery-state gate (RFC-0204 Phase 3): the gate
   drives two domains through the seq allocator and asserts the final counter
   equals the total number of calls (no lost updates). *)
let __test_next_dashboard_seq = next_dashboard_seq
let __test_dashboard_seq_value session = Atomic.get session.dashboard_seq

let __test_dashboard_delta_payload_text_for_sse sse_event =
  dashboard_delta_payload_text_for_parsed sse_event
    (parse_sse_dashboard_event sse_event)

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
                   Ws_wsd.send_ping session.wsd ())
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

(* RFC-0287: ping->pong is automatic in the ws-direct Endpoint, so the former
   [send_upgrade_pong] is gone; [record_pong] still fires from the [on_pong]
   handler to refresh the liveness timestamp. *)

(** Build the MCP-over-WebSocket session handler for a freshly upgraded
    [wsd].  Single source of truth for the MCP WebSocket session
    protocol — session registration, SSE broadcast subscription,
    liveness heartbeat, and frame opcode handling — shared by the
    same-origin HTTP-upgrade path
    ([Server_routes_http_routes_frontend]) and the standalone listener
    ([Server_ws_standalone]).  The two paths differ only in how the
    socket is attached (Gluten upgrade vs. raw listener), not in the
    session protocol.  RFC-0281 S3.2.

    [on_connection_close] and [on_eof] are observability hooks invoked
    before {!cleanup_session}.  The defaults close the close-frame
    payload and ignore the eof error; the standalone path injects its
    close-code diagnostic + eof summary.  Cleanup runs regardless of
    the hook. *)
let mcp_websocket_handler
    ?sw
    ?clock
    ?(on_close_log = fun ~session_id:_ ~code:_ ~reason:_ -> ())
    ?(on_eof = fun ~session_id:_ -> ())
    ~on_message
    ~origin_label
    (wsd : Ws_wsd.t)
  : Ws_endpoint.handlers =
  let session_id = next_id () in
  let session = new_session ~id:session_id ~wsd in
  with_sessions_rw (fun () -> Hashtbl.replace sessions session_id session);
  Transport_metrics.set_ws_sessions
    (with_sessions_rw (fun () -> Hashtbl.length sessions));
  (* Register as SSE external subscriber for broadcast events. *)
  Sse.subscribe_external ~id:session_id
    ~is_alive:(fun () -> not (is_session_closed session))
    ~callback:(fun sse_event ->
      if not (is_session_closed session)
         && not (send_dashboard_or_raw_sse session sse_event)
      then cleanup_session session_id)
    ();
  start_upgrade_heartbeat ?sw ?clock session_id session;
  (* #10875: see cleanup_session — per-session lifecycle is DEBUG to
     avoid logging amplification during WS storm (#10701). *)
  Log.Server.debug "WebSocket session %s connected (%s)" session_id origin_label;
  (* RFC-0287: ws-direct reassembles fragments + validates UTF-8 + enforces the
     size caps internally, so [on_message] receives a complete message and a
     protocol/size violation surfaces as [on_close]/[on_error] with the right
     close code — no frame-opcode switch or manual reassembly here. Ping is
     auto-ponged by the Endpoint; [on_pong] only refreshes liveness. *)
  Ws_endpoint.handlers
    ~on_message:(fun (m : Ws_msg.t) ->
      on_message session_id (Bigstringaf.to_string m.Ws_msg.payload))
    ~on_pong:(fun _ -> record_pong session)
    ~on_close:(fun ~code ~reason ->
      on_close_log ~session_id ~code ~reason;
      cleanup_session session_id)
    ~on_error:(fun _reason -> cleanup_session session_id)
    ~on_eof:(fun () ->
      on_eof ~session_id;
      cleanup_session session_id)
    ()

(** Perform the HTTP/1.1 -> WebSocket upgrade and drive the resulting
    connection.  Single source of truth for attaching an upgraded
    socket to a ws-direct [Ws_endpoint] (Server role) packaged as a
    [Gluten.impl] — drop-in for the former [Httpun_ws.Server_connection.t]
    (RFC-0287 §4.1): it sends the 101 via
    [respond_with_upgrade], then hands the connection to the Gluten
    runtime via [upgrade].  Omitting the [upgrade] call (the
    pre-RFC-0281 defect) left the connection undriven, so inbound frames
    — including the client hello and protocol pongs — were never read.
    RFC-0281 S3.1.

    [handler] builds the per-connection [input_handlers] from the
    [Wsd.t]; the MCP session ({!mcp_websocket_handler}) and the IDE LSP
    session each supply their own. *)
(* RFC 6455 §4.2.1 scrutiny after the shared request-entry authority gate: the
   request must be a GET with [Upgrade: websocket], a [Connection] list
   containing "upgrade", a 16-byte base64 [Sec-WebSocket-Key], and
   [Sec-WebSocket-Version: 13].  Host cardinality and syntax are already
   represented by [Server_request_authority.authority] in the request fiber;
   this downstream handshake must not re-read the raw Host field. *)
let ws_upgrade_accept (request : Httpun.Request.t) : (string, string) result =
  let h name = Httpun.Headers.get request.Httpun.Request.headers name in
  let ci_eq a b = String.equal (String.lowercase_ascii a) b in
  let connection_lists_upgrade v =
    List.exists
      (fun tok -> ci_eq (String.trim tok) "upgrade")
      (String.split_on_char ',' v)
  in
  match
    request.Httpun.Request.meth, h "upgrade", h "connection",
    h "sec-websocket-key", h "sec-websocket-version"
  with
  | `GET, Some upgrade, Some connection, Some key, Some "13"
    when ci_eq upgrade "websocket"
         && connection_lists_upgrade connection
         && (try String.length (Base64.decode_exn key) = 16 with _ -> false) ->
    Ok (sec_websocket_accept key)
  | _ -> Error "websocket upgrade request did not pass RFC 6455 §4.2.1 scrutiny"

let respond_and_drive_upgrade
    ~(upgrade : Gluten.impl -> unit)
    ~(reqd : Httpun.Reqd.t)
    ~(max_message : int)
    ~(max_frame : int)
    ~(handler : Ws_wsd.t -> Ws_endpoint.handlers)
  : (unit, string) result =
  let request = Httpun.Reqd.request reqd in
  match ws_upgrade_accept request with
  | Error _ as e -> e
  | Ok accept ->
    let headers =
      Httpun.Headers.of_list
        [ "Upgrade", "websocket"
        ; "Connection", "Upgrade"
        ; "Sec-WebSocket-Accept", accept
        ]
    in
    (* Sends the 101 on the reqd, then the callback attaches the post-101
       socket: a ws-direct Endpoint (Server role) packaged as a Gluten.impl,
       drop-in for the former Httpun_ws.Server_connection. RFC-0287 §4.1. *)
    Httpun.Reqd.respond_with_upgrade reqd headers (fun () ->
      let endpoint =
        Ws_endpoint.create Ws_endpoint.Server ~max_message ~max_frame handler
      in
      upgrade (Ws_direct_gluten.impl endpoint));
    Ok ()

(** Handle an HTTP/1.1 [GET /ws] upgrade on the main HTTP origin using
    the shared MCP session protocol.  Requires the Gluten [upgrade]
    capability, threaded from the route via
    {!Http_server_eio.Router.ws_get}.  Returns [Ok ()] on a successful
    101 + drive, [Error msg] on handshake failure.

    @param on_message Callback for incoming text messages.
      Default: ignore. *)
let upgrade_connection
    ?sw
    ?clock
    ?(on_message = fun _session_id _text -> ())
    ~(upgrade : Gluten.impl -> unit)
    (reqd : Httpun.Reqd.t)
  : (unit, string) result =
  respond_and_drive_upgrade ~upgrade ~reqd
    ~max_message:(max_inbound_message_bytes ())
    ~max_frame:(max_inbound_frame_bytes ())
    ~handler:
      (mcp_websocket_handler ?sw ?clock ~on_message ~origin_label:"same-origin /ws")

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
