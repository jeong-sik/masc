(** Standalone WebSocket server for MASC MCP.

    Runs on a separate port (default 8937, configurable via MASC_WS_PORT).
    Enabled by default. Disable with MASC_WS_ENABLED=0.

    Unlike the /ws upgrade path on the HTTP port, this server owns the
    full TCP socket, so httpun-ws can run the HTTP->WS upgrade lifecycle
    end-to-end without conflicting with gluten's protocol management.

    Session state is shared with {!Server_mcp_transport_ws}: the same
    [sessions] hashtable, [send_to_session], and [cleanup_session] are
    reused.  This module only handles TCP accept + connection handler
    wiring. *)

module Ws = Httpun_ws
module Ws_eio = Httpun_ws_eio

(** SSOT: [Env_config.Transport.ws_port]. *)
let default_port = Env_config.Transport.ws_port

(** Read the configured WS port from environment or use default. *)
let configured_port () = Env_config.Transport.ws_port

(** Check whether standalone WS is enabled (default: enabled).
    Disable with MASC_WS_ENABLED=0 or MASC_WS_ENABLED=false. *)
let is_enabled () =
  Transport_metrics.ws_enabled ()

(** Interval between protocol-level heartbeat pings on each WS session.

    30s strikes a balance between keeping NAT/proxy mappings warm
    (typical idle-mapping eviction is 60-120s) and not spamming the
    write path on a quiet connection.  The browser handles pong replies
    invisibly in the WebSocket implementation; the server detects dead
    peers when [Ws.Wsd.is_closed] flips or the underlying write raises a
    classify_write_failure-recognised error. *)
let heartbeat_interval_s = 30.0

let max_ws_close_reason_log_len = 96

let max_ws_close_payload_len = 125

let utf8_codepoint_width first_byte =
  let byte = Char.code first_byte in
  if byte land 0x80 = 0 then
    1
  else if byte land 0xE0 = 0xC0 then
    2
  else if byte land 0xF0 = 0xE0 then
    3
  else if byte land 0xF8 = 0xF0 then
    4
  else
    1

let truncate_ws_close_reason reason =
  if String.length reason <= max_ws_close_reason_log_len then
    reason
  else begin
    let rec boundary idx =
      if idx >= String.length reason || idx >= max_ws_close_reason_log_len then
        idx
      else
        let next_idx = idx + utf8_codepoint_width reason.[idx] in
        if next_idx > max_ws_close_reason_log_len then
          idx
        else
          boundary next_idx
    in
    String.sub reason 0 (boundary 0) ^ "...<truncated>"
  end

let summarize_ws_close_payload bytes ~received_len ~declared_len =
  if received_len = 0 then
    Printf.sprintf "code=none received_len=0 declared_len=%d" declared_len
  else if received_len = 1 then
    Printf.sprintf "malformed_close_payload received_len=1 declared_len=%d"
      declared_len
  else
    let code =
      (Char.code (Bytes.get bytes 0) lsl 8) lor Char.code (Bytes.get bytes 1)
    in
    let reason_len = received_len - 2 in
    let reason =
      if reason_len = 0 then
        "reason=<empty>"
      else
        let reason =
          Bytes.sub_string bytes 2 reason_len |> truncate_ws_close_reason
        in
        Printf.sprintf "reason=%S" reason
    in
    let partial =
      if received_len = declared_len then
        ""
      else
        " partial=true"
    in
    Printf.sprintf "code=%d %s received_len=%d declared_len=%d%s" code reason
      received_len declared_len partial

let immediate_ws_close_payload_summary ~declared_len =
  if declared_len <= 0 then
    Some (Printf.sprintf "code=none received_len=0 declared_len=%d" declared_len)
  else if declared_len > max_ws_close_payload_len then
    Some
      (Printf.sprintf "payload_len=%d exceeds_control_frame_limit"
         declared_len)
  else
    None

type ws_close_payload_chunk_plan =
  | Reject_empty_chunk of string
  | Copy_then_finish of { copy_len : int; next_offset : int }
  | Copy_then_continue of { copy_len : int; next_offset : int }

