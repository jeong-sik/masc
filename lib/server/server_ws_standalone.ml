(** Standalone WebSocket server for MASC MCP.

    Runs on a separate port (default 8937, configurable via MASC_WS_PORT).
    Session state is shared with {!Server_mcp_transport_ws}; this module only
    wires TCP accept + the httpun-ws connection handler. *)

module Ws = Httpun_ws
module Ws_eio = Httpun_ws_eio

(** SSOT: [Env_config.Transport.ws_port]. *)
let default_port = Env_config.Transport.ws_port

(** Read the configured WS port from environment or use default. *)
let configured_port () = Env_config.Transport.ws_port

(** Check whether standalone WS is enabled (default: enabled).
    Disable with MASC_WS_ENABLED=0 or MASC_WS_ENABLED=false. *)
let is_enabled () = Transport_metrics.ws_enabled ()

(** Interval between protocol-level heartbeat pings on each WS session. *)
let heartbeat_interval_s = 30.0

(** Default consecutive unanswered pings before the server closes the session.
    Override with [MASC_WS_MISSED_PONG_THRESHOLD]. *)
let pong_timeout_intervals = 3

(** Configurable missed-pong threshold. [0] disables the guard; negatives are
    clamped to [0].  Read once per session. *)
let missed_pong_threshold () =
  max 0 (Env_config_core.get_int ~default:pong_timeout_intervals "MASC_WS_MISSED_PONG_THRESHOLD")

(** Cap for accept-error exponential backoff. *)
let accept_backoff_cap_s = 5.0

(** Factor for accept-error backoff jitter (±20%). *)
let accept_backoff_jitter_frac = 0.2

let max_ws_close_reason_log_len = 96
let max_ws_close_payload_len = 125

let utf8_codepoint_width first_byte =
  let byte = Char.code first_byte in
  if byte land 0x80 = 0
  then 1
  else if byte land 0xE0 = 0xC0
  then 2
  else if byte land 0xF0 = 0xE0
  then 3
  else if byte land 0xF8 = 0xF0
  then 4
  else 1
;;

let truncate_ws_close_reason reason =
  if String.length reason <= max_ws_close_reason_log_len
  then reason
  else (
    let rec boundary idx =
      if idx >= String.length reason || idx >= max_ws_close_reason_log_len
      then idx
      else (
        let next_idx = idx + utf8_codepoint_width reason.[idx] in
        if next_idx > max_ws_close_reason_log_len then idx else boundary next_idx)
    in
    String.sub reason 0 (boundary 0) ^ "...<truncated>")
;;

let summarize_ws_close_payload bytes ~received_len ~declared_len =
  if received_len = 0
  then Printf.sprintf "code=none received_len=0 declared_len=%d" declared_len
  else if received_len = 1
  then
    Printf.sprintf "malformed_close_payload received_len=1 declared_len=%d" declared_len
  else (
    let code = (Char.code (Bytes.get bytes 0) lsl 8) lor Char.code (Bytes.get bytes 1) in
    let reason_len = received_len - 2 in
    let reason =
      if reason_len = 0
      then "reason=<empty>"
      else (
        let reason = Bytes.sub_string bytes 2 reason_len |> truncate_ws_close_reason in
        Printf.sprintf "reason=%S" reason)
    in
    let partial = if received_len = declared_len then "" else " partial=true" in
    Printf.sprintf
      "code=%d %s received_len=%d declared_len=%d%s"
      code
      reason
      received_len
      declared_len
      partial)
;;

let immediate_ws_close_payload_summary ~declared_len =
  if declared_len <= 0
  then Some (Printf.sprintf "code=none received_len=0 declared_len=%d" declared_len)
  else if declared_len > max_ws_close_payload_len
  then Some (Printf.sprintf "payload_len=%d exceeds_control_frame_limit" declared_len)
  else None
;;

type ws_close_payload_chunk_plan =
  | Reject_empty_chunk of string
  | Copy_then_finish of
      { copy_len : int
      ; next_offset : int
      }
  | Copy_then_continue of
      { copy_len : int
      ; next_offset : int
      }

