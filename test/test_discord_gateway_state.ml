(* RFC-0203 Phase 1.6 — fixture-frame unit tests for the pure
   state machine.

   No live WSS, no Eio. Drives Discord_gateway_state.step with
   typed inputs constructed in-process. *)

open Alcotest
module S = Discord_gateway_state

(* ---------------------------------------------------------------- *)
(* Primitives                                                       *)
(* ---------------------------------------------------------------- *)

let test_opcode_round_trip () =
  let all =
    [ 0, S.Op_dispatch
    ; 1, S.Op_heartbeat
    ; 2, S.Op_identify
    ; 6, S.Op_resume
    ; 7, S.Op_reconnect
    ; 9, S.Op_invalid_session
    ; 10, S.Op_hello
    ; 11, S.Op_heartbeat_ack
    ]
  in
  List.iter
    (fun (i, op) ->
      check int (Printf.sprintf "to_int %d" i) i (S.opcode_to_int op);
      match S.opcode_of_int i with
      | Ok op' when op' = op -> ()
      | Ok _ -> failf "of_int %d round-trip mismatch" i
      | Error msg -> failf "of_int %d unexpected error: %s" i msg)
    all;
  match S.opcode_of_int 99 with
  | Ok _ -> fail "expected error for unknown opcode 99"
  | Error _ -> ()

let test_intents_bitmask () =
  (* Discord intent bits (Gateway v10):
     GUILDS=1<<0, GUILD_MESSAGES=1<<9, GUILD_MESSAGE_REACTIONS=1<<10,
     DIRECT_MESSAGES=1<<12, DIRECT_MESSAGE_REACTIONS=1<<13,
     MESSAGE_CONTENT=1<<15 *)
  check int "Guilds alone" 1 (S.intents_bitmask [ S.Guilds ]);
  check int "Guild_messages alone" 512 (S.intents_bitmask [ S.Guild_messages ]);
  check int "Message_content alone" 32768
    (S.intents_bitmask [ S.Message_content ]);
  check int "all six (RFC-0203 default set)"
    (1 + 512 + 1024 + 4096 + 8192 + 32768)
    (S.intents_bitmask
       [ S.Guilds
       ; S.Guild_messages
       ; S.Guild_message_reactions
       ; S.Direct_messages
       ; S.Direct_message_reactions
       ; S.Message_content
       ]);
  check int "empty list" 0 (S.intents_bitmask [])

let policy_equal a b =
  match a, b with
  | S.Mention_only, S.Mention_only -> true
  | S.All, S.All -> true
  | S.User_only x, S.User_only y -> String.equal x y
  | _ -> false

let test_parse_trigger_policy_accepts () =
  let cases =
    [ "mention_only", S.Mention_only
    ; "all", S.All
    ; "user_only:1234567890", S.User_only "1234567890"
    ]
  in
  List.iter
    (fun (input, expected) ->
      match S.parse_trigger_policy input with
      | Ok p when policy_equal p expected -> ()
      | Ok _ -> failf "parse_trigger_policy %S: wrong variant" input
      | Error msg -> failf "parse_trigger_policy %S: %s" input msg)
    cases

let test_parse_trigger_policy_rejects () =
  let bad = [ "mention"; "user_only:"; "USER_ONLY:123"; "everything"; ""; "all "  ] in
  List.iter
    (fun input ->
      match S.parse_trigger_policy input with
      | Ok _ -> failf "expected Error for %S" input
      | Error _ -> ())
    bad

(* ---------------------------------------------------------------- *)
(* parse_frame                                                      *)
(* ---------------------------------------------------------------- *)

let test_parse_frame_hello () =
  let json =
    `Assoc
      [ "op", `Int 10
      ; "d", `Assoc [ "heartbeat_interval", `Int 41250 ]
      ]
  in
  match S.parse_frame json with
  | Ok { op = S.Op_hello; s = None; t = None; _ } -> ()
  | Ok _ -> fail "parsed wrong opcode/seq/t for Hello"
  | Error msg -> fail msg