let plan_ws_close_payload_chunk ~offset ~declared_len ~chunk_len =
  if chunk_len <= 0 then
    Reject_empty_chunk
      (Printf.sprintf "payload_read_empty_chunk received_len=%d declared_len=%d"
         offset declared_len)
  else
    let remaining = max 0 (declared_len - offset) in
    let copy_len = min chunk_len remaining in
    let next_offset = offset + copy_len in
    if next_offset >= declared_len then
      Copy_then_finish { copy_len; next_offset }
    else
      Copy_then_continue { copy_len; next_offset }

module For_testing = struct
  let max_ws_close_reason_log_len = max_ws_close_reason_log_len

  let max_ws_close_payload_len = max_ws_close_payload_len

  let truncate_ws_close_reason = truncate_ws_close_reason

  let summarize_ws_close_payload = summarize_ws_close_payload

  let immediate_ws_close_payload_summary = immediate_ws_close_payload_summary

  type nonrec ws_close_payload_chunk_plan = ws_close_payload_chunk_plan =
    | Reject_empty_chunk of string
    | Copy_then_finish of { copy_len : int; next_offset : int }
    | Copy_then_continue of { copy_len : int; next_offset : int }

  let plan_ws_close_payload_chunk = plan_ws_close_payload_chunk
end

let log_ws_client_close_payload ~session_id ~declared_len payload =
  (* Terminal action for a single close-payload handling: log once + close
     payload once.  Every reachable leaf of the read state machine (early
     reject, on_eof, on_read completion, schedule re-entry on full buffer,
     exception) routes through here so the payload is never logged twice
     and never leaked. *)
  let finish =
    let finished = ref false in
    fun summary ->
      if not !finished then begin
        finished := true;
        Log.Server.debug "[ws-standalone] session %s client close (%s)"
          session_id summary;
        Ws.Payload.close payload
      end
  in
  match immediate_ws_close_payload_summary ~declared_len with
  | Some summary -> finish summary
  | None ->
    let buffer = Bytes.create declared_len in
    let offset = ref 0 in
    let rec schedule () =
      if !offset >= declared_len then
        finish
          (summarize_ws_close_payload buffer ~received_len:!offset
             ~declared_len)
      else
        Ws.Payload.schedule_read payload
          ~on_eof:(fun () ->
            finish
              (summarize_ws_close_payload buffer ~received_len:!offset
                 ~declared_len))
          ~on_read:(fun bs ~off ~len:chunk_len ->
            match
              plan_ws_close_payload_chunk ~offset:!offset ~declared_len
                ~chunk_len
            with
            | Reject_empty_chunk summary -> finish summary
            | Copy_then_finish { copy_len; next_offset } ->
                Bigstringaf.blit_to_bytes bs ~src_off:off buffer
                  ~dst_off:!offset ~len:copy_len;
                offset := next_offset;
                finish
                  (summarize_ws_close_payload buffer ~received_len:!offset
                     ~declared_len)
            | Copy_then_continue { copy_len; next_offset } ->
                Bigstringaf.blit_to_bytes bs ~src_off:off buffer
                  ~dst_off:!offset ~len:copy_len;
                offset := next_offset;
                schedule ())
    in
    try schedule () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        finish
          (Printf.sprintf "payload_read_error=%s declared_len=%d"
             (Printexc.to_string exn) declared_len)