let plan_ws_close_payload_chunk ~offset ~declared_len ~chunk_len =
  if chunk_len <= 0
  then
    Reject_empty_chunk
      (Printf.sprintf
         "payload_read_empty_chunk received_len=%d declared_len=%d"
         offset
         declared_len)
  else (
    let remaining = max 0 (declared_len - offset) in
    let copy_len = min chunk_len remaining in
    let next_offset = offset + copy_len in
    if next_offset >= declared_len
    then Copy_then_finish { copy_len; next_offset }
    else Copy_then_continue { copy_len; next_offset })
;;

module For_testing = struct
  let max_ws_close_reason_log_len = max_ws_close_reason_log_len
  let max_ws_close_payload_len = max_ws_close_payload_len
  let truncate_ws_close_reason = truncate_ws_close_reason
  let summarize_ws_close_payload = summarize_ws_close_payload
  let immediate_ws_close_payload_summary = immediate_ws_close_payload_summary

  type nonrec ws_close_payload_chunk_plan = ws_close_payload_chunk_plan =
    | Reject_empty_chunk of string
    | Copy_then_finish of
        { copy_len : int
        ; next_offset : int
        }
    | Copy_then_continue of
        { copy_len : int
        ; next_offset : int
        }

  let plan_ws_close_payload_chunk = plan_ws_close_payload_chunk

  let heartbeat_interval_s = heartbeat_interval_s
  let pong_timeout_intervals = pong_timeout_intervals
  let missed_pong_threshold = missed_pong_threshold
  let accept_backoff_cap_s = accept_backoff_cap_s

  (** Deterministic next accept-error backoff (production adds jitter). *)
  let next_accept_backoff backoff_s = Float.min accept_backoff_cap_s (backoff_s *. 1.5)
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
      if not !finished
      then (
        finished := true;
        Log.Server.debug "[ws-standalone] session %s client close (%s)" session_id summary;
        Ws.Payload.close payload)
  in
  match immediate_ws_close_payload_summary ~declared_len with
  | Some summary -> finish summary
  | None ->
    let buffer = Bytes.create declared_len in
    let offset = ref 0 in
    let rec schedule () =
      if !offset >= declared_len
      then finish (summarize_ws_close_payload buffer ~received_len:!offset ~declared_len)
      else
        Ws.Payload.schedule_read
          payload
          ~on_eof:(fun () ->
            finish (summarize_ws_close_payload buffer ~received_len:!offset ~declared_len))
          ~on_read:(fun bs ~off ~len:chunk_len ->
            match
              plan_ws_close_payload_chunk ~offset:!offset ~declared_len ~chunk_len
            with
            | Reject_empty_chunk summary -> finish summary
            | Copy_then_finish { copy_len; next_offset } ->
              Bigstringaf.blit_to_bytes
                bs
                ~src_off:off
                buffer
                ~dst_off:!offset
                ~len:copy_len;
              offset := next_offset;
              finish
                (summarize_ws_close_payload buffer ~received_len:!offset ~declared_len)
            | Copy_then_continue { copy_len; next_offset } ->
              Bigstringaf.blit_to_bytes
                bs
                ~src_off:off
                buffer
                ~dst_off:!offset
                ~len:copy_len;
              offset := next_offset;
              schedule ())
    in
    (try schedule () with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       finish
         (Printf.sprintf
            "payload_read_error=%s declared_len=%d"
            (Printexc.to_string exn)
            declared_len))
;;

