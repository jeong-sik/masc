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

(** Active WebSocket session state. *)
type ws_session = {
  id: string;
  wsd: Httpun_ws.Wsd.t;
  mutable closed: bool;
  mutable dashboard_authenticated: bool;
  mutable dashboard_agent: string option;
  mutable dashboard_route: string option;
  dashboard_slices: (string, unit) Hashtbl.t;
  mutable dashboard_seq: int;
  mutable inbound_partial_text: Buffer.t option;
}

(** Registry of active WebSocket sessions. *)
let sessions : (string, ws_session) Hashtbl.t = Hashtbl.create 16
let sessions_mutex = Eio.Mutex.create ()

let with_sessions_rw f = Eio_guard.with_mutex sessions_mutex f

(** Generate a unique session ID. *)
let next_id =
  let counter = Atomic.make 0 in
  fun () ->
    let n = Atomic.fetch_and_add counter 1 in
    Printf.sprintf "ws-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) n

let log_ws_delivery_dropped ~context session_id =
  Log.Transport.warn "WS %s not delivered for session=%s" context session_id

let new_session ~id ~wsd =
  {
    id;
    wsd;
    closed = false;
    dashboard_authenticated = false;
    dashboard_agent = None;
    dashboard_route = None;
    dashboard_slices = Hashtbl.create 8;
    dashboard_seq = 0;
    inbound_partial_text = None;
  }