let standalone_ws_eof_summary = function
  | None -> "error=none"
  | Some (`Exn exn) -> Printf.sprintf "error=%s" (Printexc.to_string exn)

(** WebSocket handler factory.

    For each accepted connection, httpun-ws-eio calls this with the
    client address and a [Wsd.t].  We create a session in the shared
    registry and wire frame callbacks to [on_message].

    [~sw] is the server-wide switch — heartbeat fibers fork onto it and
    self-exit as soon as the session closes.  [~clock] drives the
    heartbeat sleep. *)
let make_websocket_handler ~sw ~clock ~on_message _client_addr
    (wsd : Ws.Wsd.t) : Ws.Websocket_connection.input_handlers =
  let session_id = Server_mcp_transport_ws.next_id () in
  let session = Server_mcp_transport_ws.new_session ~id:session_id ~wsd in
  Server_mcp_transport_ws.with_sessions_rw (fun () ->
    Hashtbl.replace Server_mcp_transport_ws.sessions session_id session);
  Transport_metrics.set_ws_sessions
    (Server_mcp_transport_ws.with_sessions_rw (fun () ->
       Hashtbl.length Server_mcp_transport_ws.sessions));
  (* Register as SSE external subscriber for broadcast events *)
  Sse.subscribe_external ~id:session_id
    ~is_alive:(fun () ->
      not session.closed && not (Ws.Wsd.is_closed session.wsd))
    ~callback:(fun sse_event ->
      if not session.closed
         && not
              (Server_mcp_transport_ws.send_dashboard_or_raw_sse session
                 sse_event)
      then begin
        Log.Server.debug
          "[ws-standalone] session %s sse-forward send failed; cleaning up"
          session_id;
        Server_mcp_transport_ws.cleanup_session session_id
      end)
    ();
  (* Heartbeat fiber: emit a protocol-level ping every
     [heartbeat_interval_s] to keep NAT/proxy mappings warm and surface
     silent disconnects so the reconnect path on the client can engage
     instead of hanging on a dead socket.  Exits once [session.closed]
     flips or the writer is closed, so it does not outlive the
     connection beyond one sleep tick. *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock heartbeat_interval_s;
      if not session.closed && not (Ws.Wsd.is_closed session.wsd) then begin
        let send_failed = ref false in
        (try Ws.Wsd.send_ping wsd with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn -> (
             send_failed := true;
             match
               Http_server_eio.Late_response.classify_write_failure exn
             with
             | Some _ ->
                 Log.Server.debug
                   "[ws-standalone] session %s heartbeat skipped (writer \
                    closed during cancel race)"
                   session_id
             | None ->
                 Log.Server.warn
                   "[ws-standalone] session %s heartbeat send_ping failed: %s"
                   session_id (Printexc.to_string exn)));
        if !send_failed then begin
          (* If send_ping failed while [session.closed]/[Wsd.is_closed]
             still read false, the loop would otherwise spin emitting
             warnings until the WSD finally observed the broken socket.
             Mark the session closed and run [cleanup_session] now so
             the rest of the pipeline (sessions table, heartbeat budget,
             aggregate metrics) drops the half-open session immediately
             instead of leaking a fiber per failure. *)
          Server_mcp_transport_ws.cleanup_session session_id
        end else
          loop ()
      end
    in
    loop ());
  (* #10875: WS storm (#10701) emits ~190k connect/close lines/day at INFO,
     drowning real signal in noise. Per-session lifecycle is DEBUG; aggregate
     state surfaces via Transport_metrics.set_ws_sessions and shutdown_hooks
     summary INFO. *)
  Log.Server.debug "WebSocket session %s connected (standalone port)" session_id;
  { Ws.Websocket_connection.
    frame = (fun ~opcode ~is_fin ~len payload ->
      match opcode with
      | `Text | `Binary | `Continuation ->
        Server_mcp_transport_ws.read_inbound_message_frame session
          ~on_message ~is_fin ~len payload
      | `Ping ->
        (* Guard against "cannot write to closed writer" when the WSD is
           closed during a cancel/disconnect race (2026-05-05 cycle9 incident).
           The outer connection_handler catch already swallows these, but
           wrapping here makes the intent explicit and avoids an intermediate
           httpun-ws state-machine inconsistency.

           Use the centralized [Late_response.classify_write_failure]
           SSOT so the recognized "writer closed during cancel" race
           is downgraded to debug here too — matching the outer
           connection_handler.  Anything the classifier does not own
           (genuine bugs / unexpected exceptions) still warns.  This
           closes the warn-noise gap reported in #13082 review. *)
        (try Ws.Wsd.send_pong wsd
         with Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                (match
                   Http_server_eio.Late_response.classify_write_failure exn
                 with
                 | Some _ ->
                     Log.Server.debug
                       "[ws-standalone] send_pong skipped (writer closed during \
                        cancel race)"
                 | None ->
                     Log.Server.warn
                       "[ws-standalone] send_pong failed: %s"
                       (Printexc.to_string exn)));
        Ws.Payload.close payload
      | `Connection_close ->
        log_ws_client_close_payload ~session_id ~declared_len:len payload;
        Server_mcp_transport_ws.cleanup_session session_id;
      | `Pong | `Other _ ->
        Ws.Payload.close payload
    );
    eof = (fun ?error () ->
      Log.Server.debug "[ws-standalone] session %s eof (%s)" session_id
        (standalone_ws_eof_summary error);
      Server_mcp_transport_ws.cleanup_session session_id)
  }

