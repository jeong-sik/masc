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
    ]