let test_parse_frame_dispatch_ready () =
  let json =
    `Assoc
      [ "op", `Int 0
      ; "s", `Int 1
      ; "t", `String "READY"
      ; "d", `Assoc [ "v", `Int 10 ]
      ]
  in
  match S.parse_frame json with
  | Ok { op = S.Op_dispatch; s = Some 1; t = Some "READY"; _ } -> ()
  | Ok _ -> fail "parsed wrong fields for dispatch READY envelope"
  | Error msg -> fail msg

let test_parse_frame_rejects_unknown_op () =
  let json = `Assoc [ "op", `Int 99; "d", `Null ] in
  match S.parse_frame json with
  | Ok _ -> fail "expected error for op=99"
  | Error _ -> ()

let test_parse_frame_rejects_missing_op () =
  let json = `Assoc [ "d", `Null ] in
  match S.parse_frame json with
  | Ok _ -> fail "expected error for missing op"
  | Error _ -> ()

(* ---------------------------------------------------------------- *)
(* decode_dispatch                                                  *)
(* ---------------------------------------------------------------- *)

let test_decode_dispatch_ready () =
  let payload =
    `Assoc
      [ "v", `Int 10
      ; "user", `Assoc [ "id", `String "1111" ]
      ; "session_id", `String "sess-abc"
      ; "resume_gateway_url",
        `String "wss://gateway-us-east1-d.discord.gg/"
      ]
  in
  match
    S.decode_dispatch ~bot_user_id:None ~event_name:"READY" ~payload
  with
  | Ok
      (S.Ready
        { session_id = "sess-abc"
        ; resume_gateway_url = "wss://gateway-us-east1-d.discord.gg/"
        ; bot_user_id = "1111"
        }) ->
    ()
  | Ok _ -> fail "decoded wrong fields for READY"
  | Error msg -> fail msg

let test_decode_dispatch_ignored_for_unknown_event () =
  let payload = `Assoc [] in
  match
    S.decode_dispatch ~bot_user_id:None ~event_name:"WAVE_HAND" ~payload
  with
  | Ok (S.Ignored "WAVE_HAND") -> ()
  | Ok _ -> fail "expected Ignored \"WAVE_HAND\""
  | Error msg -> fail msg

(* ---------------------------------------------------------------- *)
(* step transitions                                                 *)
(* ---------------------------------------------------------------- *)

let mk_config () : S.config =
  { token = "test-token"
  ; intents = [ S.Guilds; S.Guild_messages ]
  ; bot_user_id = None
  ; trigger_policy = S.Mention_only
  }

let has_open_wss effects =
  List.exists (function S.Open_wss _ -> true | _ -> false) effects

let has_send_identify effects =
  List.exists
    (function
      | S.Send_frame { op = S.Op_identify; _ } -> true
      | _ -> false)
    effects

let has_schedule_heartbeat ~interval_ms effects =
  List.exists
    (function
      | S.Schedule_heartbeat { interval_ms = ms } -> ms = interval_ms
      | _ -> false)
    effects

let has_send_heartbeat effects =
  List.exists
    (function
      | S.Send_frame { op = S.Op_heartbeat; _ } -> true
      | _ -> false)
    effects

let has_emit_ready ~session_id effects =
  List.exists
    (function
      | S.Emit_event (S.Ready { session_id = sid; _ }) ->
        String.equal sid session_id
      | _ -> false)
    effects

let test_step_connect_requested () =
  let m = S.create ~config:(mk_config ()) in
  let m', effects = S.step m ~now_mono:0.0 S.Connect_requested in
  (match S.state m' with
   | S.Awaiting_hello -> ()
   | _ -> fail "expected Awaiting_hello after Connect_requested");
  check bool "Open_wss effect emitted" true (has_open_wss effects)

let hello_frame ~heartbeat_interval : S.frame =
  { op = S.Op_hello
  ; s = None
  ; t = None
  ; d = `Assoc [ "heartbeat_interval", `Int heartbeat_interval ]
  }

let ready_frame ~session_id ~resume_url ~user_id : S.frame =
  { op = S.Op_dispatch
  ; s = Some 1
  ; t = Some "READY"
  ; d =
      `Assoc
        [ "v", `Int 10
        ; "user", `Assoc [ "id", `String user_id ]
        ; "session_id", `String session_id
        ; "resume_gateway_url", `String resume_url
        ]
  }

