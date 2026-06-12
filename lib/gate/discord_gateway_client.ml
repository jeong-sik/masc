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
      ; guild_id : string option
      ; message_id : string
      ; author_id : string
      ; author_name : string option
      ; content : string
      ; mention_user_ids : string list
      ; mentions_bot : bool
      ; explicit_mentions_bot : bool
      ; message_reference_channel_id : string option
      ; message_reference_message_id : string option
      ; referenced_message_author_id : string option
      }
  | Reaction_add of
      { channel_id : string
      ; message_id : string
      ; user_id : string
      ; emoji : string
      }
  | Thread_tracked of
      { thread_id : string
      ; parent_channel_id : string
      }
  | Threads_bulk_tracked of
      { threads : (string * string) list
      }
  | Thread_removed of
      { thread_id : string
      }
  | Ignored of string

type trigger_policy = Discord_gateway_state.trigger_policy =
  | Mention_only
  | Mention_or_thread
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

(* RFC-0223 P2: the run loop's connection state, published so presence
   derivation (Channel_gate_discord_state.connected) can read it without
   file indirection. One gateway per process (single bot token), so a
   module-level register is unambiguous. Written only by [run]'s
   state-machine step; everyone else reads. *)
let published_connection_state : Discord_gateway_state.connection_state Atomic.t
  =
  Atomic.make Discord_gateway_state.Disconnected

let connection_state () = Atomic.get published_connection_state

(* Module-level cell for the gateway's input mailbox, set by [run].
   Allows external callers to push [Status_change] inputs without
   a direct handle on the mailbox. One gateway is expected per process,
   but the release hook avoids leaving a stale stream after shutdown. *)
let input_mailbox_cell :
  Discord_gateway_state.input Eio.Stream.t option Atomic.t =
  Atomic.make None

let set_presence (status : Discord_gateway_state.presence_status) =
  match Atomic.get input_mailbox_cell with
  | None ->
    Log.Discord.debug
      "set_presence ignored: gateway not running (status=%s)"
      (Discord_gateway_state.presence_status_to_string status)
  | Some mb ->
    Eio.Stream.add mb (Discord_gateway_state.Status_change status)