(** Start the standalone WebSocket server.

    Forks a fiber that listens for TCP connections and runs the
    httpun-ws-eio connection handler for each.  Does nothing if
    [MASC_WS_ENABLED] is not set.

    @param sw Eio switch for structured concurrency.
    @param env Eio environment (for network access).
    @param on_message Called with [(session_id, body_str)] for each
      inbound text frame. *)
let start
    ~(sw : Eio.Switch.t)
    ~(env : Eio_unix.Stdenv.base)
    ~(on_message : string -> string -> unit)
  : unit =
  if not (is_enabled ()) then begin
    Transport_metrics.set_ws_runtime_listening false;
    Transport_metrics.set_ws_listen_status "disabled";
    Log.Server.info "WebSocket transport disabled (MASC_WS_ENABLED=0)"
  end else begin
    let port = configured_port () in
    let net = Eio.Stdenv.net env in
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    (* Isolate bind failure so it does not propagate to the bootstrap
       catch-all and mark the entire startup as Degraded (#3408). *)
    match Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:128 addr with
    | socket ->
      Transport_metrics.set_ws_runtime_listening true;
      Transport_metrics.set_ws_listen_status "listening";
      let clock = Eio.Stdenv.clock env in
      let connection_handler =
        Ws_eio.Server.create_connection_handler ~sw
          (make_websocket_handler ~sw ~clock ~on_message)
      in
      Eio.Fiber.fork ~sw (fun () ->
        (* Safe: finally is Atomic.set — no I/O, no exception risk *)
        Fun.protect
          ~finally:(fun () ->
            Transport_metrics.set_ws_runtime_listening false;
            Transport_metrics.set_ws_listen_status "stopped")
          (fun () ->
            Log.Server.info "WebSocket server starting on port %d" port;
            let rec accept_loop backoff_s =
              try
                let flow, client_addr = Eio.Net.accept ~sw socket in
                Eio.Fiber.fork ~sw (fun () ->
                  (* Per-connection switch so the accepted [flow] is
                     released the moment the WS handler exits, not when
                     the long-lived server [sw] closes. Without this
                     each connection's FD lingers in the kernel [CLOSED]
                     state until shutdown — a 1Hz dashboard reconnect
                     (claude-in-chrome's playwright Chrome polls
                     [ws://127.0.0.1:8937/]) accumulates ~3 600 FDs/h,
                     tripping [admission_queue_rejected: fd count >= 90%]
                     and starving every keeper subprocess. Pattern
                     matches [http_server_h2.ml]'s accept loop. *)
                  Eio.Switch.run (fun conn_sw ->
                    Eio.Switch.on_release conn_sw (fun () ->
                      try Eio.Flow.close flow with
                      | Eio.Cancel.Cancelled _ as e -> raise e
                      | exn ->
                        Log.Server.warn
                          "[ws-standalone] flow close failed: %s"
                          (Printexc.to_string exn));
                    try connection_handler client_addr flow
                    with
                    | Eio.Cancel.Cancelled _ as e -> raise e
                    | exn -> (
                      match
                        Http_server_eio.Late_response.classify_write_failure
                          exn
                      with
                      | Some _ ->
                          Log.Server.debug
                            "WS standalone handler closed before write completed"
                      | None ->
                          Log.Server.warn "WS standalone handler error: %s"
                            (Printexc.to_string exn))));
                accept_loop 0.05
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Server.error "WS standalone accept error: %s"
                  (Printexc.to_string exn);
                (* Backoff to avoid tight error loops *)
                (try Eio.Time.sleep (Eio.Stdenv.clock env) backoff_s
                 with Eio.Cancel.Cancelled _ as e -> raise e
                    | exn ->
                        Log.Server.warn
                          "WS standalone backoff sleep failed on port %d (backoff=%.2fs): %s"
                          port backoff_s (Printexc.to_string exn));
                let next_backoff = Float.min 2.0 (backoff_s *. 1.5) in
                accept_loop next_backoff
            in
            accept_loop 0.05))
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
      Transport_metrics.set_ws_runtime_listening false;
      Transport_metrics.set_ws_listen_status "bind_failed";
      Log.Server.error
        "WebSocket transport unavailable on 127.0.0.1:%d: port already in use"
        port
    | exception exn ->
      Transport_metrics.set_ws_runtime_listening false;
      Transport_metrics.set_ws_listen_status "bind_failed";
      Log.Server.error "WebSocket bind failed on port %d: %s"
        port (Printexc.to_string exn)
  end
