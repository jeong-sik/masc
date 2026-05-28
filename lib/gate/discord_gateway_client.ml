(* RFC-0203 Phase 1.2b.3 — I/O loop bridging Discord_wss_connection and
   Discord_gateway_state.

   Single session, no reconnect. Phase 1.4 will wrap this in a backoff
   loop that re-creates the WSS connection on Reconnect_requested. *)

type intent = Discord_gateway_state.intent =
  | Guilds
  | Guild_messages
  | Message_content
  | Guild_message_reactions
  | Direct_messages
  | Direct_message_reactions

type gateway_event = Discord_gateway_state.dispatched_event =
  | Ready of
      { session_id : string
      ; resume_gateway_url : string
      ; bot_user_id : string
      }
  | Message_create of
      { channel_id : string
      ; message_id : string
      ; author_id : string
      ; content : string
      ; mentions_bot : bool
      }
  | Reaction_add of
      { channel_id : string
      ; message_id : string
      ; user_id : string
      ; emoji : string
      }
  | Ignored of string

type trigger_policy = Discord_gateway_state.trigger_policy =
  | Mention_only
  | User_only of string
  | All

let intents_bitmask = Discord_gateway_state.intents_bitmask

(* now_mono as float seconds. State machine treats it as opaque; we only
   need it monotone-increasing. *)
let now_mono env =
  let m = Eio.Time.Mono.now (Eio.Stdenv.mono_clock env) in
  Int64.to_float (Mtime.to_uint64_ns m) /. 1e9

let frame_to_input frame =
  let module F = Websocket.Frame in
  match frame.F.opcode with
  | Text ->
    (match Yojson.Safe.from_string frame.F.content with
     | exception Yojson.Json_error msg ->
       Some (Discord_gateway_state.Frame_parse_error ("json: " ^ msg))
     | json ->
       (match Discord_gateway_state.parse_frame json with
        | Ok f -> Some (Discord_gateway_state.Frame_received f)
        | Error msg -> Some (Discord_gateway_state.Frame_parse_error msg)))
  | Close ->
    let content = frame.F.content in
    let code =
      if String.length content >= 2 then
        ((Char.code content.[0]) lsl 8) lor (Char.code content.[1])
      else 1005
    in
    let reason =
      if String.length content > 2
      then String.sub content 2 (String.length content - 2)
      else "remote close"
    in
    Some (Discord_gateway_state.Wss_closed { code; reason })
  | Binary | Continuation | Ping | Pong | Ctrl _ | Nonctrl _ ->
    (* Discord with compress=false uses only Text+Close on app frames;
       Ping/Pong are protocol-level and the websocket lib handles them
       transparently. *)
    None

(* Raised by run_effect when the state machine asks us to (re)open or
   close the WSS connection. Caught by the outer reconnect loop —
   currently a stub that surfaces a clear "Phase 1.4 not implemented"
   error rather than silently looping. *)
exception Reconnect_requested

let log_effect level message =
  let prefix = match level with
    | `Info -> "[discord] "
    | `Warn -> "[discord WARN] "
    | `Error -> "[discord ERROR] "
  in
  prerr_endline (prefix ^ message)

let run ~sw ~env ~token ~intents ~trigger_policy ~on_event () =
  let config : Discord_gateway_state.config = {
    token; intents; bot_user_id = None; trigger_policy;
  } in
  let state = ref (Discord_gateway_state.create ~config) in
  let conn_ref : Discord_wss_connection.conn option ref = ref None in
  let input_mailbox = Eio.Stream.create 64 in
  let heartbeat_ms = ref None in

  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (match !heartbeat_ms with
       | None ->
         Eio.Time.sleep clock 0.5
       | Some ms ->
         Eio.Time.sleep clock (float_of_int ms /. 1000.0);
         Eio.Stream.add input_mailbox Discord_gateway_state.Heartbeat_tick);
      loop ()
    in
    loop ());

  let reader_loop conn =
    let rec loop () =
      match Discord_wss_connection.read conn with
      | exception End_of_file ->
        Eio.Stream.add input_mailbox
          (Discord_gateway_state.Wss_closed { code = 1006; reason = "eof" })
      | exception e ->
        Eio.Stream.add input_mailbox
          (Discord_gateway_state.Wss_closed
             { code = 1011; reason = Printexc.to_string e })
      | frame ->
        (match frame_to_input frame with
         | Some inp -> Eio.Stream.add input_mailbox inp
         | None -> ());
        loop ()
    in
    loop ()
  in

  let run_effect (eff : Discord_gateway_state.gateway_effect) =
    let open Discord_gateway_state in
    match eff with
    | Open_wss { url } ->
      (match !conn_ref with
       | Some _ -> raise Reconnect_requested
       | None ->
         let conn = Discord_wss_connection.connect ~sw ~env ~url in
         conn_ref := Some conn;
         Eio.Fiber.fork ~sw (fun () -> reader_loop conn))
    | Close_wss _ -> raise Reconnect_requested
    | Send_frame f ->
      (match !conn_ref with
       | None -> failwith "Send_frame before WSS open"
       | Some conn ->
         let json = Discord_gateway_state.encode_frame f in
         let payload = Yojson.Safe.to_string json in
         let ws =
           Websocket.Frame.create ~opcode:Text ~content:payload ()
         in
         Discord_wss_connection.write conn ws)
    | Schedule_heartbeat { interval_ms } ->
      heartbeat_ms := Some interval_ms
    | Schedule_backoff _ -> raise Reconnect_requested
    | Emit_event ev -> on_event ev
    | Log { level; message } -> log_effect level message
  in

  let step_now input =
    let now = now_mono env in
    let (s', effects) = Discord_gateway_state.step !state ~now_mono:now input in
    state := s';
    List.iter run_effect effects
  in

  (* Kick off: state machine emits Open_wss + Log, which run_effect
     turns into the actual TCP+TLS+WSS handshake plus a reader fiber. *)
  step_now Discord_gateway_state.Connect_requested;

  (try
     let rec drive () =
       let input = Eio.Stream.take input_mailbox in
       step_now input;
       drive ()
     in
     drive ()
   with Reconnect_requested ->
     failwith
       "Discord_gateway_client.run: reconnect requested, but Phase 1.4 \
        (reconnect/resume) not yet implemented")