let test_hello_transition () =
  let m = S.create ~config:(mk_config ()) in
  let m, _ = S.step m ~now_mono:0.0 S.Connect_requested in
  let m', effects =
    S.step m ~now_mono:1.0
      (S.Frame_received (hello_frame ~heartbeat_interval:41250))
  in
  (match S.state m' with
   | S.Identifying -> ()
   | _ -> fail "expected Identifying after Hello");
  check bool "Send_frame Op_identify emitted" true (has_send_identify effects);
  check bool "Schedule_heartbeat 41250ms emitted" true
    (has_schedule_heartbeat ~interval_ms:41250 effects)

let test_ready_transition () =
  let m = S.create ~config:(mk_config ()) in
  let m, _ = S.step m ~now_mono:0.0 S.Connect_requested in
  let m, _ =
    S.step m ~now_mono:1.0
      (S.Frame_received (hello_frame ~heartbeat_interval:41250))
  in
  let m', effects =
    S.step m ~now_mono:2.0
      (S.Frame_received
         (ready_frame
            ~session_id:"sess-abc"
            ~resume_url:"wss://gateway-us-east1.discord.gg/"
            ~user_id:"1111"))
  in
  (match S.state m' with
   | S.Connected { session_id = "sess-abc"; _ } -> ()
   | _ -> fail "expected Connected with session_id=sess-abc");
  check bool "Emit_event Ready sess-abc" true
    (has_emit_ready ~session_id:"sess-abc" effects)

let test_heartbeat_tick_when_connected () =
  let m = S.create ~config:(mk_config ()) in
  let m, _ = S.step m ~now_mono:0.0 S.Connect_requested in
  let m, _ =
    S.step m ~now_mono:1.0
      (S.Frame_received (hello_frame ~heartbeat_interval:41250))
  in
  let m, _ =
    S.step m ~now_mono:2.0
      (S.Frame_received
         (ready_frame
            ~session_id:"sess-1"
            ~resume_url:"wss://gateway.discord.gg/"
            ~user_id:"42"))
  in
  let _, effects = S.step m ~now_mono:43.0 S.Heartbeat_tick in
  check bool "heartbeat tick emits Send_frame Op_heartbeat" true
    (has_send_heartbeat effects)

(* ---------------------------------------------------------------- *)
(* Phase 1.4 — reconnect / resume arms                              *)
(* ---------------------------------------------------------------- *)

let has_schedule_backoff effects =
  List.exists (function S.Schedule_backoff _ -> true | _ -> false) effects

let has_close_wss effects =
  List.exists (function S.Close_wss _ -> true | _ -> false) effects

let has_open_wss_url ~url effects =
  List.exists
    (function S.Open_wss { url = u } -> String.equal u url | _ -> false)
    effects

let has_send_resume effects =
  List.exists
    (function
      | S.Send_frame { op = S.Op_resume; _ } -> true
      | _ -> false)
    effects

(* Build a state already at Connected (sess-x), to skip ceremony in
   each test below. *)
let connected_at ~session_id ~resume_url ~user_id =
  let m = S.create ~config:(mk_config ()) in
  let m, _ = S.step m ~now_mono:0.0 S.Connect_requested in
  let m, _ =
    S.step m ~now_mono:1.0
      (S.Frame_received (hello_frame ~heartbeat_interval:41250))
  in
  let m, _ =
    S.step m ~now_mono:2.0
      (S.Frame_received
         (ready_frame ~session_id ~resume_url ~user_id))
  in
  m

let test_wss_closed_from_connected_is_resumable () =
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume.discord.gg/"
      ~user_id:"42"
  in
  let m', effects =
    S.step m ~now_mono:10.0
      (S.Wss_closed { code = 1006; reason = "network blip" })
  in
  (match S.state m' with
   | S.Reconnect_pending { resumable = true; _ } -> ()
   | _ -> fail "expected Reconnect_pending resumable=true");
  check bool "Schedule_backoff emitted" true
    (has_schedule_backoff effects)

