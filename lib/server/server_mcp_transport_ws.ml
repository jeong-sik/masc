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

(** Send a text frame to a WebSocket client. *)
let send_text session text =
  if session.closed || Httpun_ws.Wsd.is_closed session.wsd then begin
    session.closed <- true;
    false
  end else begin
    try
      let bytes = Bytes.of_string text in
      Httpun_ws.Wsd.send_bytes session.wsd
        ~kind:`Text bytes ~off:0 ~len:(Bytes.length bytes);
      true
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Transport.warn "WS text send failed for session=%s: %s" session.id
        (Printexc.to_string exn);
      session.closed <- true;
      false
  end

let send_text_checked ~context session text =
  let sent = send_text session text in
  if not sent then log_ws_delivery_dropped ~context session.id;
  sent

(** Remove a session and unsubscribe from SSE. *)
let cleanup_session session_id =
  with_sessions_rw (fun () ->
    match Hashtbl.find_opt sessions session_id with
    | None -> ()
    | Some session ->
      session.closed <- true;
      (try Httpun_ws.Wsd.close session.wsd
       with Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> Log.Server.warn "WS close failed for %s: %s" session_id (Printexc.to_string exn));
      Hashtbl.remove sessions session_id);
  Transport_metrics.set_ws_sessions
    (with_sessions_rw (fun () -> Hashtbl.length sessions));
  Sse.unsubscribe_external session_id;
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
          let session = { id = session_id; wsd; closed = false } in
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
                 && not (send_text_checked ~context:"sse-forward" session sse_event)
              then
                cleanup_session session_id)
            ();
          Log.Server.info "WebSocket session %s connected" session_id;
          let buf = Buffer.create 4096 in
          { Httpun_ws.Websocket_connection.
            frame = (fun ~opcode ~is_fin:_ ~len:_ payload ->
              match opcode with
              | `Text | `Binary ->
                Buffer.clear buf;
                Httpun_ws.Payload.schedule_read payload
                  ~on_eof:(fun () ->
                    let text = Buffer.contents buf in
                    if String.length text > 0 then
                      on_message session_id text)
                  ~on_read:(fun bs ~off ~len ->
                    Buffer.add_string buf
                      (Bigstringaf.substring bs ~off ~len))
              | `Ping ->
                Httpun_ws.Wsd.send_pong wsd;
                Httpun_ws.Payload.close payload
              | `Connection_close ->
                cleanup_session session_id;
                Httpun_ws.Payload.close payload
              | `Pong | `Continuation | `Other _ ->
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
