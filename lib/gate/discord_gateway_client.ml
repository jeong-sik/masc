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
      ; author_name : string option
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

let log_effect level message =
  match level with
  | `Info -> Log.Discord.info "%s" message
  | `Warn -> Log.Discord.warn "%s" message
  | `Error -> Log.Discord.error "%s" message

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
       | Some _ ->
         log_effect `Warn
           "Open_wss while conn_ref still Some; expected Close_wss \
            first — dropping new connect"
       | None ->
         let conn = Discord_wss_connection.connect ~sw ~env ~url in
         conn_ref := Some conn;
         Eio.Fiber.fork ~sw (fun () -> reader_loop conn))
    | Close_wss _ ->
      (* Phase 1.4b: explicit close. Discord_wss_connection.close
         resolves the inner session switch's close-signal promise,
         which lets that switch return, which cancels reader/writer
         fibers and releases the socket + TLS flow. The reader's
         pending read raises Cancelled; our reader_loop exception
         arm pushes a redundant Wss_closed input that the state
         machine no-ops because it is already in Reconnect_pending. *)
      (match !conn_ref with
       | Some c -> Discord_wss_connection.close c
       | None -> ());
      conn_ref := None
    | Send_frame f ->
      (match !conn_ref with
       | None ->
         (* Late effect after conn cleared — drop with a log instead
            of crashing the drive loop. *)
         log_effect `Warn
           (Printf.sprintf
              "Send_frame op=%d while conn_ref is None; dropping"
              (Discord_gateway_state.opcode_to_int f.op))
       | Some conn ->
         let json = Discord_gateway_state.encode_frame f in
         let payload = Yojson.Safe.to_string json in
         let ws =
           Websocket.Frame.create ~opcode:Text ~content:payload ()
         in
         Discord_wss_connection.write conn ws)
    | Schedule_heartbeat { interval_ms } ->
      heartbeat_ms := Some interval_ms
    | Schedule_backoff { delay_ms } ->
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Time.sleep clock (float_of_int delay_ms /. 1000.0);
        Eio.Stream.add input_mailbox Discord_gateway_state.Backoff_elapsed)
    | Emit_event ev -> on_event ev
    | Log { level; message } -> log_effect level message
  in

  let step_now input =
    let now = now_mono env in
    let (s', effects) = Discord_gateway_state.step !state ~now_mono:now input in
    state := s';
    List.iter run_effect effects
  in

  step_now Discord_gateway_state.Connect_requested;

  let rec drive () =
    let input = Eio.Stream.take input_mailbox in
    step_now input;
    drive ()
  in
  drive ()