let test_wss_closed_fatal_goes_to_failed () =
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume.discord.gg/"
      ~user_id:"42"
  in
  let m', effects =
    S.step m ~now_mono:10.0
      (S.Wss_closed { code = 4014; reason = "disallowed intents" })
  in
  (match S.state m' with
   | S.Failed _ -> ()
   | _ -> fail "expected Failed for fatal close code 4014");
  check bool "no Schedule_backoff on fatal close" false
    (has_schedule_backoff effects)

let test_heartbeat_ack_timeout () =
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume.discord.gg/"
      ~user_id:"42"
  in
  let m', effects =
    S.step m ~now_mono:10.0 S.Heartbeat_ack_timeout
  in
  (match S.state m' with
   | S.Reconnect_pending { resumable = true; _ } -> ()
   | _ -> fail "expected Reconnect_pending resumable=true");
  check bool "Close_wss emitted" true (has_close_wss effects);
  check bool "Schedule_backoff emitted" true
    (has_schedule_backoff effects)

let test_op_reconnect_from_server () =
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume.discord.gg/"
      ~user_id:"42"
  in
  let reconnect_frame : S.frame =
    { op = S.Op_reconnect; s = None; t = None; d = `Null }
  in
  let m', effects =
    S.step m ~now_mono:10.0 (S.Frame_received reconnect_frame)
  in
  (match S.state m' with
   | S.Reconnect_pending { resumable = true; _ } -> ()
   | _ -> fail "expected Reconnect_pending after server Op_reconnect");
  check bool "Close_wss + Schedule_backoff" true
    (has_close_wss effects && has_schedule_backoff effects)

let test_op_invalid_session_resumable_true () =
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume.discord.gg/"
      ~user_id:"42"
  in
  let invalid : S.frame =
    { op = S.Op_invalid_session; s = None; t = None; d = `Bool true }
  in
  let m', effects =
    S.step m ~now_mono:10.0 (S.Frame_received invalid)
  in
  (match S.state m' with
   | S.Reconnect_pending { resumable = true; _ } -> ()
   | _ -> fail "expected Reconnect_pending resumable=true");
  check bool "Schedule_backoff emitted" true
    (has_schedule_backoff effects)

let test_op_invalid_session_resumable_false () =
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume.discord.gg/"
      ~user_id:"42"
  in
  let invalid : S.frame =
    { op = S.Op_invalid_session; s = None; t = None; d = `Bool false }
  in
  let m', _effects =
    S.step m ~now_mono:10.0 (S.Frame_received invalid)
  in
  (match S.state m' with
   | S.Reconnect_pending { resumable = false; _ } -> ()
   | _ -> fail "expected Reconnect_pending resumable=false")

let test_backoff_elapsed_resumable_uses_resume_url () =
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume-host.discord.gg/"
      ~user_id:"42"
  in
  let m, _ =
    S.step m ~now_mono:10.0
      (S.Wss_closed { code = 1006; reason = "blip" })
  in
  let m', effects = S.step m ~now_mono:12.0 S.Backoff_elapsed in
  (match S.state m' with
   | S.Awaiting_hello -> ()
   | _ -> fail "expected Awaiting_hello after Backoff_elapsed (resumable)");
  check bool "Open_wss uses resume URL" true
    (has_open_wss_url ~url:"wss://resume-host.discord.gg/" effects)

let test_backoff_elapsed_non_resumable_uses_fresh_url () =
  (* Drive into Reconnect_pending(resumable=false) via
     Op_invalid_session with `d = `Bool false`. *)
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume-host.discord.gg/"
      ~user_id:"42"
  in
  let invalid : S.frame =
    { op = S.Op_invalid_session; s = None; t = None; d = `Bool false }
  in
  let m, _ = S.step m ~now_mono:10.0 (S.Frame_received invalid) in
  let m', effects = S.step m ~now_mono:12.0 S.Backoff_elapsed in
  (match S.state m' with
   | S.Awaiting_hello -> ()
   | _ -> fail "expected Awaiting_hello after Backoff_elapsed (fresh)");
  check bool "Open_wss uses default gateway URL (not resume URL)" true
    (has_open_wss_url
       ~url:"wss://gateway.discord.gg/?v=10&encoding=json"
       effects)

let test_resume_round_trip_to_connected () =
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume-host.discord.gg/"
      ~user_id:"42"
  in
  let m, _ =
    S.step m ~now_mono:10.0
      (S.Wss_closed { code = 1006; reason = "blip" })
  in
  let m, _ = S.step m ~now_mono:12.0 S.Backoff_elapsed in
  let m, effects =
    S.step m ~now_mono:13.0
      (S.Frame_received (hello_frame ~heartbeat_interval:41250))
  in
  (match S.state m with
   | S.Resuming -> ()
   | _ -> fail "expected Resuming after Hello on resume path");
  check bool "Send_frame Op_resume emitted (not Identify)" true
    (has_send_resume effects);
  let resumed : S.frame =
    { op = S.Op_dispatch
    ; s = Some 99
    ; t = Some "RESUMED"
    ; d = `Assoc []
    }
  in
  let m', _ = S.step m ~now_mono:14.0 (S.Frame_received resumed) in
  match S.state m' with
  | S.Connected { session_id = "sess-1"; last_seq = Some 99 } -> ()
  | _ -> fail "expected Connected sess-1 last_seq=99 after RESUMED"