let standalone_ws_eof_summary = function
  | None -> "error=none"
  | Some (`Exn exn) -> Printf.sprintf "error=%s" (Printexc.to_string exn)
;;

(** WebSocket handler factory.  [~sw] is the per-connection switch so heartbeat
    fibers exit with the connection instead of lingering on the server switch. *)
let make_websocket_handler ~sw ~clock ~on_message _client_addr (wsd : Ws.Wsd.t)
  : Ws.Websocket_connection.input_handlers
  =
  let session_id = Server_mcp_transport_ws.next_id () in
  let session = Server_mcp_transport_ws.new_session ~id:session_id ~wsd in
  Server_mcp_transport_ws.with_sessions_rw (fun () ->
    Hashtbl.replace Server_mcp_transport_ws.sessions session_id session);
  Transport_metrics.set_ws_sessions
    (Server_mcp_transport_ws.with_sessions_rw (fun () ->
       Hashtbl.length Server_mcp_transport_ws.sessions));
  (* Register as SSE external subscriber for broadcast events *)
  Sse.subscribe_external
    ~id:session_id
    ~is_alive:(fun () -> not (Server_mcp_transport_ws.is_session_closed session))
    ~callback:(fun sse_event ->
      if
        (not (Server_mcp_transport_ws.is_session_closed session))
        && not (Server_mcp_transport_ws.send_dashboard_or_raw_sse session sse_event)
      then (
        Log.Server.debug
          "[ws-standalone] session %s sse-forward send failed; cleaning up"
          session_id;
        Server_mcp_transport_ws.cleanup_session session_id))
    ();
  (* Heartbeat fiber: ping every [heartbeat_interval_s], count missed pongs,
     and close the session once the threshold is reached. *)
  let threshold = missed_pong_threshold () in
  Eio.Fiber.fork ~sw (fun () ->
    let send_ping () =
      Eio_guard.with_mutex session.write_mutex (fun () ->
        if not (Server_mcp_transport_ws.is_session_closed session) then
          Ws.Wsd.send_ping session.wsd)
    in
    let rec loop () =
      Eio.Time.sleep clock heartbeat_interval_s;
      if Server_mcp_transport_ws.is_session_closed session
      then ()
      else begin
        let missed = Atomic.get session.missed_pongs in
        if threshold > 0 && missed >= threshold
        then begin
          Log.Server.debug
            "[ws-standalone] session %s missed %d pongs; closing"
            session_id
            missed;
          Server_mcp_transport_ws.cleanup_session session_id
        end
        else begin
          let send_failed = ref false in
          (try send_ping () with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             send_failed := true;
             (match Http_server_eio.Late_response.classify_write_failure exn with
              | Some _ ->
                Log.Server.debug
                  "[ws-standalone] session %s heartbeat skipped (writer closed during \
                   cancel race)"
                  session_id
              | None ->
                Log.Server.warn
                  "[ws-standalone] session %s heartbeat send_ping failed: %s"
                  session_id
                  (Printexc.to_string exn)));
          if !send_failed
          then
            (* Drop the half-open session immediately so the loop does not
               spin until the WSD observes the broken socket. *)
            Server_mcp_transport_ws.cleanup_session session_id
          else begin
            Atomic.incr session.missed_pongs;
            loop ()
          end
        end
      end
    in
    loop ());
  (* #10875: WS storm (#10701) emits ~190k connect/close lines/day at INFO,
     drowning real signal in noise. Per-session lifecycle is DEBUG; aggregate
     state surfaces via Transport_metrics.set_ws_sessions and shutdown_hooks
     summary INFO. *)
  Log.Server.debug "WebSocket session %s connected (standalone port)" session_id;
  { Ws.Websocket_connection.frame =
      (fun ~opcode ~is_fin ~len payload ->
        match opcode with
        | `Text | `Binary | `Continuation ->
          Server_mcp_transport_ws.read_inbound_message_frame
            session
            ~on_message
            ~is_fin
            ~len
            payload
        | `Ping ->
          (* Serialize the pong through the write mutex and re-check closure
             under the lock to avoid racing cleanup/heartbeat.  Recognized
             "writer closed during cancel" races are downgraded to debug. *)
          (try
             Eio_guard.with_mutex session.write_mutex (fun () ->
               if not (Server_mcp_transport_ws.is_session_closed session) then
                 Ws.Wsd.send_pong session.wsd)
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             (match Http_server_eio.Late_response.classify_write_failure exn with
              | Some _ ->
                Log.Server.debug
                  "[ws-standalone] send_pong skipped (writer closed during cancel race)"
              | None ->
                Log.Server.warn
                  "[ws-standalone] send_pong failed: %s"
                  (Printexc.to_string exn)));
          Ws.Payload.close payload
        | `Pong ->
          Server_mcp_transport_ws.record_pong session;
          Ws.Payload.close payload
        | `Connection_close ->
          log_ws_client_close_payload ~session_id ~declared_len:len payload;
          Server_mcp_transport_ws.cleanup_session session_id
        | `Other _ -> Ws.Payload.close payload)
  ; eof =
      (fun ?error () ->
        Log.Server.debug
          "[ws-standalone] session %s eof (%s)"
          session_id
          (standalone_ws_eof_summary error);
        Server_mcp_transport_ws.cleanup_session session_id)
  }