(** Send a pre-allocated frame to a WebSocket client.

    The caller owns the [bytes] buffer; this function only reads it.  In
    server mode httpun-ws does not mask (see httpun-ws 0.2.0
    [Serialize.serialize_bytes]: [apply_mask_bytes] is only called when
    [mode = `Client]), and [Faraday.write_bytes] copies into its internal
    buffer synchronously, so the same [bytes] value can safely be passed
    to multiple sessions in one broadcast without re-allocation. *)
let send_frame_bytes session bytes ~len =
  if session.closed || Httpun_ws.Wsd.is_closed session.wsd then begin
    session.closed <- true;
    false
  end else begin
    try
      Httpun_ws.Wsd.send_bytes session.wsd
        ~kind:`Text bytes ~off:0 ~len;
      true
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Transport.warn "WS text send failed for session=%s: %s" session.id
        (Printexc.to_string exn);
      session.closed <- true;
      false
  end

(** Send a text frame to a WebSocket client.
    Allocates [Bytes.t] per call — fine for single-destination sends.
    Multicast paths should go through [send_text_shared] instead so the
    bytes allocation is paid once per broadcast, not once per session. *)
let send_text session text =
  let bytes = Bytes.of_string text in
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
  if cached_str == text then cached_bytes
  else begin
    let bytes = Bytes.of_string text in
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
  | "project_snapshot" | "namespace_truth_snapshot" | "room_truth_snapshot" ->
      Some "namespace"
  | "execution_snapshot" ->
      Some "execution"
  | "operator_snapshot" | "operator_digest" ->
      Some "operator"
  | "transport_health_snapshot" ->
      Some "transport"
  | _ -> None

let dashboard_session_result session =
  let slices =
    Hashtbl.fold (fun slice () acc -> `String slice :: acc)
      session.dashboard_slices []
    |> List.sort compare
  in
  `Assoc
    [
      ("protocol", `String "dashboard-ws.v1");
      ("session_id", `String session.id);
      ("authenticated", `Bool session.dashboard_authenticated);
      ( "agent",
        match session.dashboard_agent with
        | Some agent -> `String agent
        | None -> `Null );
      ( "route",
        match session.dashboard_route with
        | Some route -> `String route
        | None -> `Null );
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
  if not auth_cfg.Types.enabled then
    Ok None
  else
    match token with
    | None when not auth_cfg.require_token ->
        (match Auth.check_permission base_path ~agent_name:"dashboard"
                 ~token:None ~permission:Types.CanReadState with
         | Ok () -> Ok None
         | Error err -> Error (Types.masc_error_to_string err))
    | None ->
        Error "dashboard/hello requires a bearer token"
    | Some raw_token -> (
        match Auth.find_credential_by_token base_path ~token:raw_token with
        | Error err -> Error (Types.masc_error_to_string err)
        | Ok cred -> (
            match
              Auth.check_permission base_path ~agent_name:cred.Types.agent_name
                ~token:(Some raw_token) ~permission:Types.CanReadState
            with
            | Ok () -> Ok (Some cred.Types.agent_name)
            | Error err -> Error (Types.masc_error_to_string err)))

let dashboard_hello ~base_path ~session_id ?token () =
  match find_session session_id with
  | None -> Error "WebSocket session not found"
  | Some session -> (
      match verify_dashboard_token ~base_path token with
      | Error msg -> Error msg
      | Ok agent ->
          session.dashboard_authenticated <- true;
          session.dashboard_agent <- agent;
          Ok (dashboard_auth_success_payload session))

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
      ( "route",
        match session.dashboard_route with
        | Some route -> `String route
        | None -> `Null );
      ("slices", `Assoc slices);
    ]

let dashboard_subscribe ~session_id ?route ~slices () =
  match find_session session_id with
  | None -> Error "WebSocket session not found"
  | Some session ->
      if not session.dashboard_authenticated then
        Error "dashboard/subscribe requires dashboard/hello first"
      else begin
        let invalid =
          List.filter (fun slice -> not (valid_dashboard_slice slice)) slices
        in
        match invalid with
        | bad :: _ ->
            Error (Printf.sprintf "unsupported dashboard slice: %s" bad)
        | [] ->
            Hashtbl.clear session.dashboard_slices;
            List.iter
              (fun slice -> Hashtbl.replace session.dashboard_slices slice ())
              slices;
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
      if not session.dashboard_authenticated then
        Error "dashboard/unsubscribe requires dashboard/hello first"
      else begin
        (match slices with
         | None -> Hashtbl.clear session.dashboard_slices
         | Some slices ->
             List.iter (fun slice -> Hashtbl.remove session.dashboard_slices slice)
               slices);
        Ok (`Assoc [ ("session", dashboard_session_result session) ])
      end

let dashboard_ack ~session_id ~seq =
  match find_session session_id with
  | None -> Error "WebSocket session not found"
  | Some session ->
      if not session.dashboard_authenticated then
        Error "dashboard/ack requires dashboard/hello first"
      else
        Ok
          (`Assoc
            [
              ("session_id", `String session.id);
              ("ack", `Int seq);
            ])

(** Shape of an SSE event after dashboard-oriented parsing.
    [slice] is [None] when the event does not map to a dashboard slice,
    in which case delivery falls through to raw SSE forwarding. *)
type parsed_sse_event = {
  event_type: string;
  slice: string option;
  payload: Yojson.Safe.t;
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

let parse_sse_dashboard_event sse_event =
  let cached_str, cached_val = Atomic.get parse_cache in
  if cached_str == sse_event then begin
    Transport_metrics.inc_ws_parse_cache_hit ();
    cached_val
  end
  else begin
    Transport_metrics.inc_ws_parse_cache_miss ();
    let result =
      match Yojson.Safe.from_string sse_event with
      | exception _ -> None
      | `Assoc fields as event_json -> (
          match List.assoc_opt "type" fields with
          | Some (`String event_type) ->
              let payload =
                match List.assoc_opt "payload" fields with
                | Some payload -> payload
                | None -> event_json
              in
              let slice = dashboard_slice_for_sse_type event_type in
              Some { event_type; slice; payload }
          | _ -> None)
      | _ -> None
    in
    Atomic.set parse_cache (sse_event, result);
    result
  end

let dashboard_delta_for_sse session sse_event =
  match parse_sse_dashboard_event sse_event with
  | Some { event_type; slice = Some slice; payload }
    when Hashtbl.mem session.dashboard_slices slice ->
      Some
        (jsonrpc_notification "dashboard/delta"
           (`Assoc
             [
               ("protocol", `String "dashboard-ws.v1");
               ("seq", `Int (next_dashboard_seq session));
               ("slice", `String slice);
               ("event_type", `String event_type);
               ("mode", `String "snapshot");
               ("payload", payload);
               ("ts_unix", `Float (Time_compat.now ()));
             ]))
  | _ -> None

let send_dashboard_or_raw_sse session sse_event =
  if session.dashboard_authenticated then
    match dashboard_delta_for_sse session sse_event with
    | Some delta ->
        (* Delta carries a per-session [seq], so the encoded text is unique
           per session and cannot be shared. *)
        send_json_checked ~context:"dashboard-delta" session delta
    | None ->
        (* Same event string is forwarded verbatim to every session that
           does not match a subscribed dashboard slice; the shared cache
           collapses N identical [Bytes.of_string] allocations into 1. *)
        send_text_shared_checked ~context:"sse-forward" session sse_event
  else
    send_text_shared_checked ~context:"sse-forward" session sse_event

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

let handle_inbound_text session ~on_message ~is_fin text =
  match session.inbound_partial_text, is_fin with
  | None, true ->
      if String.length text > 0 then
        on_message session.id text
  | None, false ->
      let buffer = Buffer.create (max 16 (String.length text * 2)) in
      Buffer.add_string buffer text;
      session.inbound_partial_text <- Some buffer
  | Some buffer, _ ->
      Buffer.add_string buffer text;
      if is_fin then begin
        session.inbound_partial_text <- None;
        let message = Buffer.contents buffer in
        if String.length message > 0 then
          on_message session.id message
      end

let read_inbound_message_frame session ~on_message ~is_fin ~len payload =
  read_payload_string payload ~len ~on_complete:(fun text ->
      handle_inbound_text session ~on_message ~is_fin text)

(** Remove a session and unsubscribe from SSE. *)
let cleanup_session session_id =
  let removed =
    with_sessions_rw (fun () ->
        match Hashtbl.find_opt sessions session_id with
        | None -> false
        | Some session ->
            session.closed <- true;
            (try Httpun_ws.Wsd.close session.wsd
             with Eio.Cancel.Cancelled _ as e -> raise e
                | exn -> Log.Server.warn "WS close failed for %s: %s" session_id (Printexc.to_string exn));
            Hashtbl.remove sessions session_id;
            true)
  in
  Transport_metrics.set_ws_sessions
    (with_sessions_rw (fun () -> Hashtbl.length sessions));
  Sse.unsubscribe_external session_id;
  if removed then
    Log.Server.info "WebSocket session %s closed" session_id

(** Number of active WebSocket sessions. *)
let session_count () =
  with_sessions_rw (fun () ->
    Hashtbl.length sessions)

(** Handle an HTTP upgrade request to WebSocket.

    Call this from the httpun request handler when path = "/ws".
    Returns [Ok ()] on successful upgrade, [Error msg] on failure.

    @param reqd The httpun request descriptor.
    @param on_message Optional callback for incoming text messages.
      Default: log and ignore. *)
let upgrade_connection
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
            ~is_alive:(fun () ->
              not session.closed && not (Httpun_ws.Wsd.is_closed session.wsd))
            ~callback:(fun sse_event ->
              if not session.closed
                 && not (send_dashboard_or_raw_sse session sse_event)
              then
                cleanup_session session_id)
            ();
          Log.Server.info "WebSocket session %s connected" session_id;
          { Httpun_ws.Websocket_connection.
            frame = (fun ~opcode ~is_fin ~len payload ->
              match opcode with
              | `Text | `Binary | `Continuation ->
                read_inbound_message_frame session ~on_message ~is_fin ~len
                  payload
              | `Ping ->
                Httpun_ws.Wsd.send_pong wsd;
                Httpun_ws.Payload.close payload
              | `Connection_close ->
                cleanup_session session_id;
                Httpun_ws.Payload.close payload
              | `Pong | `Other _ ->
                Httpun_ws.Payload.close payload
            );
            eof = (fun ?error:_ () ->
              cleanup_session session_id)
          })
    in
    (* The ws_conn needs to be driven by the I/O loop.
       httpun-ws handles this internally when using respond_with_upgrade. *)
    ignore ws_conn)

(** Send a text frame to a specific session by ID.
    Returns [false] if the session is not found or the send fails. *)
let send_to_session session_id text =
  let session_opt =
    with_sessions_rw (fun () -> Hashtbl.find_opt sessions session_id)
  in
  match session_opt with
  | None -> false
  | Some session ->
      let sent = send_text_checked ~context:"send-to-session" session text in
      if not sent then cleanup_session session_id;
      sent

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