(* ---------------------------------------------------------------- *)
(* Entry                                                            *)
(* ---------------------------------------------------------------- *)

let () =
  run "discord_gateway_state"
    [ ( "primitives"
      , [ test_case "opcode round-trip" `Quick test_opcode_round_trip
        ; test_case "intents bitmask" `Quick test_intents_bitmask
        ; test_case "parse_trigger_policy accepts 3 values" `Quick
            test_parse_trigger_policy_accepts
        ; test_case "parse_trigger_policy rejects others" `Quick
            test_parse_trigger_policy_rejects
        ] )
    ; ( "parse_frame"
      , [ test_case "Hello envelope" `Quick test_parse_frame_hello
        ; test_case "dispatch READY envelope" `Quick
            test_parse_frame_dispatch_ready
        ; test_case "rejects unknown op" `Quick
            test_parse_frame_rejects_unknown_op
        ; test_case "rejects missing op" `Quick
            test_parse_frame_rejects_missing_op
        ] )
    ; ( "decode_dispatch"
      , [ test_case "READY payload" `Quick test_decode_dispatch_ready
        ; test_case "unknown event => Ignored" `Quick
            test_decode_dispatch_ignored_for_unknown_event
        ] )
    ; ( "step transitions"
      , [ test_case "Connect_requested → Awaiting_hello + Open_wss" `Quick
            test_step_connect_requested
        ; test_case "Hello → Identifying + Identify + Schedule_heartbeat"
            `Quick test_hello_transition
        ; test_case "READY → Connected + Emit_event Ready" `Quick
            test_ready_transition
        ; test_case "Heartbeat_tick (Connected) → Send_frame Op_heartbeat"
            `Quick test_heartbeat_tick_when_connected
        ] )
    ; ( "reconnect / resume"
      , [ test_case
            "Wss_closed (Connected, non-fatal) → Reconnect_pending(resumable)"
            `Quick test_wss_closed_from_connected_is_resumable
        ; test_case "Wss_closed (code=4014 disallowed intents) → Failed"
            `Quick test_wss_closed_fatal_goes_to_failed
        ; test_case
            "Heartbeat_ack_timeout (Connected) → Close_wss + Schedule_backoff"
            `Quick test_heartbeat_ack_timeout
        ; test_case
            "Op_reconnect from server → Close_wss + Schedule_backoff"
            `Quick test_op_reconnect_from_server
        ; test_case
            "Op_invalid_session resumable=true → Reconnect_pending(resumable)"
            `Quick test_op_invalid_session_resumable_true
        ; test_case
            "Op_invalid_session resumable=false → Reconnect_pending(fresh)"
            `Quick test_op_invalid_session_resumable_false
        ; test_case
            "Backoff_elapsed (resumable) opens WSS via resume_gateway_url"
            `Quick test_backoff_elapsed_resumable_uses_resume_url
        ; test_case
            "Backoff_elapsed (non-resumable) opens default gateway URL"
            `Quick test_backoff_elapsed_non_resumable_uses_fresh_url
        ; test_case
            "Resume round trip: Connected → blip → Backoff → Hello → \
             Op_resume → RESUMED → Connected"
            `Quick test_resume_round_trip_to_connected
        ] )
    ]