;;

(** Start the standalone WebSocket server.  Does nothing if
    [MASC_WS_ENABLED] is not set. *)
let start
      ~(sw : Eio.Switch.t)
      ~(env : Eio_unix.Stdenv.base)
      ~(on_message : string -> string -> unit)
  : unit
  =
  if not (is_enabled ())
  then (
    Transport_metrics.set_ws_runtime_listening false;
    Transport_metrics.set_ws_listen_status "disabled";
    Log.Server.info "WebSocket transport disabled (MASC_WS_ENABLED=0)")
  else (
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
      Eio.Fiber.fork ~sw (fun () ->
        (* Safe: finally is Atomic.set — no I/O, no exception risk *)
        Eio_guard.protect
          ~finally:(fun () ->
            Transport_metrics.set_ws_runtime_listening false;
            Transport_metrics.set_ws_listen_status "stopped")
          (fun () ->
             Log.Server.info "WebSocket server starting on port %d" port;
             let rec accept_loop backoff_s =
               try
                 let flow, client_addr = Eio.Net.accept ~sw socket in
                 Eio.Fiber.fork ~sw (fun () ->
                   (* Per-connection switch releases [flow] as soon as the
                      handler exits, preventing FD accumulation.  The connection
                      handler and WebSocket handler are created here so the
                      heartbeat fiber runs on [conn_sw], not the server switch. *)
                   Eio.Switch.run (fun conn_sw ->
                     let connection_handler =
                       Ws_eio.Server.create_connection_handler
                         ~sw:conn_sw
                         (make_websocket_handler ~sw:conn_sw ~clock ~on_message)
                     in
                     Eio.Switch.on_release conn_sw (fun () ->
                       try Eio.Flow.close flow with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                         Log.Server.warn
                           "[ws-standalone] flow close failed: %s"
                           (Printexc.to_string exn));
                     try connection_handler client_addr flow with
                     | Eio.Cancel.Cancelled _ as e -> raise e
                     | exn ->
                       (match
                          Http_server_eio.Late_response.classify_write_failure exn
                        with
                        | Some _ ->
                          Log.Server.debug
                            "WS standalone handler closed before write completed"
                        | None ->
                          Log.Server.warn
                            "WS standalone handler error: %s"
                            (Printexc.to_string exn))));
                 accept_loop 0.05
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                 Log.Server.error
                   "WS standalone accept error: %s"
                   (Printexc.to_string exn);
                 (* Back off exponentially with jitter and a 5s cap. *)
                 (try Eio.Time.sleep (Eio.Stdenv.clock env) backoff_s with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                    Log.Server.warn
                      "WS standalone backoff sleep failed on port %d (backoff=%.2fs): %s"
                      port
                      backoff_s
                      (Printexc.to_string exn));
                 let base = Float.min accept_backoff_cap_s (backoff_s *. 1.5) in
                 let jitter =
                   base *. accept_backoff_jitter_frac *. ((Random.float 2.0) -. 1.0) (* NDT-OK: intentional jitter to avoid thundering-herd reconnects. *)
                 in
                 let next_backoff = Float.max 0.05 (base +. jitter) in
                 accept_loop next_backoff
             in
             accept_loop 0.05))
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
      Transport_metrics.set_ws_runtime_listening false;
      Transport_metrics.set_ws_listen_status "bind_failed";
      Log.Server.error
        "WebSocket transport unavailable on %s:%d: port already in use"
        Masc_network_defaults.masc_http_default_host
        port
    | exception exn ->
      Transport_metrics.set_ws_runtime_listening false;
      Transport_metrics.set_ws_listen_status "bind_failed";
      Log.Server.error
        "WebSocket bind failed on port %d: %s"
        port
        (Printexc.to_string exn))
;;