let run ~sw ~env ~token ~intents ~trigger_policy ~on_event ~on_ambient () =
  let config : Discord_gateway_state.config = {
    token; intents; bot_user_id = None; trigger_policy;
  } in
  let state = ref (Discord_gateway_state.create ~config) in
  let conn_ref : Discord_wss_connection.conn option ref = ref None in
  let input_mailbox = Eio.Stream.create 64 in
  let published_mailbox = Some input_mailbox in
  Atomic.set input_mailbox_cell published_mailbox;
  Eio.Switch.on_release sw (fun () ->
    (* Best-effort: a newer run may have already replaced the published mailbox. *)
    let (_ : bool) =
      Atomic.compare_and_set input_mailbox_cell published_mailbox None
    in
    ());
  let heartbeat_ms = ref None in
  (* Heartbeat ACK tracking. The heartbeat fiber clears on tick; the
     reader sets on Op_heartbeat_ack.  Starts [true] so the first tick
     after HELLO does not false-trigger a timeout.  Reset to [true] in
     Schedule_heartbeat (new session after reconnect) so a fresh
     heartbeat cycle starts with a clean slate. *)
  let heartbeat_ack_ok = Atomic.make true in

  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (match !heartbeat_ms with
       | None ->
         Eio.Time.sleep clock 0.5
       | Some ms ->
         Eio.Time.sleep clock (float_of_int ms /. 1000.0);
         if Atomic.get heartbeat_ack_ok then begin
           (* Previous heartbeat was ACK'd (or first tick after HELLO) —
              send the next heartbeat and start waiting for its ACK. *)
           Atomic.set heartbeat_ack_ok false;
           Eio.Stream.add input_mailbox Discord_gateway_state.Heartbeat_tick
        end else
          (* Discord docs: "If a client does not receive a heartbeat
             ack between its attempts at sending heartbeats, it should
             immediately terminate the connection with a non-1000
             close code and reconnect." *)
          begin
            Discord_observability.record_gateway_ack_timeout ();
            Eio.Stream.add input_mailbox
              Discord_gateway_state.Heartbeat_ack_timeout
          end);
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
         | Some inp ->
           (* Side-channel: track heartbeat ACK arrival for I/O-layer
              liveness detection.  The [when] guard avoids a fragile
              catch-all on the [input] type — the state machine still
              receives every input unchanged. *)
           (match inp with
            | Discord_gateway_state.Frame_received f
              when f.op = Discord_gateway_state.Op_heartbeat_ack ->
              Atomic.set heartbeat_ack_ok true
            | Discord_gateway_state.Frame_received _
            | Discord_gateway_state.Connect_requested
            | Discord_gateway_state.Frame_parse_error _
            | Discord_gateway_state.Wss_closed _
            | Discord_gateway_state.Heartbeat_tick
            | Discord_gateway_state.Heartbeat_ack_timeout
            | Discord_gateway_state.Backoff_elapsed
            | Discord_gateway_state.Status_change _ -> ());
           Eio.Stream.add input_mailbox inp
         | None -> ());
        loop ()
    in
    loop ()
  in

  let run_effect (eff : Discord_gateway_state.gateway_effect) =
    let open Discord_gateway_state in
    match eff with
    | Open_wss { url } ->
      Discord_observability.record_gateway_event
        ~route:Discord_observability.Control
        Discord_observability.Open_wss;
      (match !conn_ref with
       | Some old_conn ->
         (* Defensive cleanup: the state machine may not have emitted
            Close_wss before this Open_wss (e.g. Wss_closed from a server
            Close frame that didn't go through our explicit Close_wss path).
            Discord_wss_connection.close is idempotent (peek-resolve
            pattern), so calling it on an already-closed connection is
            safe. Without this, the stale conn_ref blocks reconnection
            permanently — the FSM transitions to Awaiting_hello but no
            socket is opened, and no timeout escapes that state. *)
         log_effect `Warn
           "Open_wss while conn_ref still Some; force-closing stale connection";
         Discord_wss_connection.close old_conn;
         conn_ref := None
       | None -> ());
      let conn = Discord_wss_connection.connect ~sw ~env ~url in
      conn_ref := Some conn;
      Eio.Fiber.fork ~sw (fun () -> reader_loop conn)
    | Close_wss { code; reason = _ } ->
      (* Phase 1.4b: explicit close. Discord_wss_connection.close
         resolves the inner session switch's close-signal promise,
         which lets that switch return, which cancels reader/writer
         fibers and releases the socket + TLS flow. The reader's
         pending read raises Cancelled; our reader_loop exception
         arm pushes a redundant Wss_closed input that the state
         machine no-ops because it is already in Reconnect_pending. *)
      Discord_observability.record_gateway_close ~code;
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
      heartbeat_ms := Some interval_ms;
      (* New HELLO received (fresh connect or reconnect) — reset the
         ACK flag so the first tick in the new session sends a heartbeat
         rather than immediately triggering a timeout. *)
      Atomic.set heartbeat_ack_ok true
    | Schedule_backoff { delay_ms } ->
      Discord_observability.record_gateway_reconnect_scheduled ();
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Time.sleep clock (float_of_int delay_ms /. 1000.0);
        Eio.Stream.add input_mailbox Discord_gateway_state.Backoff_elapsed)
    | Emit_event ev ->
      let event, route =
        match ev with
        | Ready _ -> Discord_observability.Ready, Discord_observability.Control
        | Message_create _ ->
          Discord_observability.Message_create, Discord_observability.Triggered
        | Reaction_add _ ->
          Discord_observability.Reaction_add, Discord_observability.Triggered
        | Thread_tracked _ | Threads_bulk_tracked _ | Thread_removed _ ->
          Discord_observability.Ignored, Discord_observability.Control
        | Ignored _ -> Discord_observability.Ignored, Discord_observability.Control
      in
      Discord_observability.record_gateway_event ~route event;
      on_event ev
    | Emit_ambient ev ->
      let event =
        match ev with
        | Ready _ -> Discord_observability.Ready
        | Message_create _ -> Discord_observability.Message_create
        | Reaction_add _ -> Discord_observability.Reaction_add
        | Thread_tracked _ | Threads_bulk_tracked _ | Thread_removed _ -> Discord_observability.Ignored
        | Ignored _ -> Discord_observability.Ignored
      in
      Discord_observability.record_gateway_event
        ~route:Discord_observability.Ambient event;
      on_ambient ev
    | Log { level; message } -> log_effect level message
  in

  let step_now input =
    let now = now_mono env in
    let (s', effects) = Discord_gateway_state.step !state ~now_mono:now input in
    state := s';
    Atomic.set published_connection_state (Discord_gateway_state.state s');
    List.iter run_effect effects
  in

  step_now Discord_gateway_state.Connect_requested;

  let rec drive () =
    let input = Eio.Stream.take input_mailbox in
    step_now input;
    drive ()
  in
  drive ()
