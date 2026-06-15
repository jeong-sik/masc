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
    ; 3, S.Op_status_update
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
  | S.Mention_or_thread, S.Mention_or_thread -> true
  | S.All, S.All -> true
  | S.User_only x, S.User_only y -> String.equal x y
  | _ -> false

let test_parse_trigger_policy_accepts () =
  let cases =
    [ "mention_only", S.Mention_only
    ; "mention_or_thread", S.Mention_or_thread
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

let test_presence_status_strings () =
  let cases =
    [ S.Online, "online"
    ; S.Idle, "idle"
    ; S.Dnd, "dnd"
    ; S.Invisible, "invisible"
    ]
  in
  List.iter
    (fun (status, expected) ->
      check string expected expected (S.presence_status_to_string status))
    cases

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

let status_update_frame effects =
  List.find_map
    (function
      | S.Send_frame ({ op = S.Op_status_update; _ } as frame) -> Some frame
      | _ -> None)
    effects

let has_status_update effects =
  Option.is_some (status_update_frame effects)

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

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
(* Phase 1.5 — MESSAGE_CREATE / MESSAGE_REACTION_ADD + policy       *)
(* ---------------------------------------------------------------- *)

let message_create_payload
    ~id ~channel_id ~author_id ?guild_id ?username ?global_name
    ?message_reference_channel_id ?message_reference_message_id
    ?referenced_message_author_id ?author_bot ?webhook_id
    ~content ~mention_ids ()
    : Yojson.Safe.t =
  let mentions =
    `List
      (List.map
         (fun uid -> `Assoc [ ("id", `String uid) ])
         mention_ids)
  in
  let author_fields =
    ("id", `String author_id)
    :: (match username with
        | Some u -> [ ("username", `String u) ]
        | None -> [])
    @ (match global_name with
       | Some g -> [ ("global_name", `String g) ]
       | None -> [])
    @ (match author_bot with
       | Some b -> [ ("bot", `Bool b) ]
       | None -> [])
  in
  let base_fields =
    [ ("id", `String id)
    ; ("channel_id", `String channel_id)
    ; ("author", `Assoc author_fields)
    ; ("content", `String content)
    ; ("mentions", mentions)
    ]
    @ (match webhook_id with
       | Some w -> [ ("webhook_id", `String w) ]
       | None -> [])
  in
  let with_guild =
    match guild_id with
    | None -> base_fields
    | Some gid -> ("guild_id", `String gid) :: base_fields
  in
  let with_reference =
    match message_reference_channel_id, message_reference_message_id with
    | None, None -> with_guild
    | channel_id, message_id ->
        let fields =
          (match channel_id with
           | Some cid -> [ ("channel_id", `String cid) ]
           | None -> [])
          @
          match message_id with
          | Some mid -> [ ("message_id", `String mid) ]
          | None -> []
        in
        ("message_reference", `Assoc fields) :: with_guild
  in
  let with_referenced =
    match referenced_message_author_id with
    | None -> with_reference
    | Some author_id ->
        ( "referenced_message",
          `Assoc [ ("author", `Assoc [ ("id", `String author_id) ]) ] )
        :: with_reference
  in
  `Assoc with_referenced

let reaction_add_payload
    ~channel_id ~message_id ~user_id ~emoji_name ?emoji_id () : Yojson.Safe.t =
  let emoji_fields =
    ("name", `String emoji_name)
    :: (match emoji_id with
        | Some i -> [ ("id", `String i) ]
        | None -> [])
  in
  `Assoc
    [ ("channel_id", `String channel_id)
    ; ("message_id", `String message_id)
    ; ("user_id", `String user_id)
    ; ("emoji", `Assoc emoji_fields)
    ]

let test_decode_message_create_with_mention () =
  let payload =
    message_create_payload
      ~id:"MSG1"
      ~channel_id:"CH1"
      ~guild_id:"G1"
      ~author_id:"USER1"
      ~content:"<@BOT> hi"
      ~mention_ids:[ "BOT" ]
      ~message_reference_channel_id:"CH0"
      ~message_reference_message_id:"MSG0"
      ~referenced_message_author_id:"OTHER"
      ()
  in
  match
    S.decode_dispatch
      ~bot_user_id:(Some "BOT")
      ~event_name:"MESSAGE_CREATE"
      ~payload
  with
  | Ok
      (S.Message_create
        { channel_id = "CH1"
        ; message_id = "MSG1"
        ; guild_id = Some "G1"
        ; author_id = "USER1"
        ; author_name = None
        ; content = "<@BOT> hi"
        ; mentions_bot = true
        ; explicit_mentions_bot = true
        ; message_reference_channel_id = Some "CH0"
        ; message_reference_message_id = Some "MSG0"
        ; referenced_message_author_id = Some "OTHER"
        }) ->
      ()
  | Ok _ -> fail "decoded wrong MESSAGE_CREATE fields"
  | Error msg -> fail msg

(* RFC-0223 P1 — author display name extraction. *)

let decode_author_name ~payload =
  match
    S.decode_dispatch
      ~bot_user_id:(Some "BOT")
      ~event_name:"MESSAGE_CREATE"
      ~payload
  with
  | Ok (S.Message_create { author_name; _ }) -> author_name
  | Ok _ -> fail "expected MESSAGE_CREATE"
  | Error msg -> fail msg

let test_decode_author_name_prefers_global_name () =
  let payload =
    message_create_payload
      ~id:"MSG10" ~channel_id:"CH1" ~author_id:"USER1"
      ~username:"minsu_handle" ~global_name:"Minsu"
      ~content:"hi" ~mention_ids:[] ()
  in
  Alcotest.(check (option string)) "global_name wins"
    (Some "Minsu") (decode_author_name ~payload)

let test_decode_author_name_falls_back_to_username () =
  let payload =
    message_create_payload
      ~id:"MSG11" ~channel_id:"CH1" ~author_id:"USER1"
      ~username:"minsu_handle"
      ~content:"hi" ~mention_ids:[] ()
  in
  Alcotest.(check (option string)) "username fallback"
    (Some "minsu_handle") (decode_author_name ~payload)

let test_decode_author_name_absent_when_payload_has_neither () =
  let payload =
    message_create_payload
      ~id:"MSG12" ~channel_id:"CH1" ~author_id:"USER1"
      ~content:"hi" ~mention_ids:[] ()
  in
  Alcotest.(check (option string)) "no name fields -> None"
    None (decode_author_name ~payload)

let test_decode_message_create_without_mention () =
  let payload =
    message_create_payload
      ~id:"MSG2"
      ~channel_id:"CH1"
      ~author_id:"USER1"
      ~content:"no mention here"
      ~mention_ids:[]
      ()
  in
  match
    S.decode_dispatch
      ~bot_user_id:(Some "BOT")
      ~event_name:"MESSAGE_CREATE"
      ~payload
  with
  | Ok (S.Message_create { mentions_bot = false; _ }) -> ()
  | Ok _ -> fail "expected mentions_bot=false"
  | Error msg -> fail msg

let test_decode_message_create_preserves_guild_id () =
  let payload =
    message_create_payload
      ~id:"MSG3"
      ~channel_id:"CH1"
      ~guild_id:"GUILD1"
      ~author_id:"USER1"
      ~content:"guild message"
      ~mention_ids:[]
      ()
  in
  match
    S.decode_dispatch
      ~bot_user_id:(Some "BOT")
      ~event_name:"MESSAGE_CREATE"
      ~payload
  with
  | Ok (S.Message_create { guild_id = Some "GUILD1"; _ }) -> ()
  | Ok (S.Message_create { guild_id = Some other; _ }) ->
      failf "expected guild_id=GUILD1, got %s" other
  | Ok (S.Message_create { guild_id = None; _ }) ->
      fail "expected guild_id to be preserved"
  | Ok _ -> fail "expected MESSAGE_CREATE"
  | Error msg -> fail msg

let test_decode_message_create_reply_ping_is_not_explicit_mention () =
  let payload =
    message_create_payload
      ~id:"MSG3"
      ~channel_id:"CH1"
      ~author_id:"USER1"
      ~content:"reply without visible mention"
      ~mention_ids:[ "BOT" ]
      ~message_reference_channel_id:"CH1"
      ~message_reference_message_id:"BOTMSG"
      ~referenced_message_author_id:"BOT"
      ()
  in
  match
    S.decode_dispatch
      ~bot_user_id:(Some "BOT")
      ~event_name:"MESSAGE_CREATE"
      ~payload
  with
  | Ok
      (S.Message_create
        { mentions_bot = true
        ; explicit_mentions_bot = false
        ; message_reference_channel_id = Some "CH1"
        ; message_reference_message_id = Some "BOTMSG"
        ; referenced_message_author_id = Some "BOT"
        ; _
        }) ->
      ()
  | Ok _ -> fail "expected reply ping metadata without explicit mention"
  | Error msg -> fail msg

let test_decode_reaction_add_unicode () =
  let payload =
    reaction_add_payload
      ~channel_id:"CH1"
      ~message_id:"MSG1"
      ~user_id:"USER1"
      ~emoji_name:"👍"
      ()
  in
  match
    S.decode_dispatch
      ~bot_user_id:None
      ~event_name:"MESSAGE_REACTION_ADD"
      ~payload
  with
  | Ok
      (S.Reaction_add
        { channel_id = "CH1"
        ; message_id = "MSG1"
        ; user_id = "USER1"
        ; emoji = "👍"
        }) ->
      ()
  | Ok _ -> fail "decoded wrong reaction fields"
  | Error msg -> fail msg

let test_decode_reaction_add_custom_emoji () =
  let payload =
    reaction_add_payload
      ~channel_id:"CH1"
      ~message_id:"MSG1"
      ~user_id:"USER1"
      ~emoji_name:"partyparrot"
      ~emoji_id:"7777"
      ()
  in
  match
    S.decode_dispatch
      ~bot_user_id:None
      ~event_name:"MESSAGE_REACTION_ADD"
      ~payload
  with
  | Ok (S.Reaction_add { emoji = "partyparrot:7777"; _ }) -> ()
  | Ok _ -> fail "expected emoji=\"partyparrot:7777\" for custom emoji"
  | Error msg -> fail msg

(* Drive into Connected with the given policy + bot user id, then
   feed a dispatch frame and inspect whether an Emit_event was
   produced. Returns true iff some Emit_event _ was in the effects. *)
let connected_with_policy ~policy ~bot_user_id =
  let config : S.config =
    { token = "test-token"
    ; intents = [ S.Guilds; S.Guild_messages ]
    ; bot_user_id = None
    ; trigger_policy = policy
    }
  in
  let m = S.create ~config in
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
            ~resume_url:"wss://resume.discord.gg/"
            ~user_id:bot_user_id))
  in
  m

let has_emit_event effects =
  List.exists (function S.Emit_event _ -> true | _ -> false) effects

let has_emit_ambient effects =
  List.exists (function S.Emit_ambient _ -> true | _ -> false) effects

let dispatch_frame ~event_name ~payload ~seq : S.frame =
  { op = S.Op_dispatch
  ; s = Some seq
  ; t = Some event_name
  ; d = payload
  }

let test_status_change_connected_emits_status_update () =
  let m =
    connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT"
  in
  let _, effects = S.step m ~now_mono:3.0 (S.Status_change S.Dnd) in
  let frame =
    match status_update_frame effects with
    | Some frame -> frame
    | None -> fail "expected Op_status_update frame"
  in
  check int "opcode 3" 3 (S.opcode_to_int frame.op);
  check (option int) "no sequence" None frame.s;
  check (option string) "no dispatch event name" None frame.t;
  check (option string) "status=dnd" (Some "dnd")
    (match json_field "status" frame.d with
     | Some (`String s) -> Some s
     | _ -> None);
  check (option bool) "afk=false for dnd" (Some false)
    (match json_field "afk" frame.d with
     | Some (`Bool b) -> Some b
     | _ -> None);
  check bool "activities is empty list" true
    (match json_field "activities" frame.d with
     | Some (`List []) -> true
     | _ -> false);
  check bool "since is null" true
    (match json_field "since" frame.d with
     | Some `Null -> true
     | _ -> false)

let test_status_change_idle_sets_afk () =
  let m =
    connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT"
  in
  let _, effects = S.step m ~now_mono:3.0 (S.Status_change S.Idle) in
  let frame =
    match status_update_frame effects with
    | Some frame -> frame
    | None -> fail "expected Op_status_update frame"
  in
  check (option string) "status=idle" (Some "idle")
    (match json_field "status" frame.d with
     | Some (`String s) -> Some s
     | _ -> None);
  check (option bool) "afk=true for idle" (Some true)
    (match json_field "afk" frame.d with
     | Some (`Bool b) -> Some b
     | _ -> None)

let test_status_change_ignored_when_not_connected () =
  let m = S.create ~config:(mk_config ()) in
  let m', effects = S.step m ~now_mono:0.0 (S.Status_change S.Online) in
  (match S.state m' with
   | S.Disconnected -> ()
   | _ -> fail "presence update should not change disconnected state");
  check bool "no status frame while disconnected" false
    (has_status_update effects)

let test_policy_mention_only_message_with_mention_passes () =
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"M1" ~channel_id:"C1" ~author_id:"U1" ~content:"hi <@BOT>"
      ~mention_ids:[ "BOT" ] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:5))
  in
  check bool "Emit_event produced for mention_only + mentioned message"
    true (has_emit_event effects)

let test_policy_mention_only_message_without_mention_filtered () =
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"M2" ~channel_id:"C1" ~author_id:"U1" ~content:"just chatting"
      ~mention_ids:[] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:5))
  in
  check bool "Emit_event suppressed for mention_only + non-mention"
    false (has_emit_event effects)

let test_policy_mention_only_reaction_filtered () =
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let payload =
    reaction_add_payload
      ~channel_id:"C1" ~message_id:"M1" ~user_id:"U1" ~emoji_name:"👍" ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_REACTION_ADD" ~payload ~seq:5))
  in
  check bool "Emit_event suppressed for mention_only + reaction"
    false (has_emit_event effects)

let test_policy_user_only_message_matching_author_passes () =
  let m =
    connected_with_policy
      ~policy:(S.User_only "VINCENT") ~bot_user_id:"BOT"
  in
  let payload =
    message_create_payload
      ~id:"M3" ~channel_id:"C1" ~author_id:"VINCENT" ~content:"hello"
      ~mention_ids:[] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:5))
  in
  check bool "Emit_event produced when author matches user_only id"
    true (has_emit_event effects)

let test_policy_user_only_message_other_author_filtered () =
  let m =
    connected_with_policy
      ~policy:(S.User_only "VINCENT") ~bot_user_id:"BOT"
  in
  let payload =
    message_create_payload
      ~id:"M4" ~channel_id:"C1" ~author_id:"STRANGER" ~content:"hello"
      ~mention_ids:[ "BOT" ] (* mention shouldn't help user_only path *)
      ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:5))
  in
  check bool
    "Emit_event suppressed when author doesn't match user_only \
     (mention bypass not applied)"
    false (has_emit_event effects)

let test_policy_user_only_reaction_matching_reactor_passes () =
  let m =
    connected_with_policy
      ~policy:(S.User_only "VINCENT") ~bot_user_id:"BOT"
  in
  let payload =
    reaction_add_payload
      ~channel_id:"C1" ~message_id:"M1" ~user_id:"VINCENT" ~emoji_name:"💯"
      ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_REACTION_ADD" ~payload ~seq:5))
  in
  check bool "Emit_event produced when reactor matches user_only id"
    true (has_emit_event effects)

let test_policy_all_emits_messages_and_reactions () =
  let m = connected_with_policy ~policy:S.All ~bot_user_id:"BOT" in
  let msg =
    message_create_payload
      ~id:"M5" ~channel_id:"C1" ~author_id:"ANYONE" ~content:"."
      ~mention_ids:[] ()
  in
  let _, msg_effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload:msg ~seq:5))
  in
  check bool "Emit_event for any message under All" true
    (has_emit_event msg_effects);
  let react =
    reaction_add_payload
      ~channel_id:"C1" ~message_id:"M5" ~user_id:"ANYONE" ~emoji_name:"🎉"
      ()
  in
  let _, react_effects =
    S.step m ~now_mono:4.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_REACTION_ADD" ~payload:react
            ~seq:6))
  in
  check bool "Emit_event for any reaction under All" true
    (has_emit_event react_effects)

(* ---------------------------------------------------------------- *)
(* RFC-0226 — ambient lane recording. A message that fails the      *)
(* trigger policy (and is not the bot's own echo) is delivered as   *)
(* Emit_ambient: record-only, never a turn. Policy decides exactly  *)
(* one thing — whether a turn starts.                               *)
(* ---------------------------------------------------------------- *)

let step_message m ~author_id ?(content = "ambient text") ?(mention_ids = []) () =
  let payload =
    message_create_payload
      ~id:"AMB" ~channel_id:"C1" ~author_id ~content
      ~mention_ids ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:9))
  in
  effects

let test_ambient_mention_only_plain_message () =
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let effects = step_message m ~author_id:"U1" () in
  check bool "no turn for non-mention" false (has_emit_event effects);
  check bool "ambient delivery for non-mention" true
    (has_emit_ambient effects)

let test_ambient_mention_only_reply_ping_is_ambient () =
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"REPLY1"
      ~channel_id:"C1"
      ~author_id:"U1"
      ~content:"reply without visible mention"
      ~mention_ids:[ "BOT" ]
      ~message_reference_channel_id:"C1"
      ~message_reference_message_id:"BOTMSG"
      ~referenced_message_author_id:"BOT"
      ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:9))
  in
  check bool "reply-ping does not start a turn" false
    (has_emit_event effects);
  check bool "reply-ping is still recorded as ambient" true
    (has_emit_ambient effects)

let test_ambient_absent_when_policy_passes () =
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let effects =
    step_message m ~author_id:"U1" ~content:"<@BOT> ambient text"
      ~mention_ids:[ "BOT" ] ()
  in
  check bool "turn for mention" true (has_emit_event effects);
  check bool "no double delivery when policy passes" false
    (has_emit_ambient effects)

let test_ambient_user_only_other_author () =
  let m =
    connected_with_policy ~policy:(S.User_only "VINCENT") ~bot_user_id:"BOT"
  in
  let effects = step_message m ~author_id:"STRANGER" () in
  check bool "no turn for other author" false (has_emit_event effects);
  check bool "ambient delivery for other author" true
    (has_emit_ambient effects)

let test_ambient_never_for_self () =
  let m = connected_with_policy ~policy:S.All ~bot_user_id:"BOT" in
  let effects = step_message m ~author_id:"BOT" () in
  check bool "self echo never a turn" false (has_emit_event effects);
  check bool "self echo never ambient (outbound persisted at send)"
    false (has_emit_ambient effects)

let test_ambient_not_for_reactions () =
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let payload =
    reaction_add_payload
      ~channel_id:"C1" ~message_id:"M1" ~user_id:"U1" ~emoji_name:"👍" ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_REACTION_ADD" ~payload ~seq:9))
  in
  check bool "a reaction is a trigger signal, not conversation" false
    (has_emit_ambient effects)

(* ---------------------------------------------------------------- *)
(* RFC-0203 Phase 3 follow-up — self-skip guard. Bot-authored events *)
(* are suppressed regardless of trigger policy so a misconfigured   *)
(* User_only:<bot_id> or All policy can't loop the bot into itself. *)
(* ---------------------------------------------------------------- *)

let test_self_message_suppressed_under_all_policy () =
  let m = connected_with_policy ~policy:S.All ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"SELF1" ~channel_id:"C1" ~author_id:"BOT" ~content:"echo"
      ~mention_ids:[] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:7))
  in
  check bool
    "bot's own message suppressed even under All policy"
    false (has_emit_event effects)

let test_self_message_suppressed_when_user_only_targets_bot_id () =
  (* Operator footgun: pasted bot's own id as the user_only target.
     Without the self-skip guard this would loop. *)
  let m =
    connected_with_policy
      ~policy:(S.User_only "BOT") ~bot_user_id:"BOT"
  in
  let payload =
    message_create_payload
      ~id:"SELF2" ~channel_id:"C1" ~author_id:"BOT" ~content:"loop?"
      ~mention_ids:[] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:8))
  in
  check bool
    "self-message suppressed even when User_only id collides with bot_user_id"
    false (has_emit_event effects)

let test_self_reaction_suppressed_under_all_policy () =
  let m = connected_with_policy ~policy:S.All ~bot_user_id:"BOT" in
  let payload =
    reaction_add_payload
      ~channel_id:"C1" ~message_id:"SELF1" ~user_id:"BOT" ~emoji_name:"✅"
      ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_REACTION_ADD" ~payload ~seq:9))
  in
  check bool
    "bot's own reaction suppressed even under All policy"
    false (has_emit_event effects)

let test_non_self_message_still_emitted_under_all () =
  (* Regression guard: self-skip must not break the non-self path. *)
  let m = connected_with_policy ~policy:S.All ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"OTHER1" ~channel_id:"C1" ~author_id:"VINCENT" ~content:"hi"
      ~mention_ids:[] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:10))
  in
  check bool
    "non-self message still emits under All policy"
    true (has_emit_event effects)

(* ---------------------------------------------------------------- *)
(* F940 — bot/webhook suppression. Another bot or a webhook must not *)
(* start a turn under the ambient policies (loop prevention), even   *)
(* when it @mentions the bot or posts in a tracked thread. It is     *)
(* still delivered as ambient (record-only). [User_only id] is an    *)
(* explicit per-snowflake opt-in and is honored.                     *)
(* ---------------------------------------------------------------- *)

let track_thread m ~thread_id ~parent_id ~seq =
  let frame : S.frame =
    { op = S.Op_dispatch
    ; s = Some seq
    ; t = Some "THREAD_CREATE"
    ; d =
        `Assoc
          [ ("id", `String thread_id)
          ; ("parent_id", `String parent_id)
          ; ("type", `Int 11)
          ]
    }
  in
  let m', _ = S.step m ~now_mono:2.5 (S.Frame_received frame) in
  m'

let test_decode_sets_author_is_bot_from_bot_flag () =
  let payload =
    message_create_payload
      ~id:"B1" ~channel_id:"C1" ~author_id:"OTHERBOT" ~content:"hi"
      ~mention_ids:[] ~author_bot:true ()
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"MESSAGE_CREATE" ~payload with
  | Ok (S.Message_create { author_is_bot = true; _ }) -> ()
  | Ok _ -> fail "author.bot=true should set author_is_bot=true"
  | Error msg -> fail msg

let test_decode_sets_author_is_bot_from_webhook_id () =
  let payload =
    message_create_payload
      ~id:"W1" ~channel_id:"C1" ~author_id:"HOOK" ~content:"hi"
      ~mention_ids:[] ~webhook_id:"123456" ()
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"MESSAGE_CREATE" ~payload with
  | Ok (S.Message_create { author_is_bot = true; _ }) -> ()
  | Ok _ -> fail "webhook_id present should set author_is_bot=true"
  | Error msg -> fail msg

let test_decode_human_author_is_not_bot () =
  let payload =
    message_create_payload
      ~id:"H1" ~channel_id:"C1" ~author_id:"VINCENT" ~content:"hi"
      ~mention_ids:[] ()
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"MESSAGE_CREATE" ~payload with
  | Ok (S.Message_create { author_is_bot = false; _ }) -> ()
  | Ok _ -> fail "plain author should have author_is_bot=false"
  | Error msg -> fail msg

let test_bot_mention_suppressed_under_mention_only () =
  (* The reply-loop scenario: another bot @mentions our bot. Without
     suppression explicit_mentions_bot=true would start a turn. *)
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"BL1" ~channel_id:"C1" ~author_id:"OTHERBOT"
      ~content:"<@BOT> are you there" ~mention_ids:[ "BOT" ]
      ~author_bot:true ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:11))
  in
  check bool "bot mention does not start a turn" false (has_emit_event effects);
  check bool "bot mention still recorded as ambient" true
    (has_emit_ambient effects)

let test_webhook_mention_suppressed_under_mention_only () =
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"WH1" ~channel_id:"C1" ~author_id:"HOOK"
      ~content:"<@BOT> alert" ~mention_ids:[ "BOT" ]
      ~webhook_id:"999" ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:12))
  in
  check bool "webhook mention does not start a turn" false
    (has_emit_event effects);
  check bool "webhook mention still recorded as ambient" true
    (has_emit_ambient effects)

let test_human_mention_still_passes_under_mention_only () =
  (* Regression guard: bot suppression must not block real users. *)
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"HM1" ~channel_id:"C1" ~author_id:"VINCENT"
      ~content:"<@BOT> hello" ~mention_ids:[ "BOT" ] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:13))
  in
  check bool "human mention starts a turn" true (has_emit_event effects)

let test_bot_in_thread_suppressed_under_mention_or_thread () =
  (* The audit's specific case: a bot posts in a tracked thread under
     Mention_or_thread. is_thread=true, but author_is_bot must veto. *)
  let m =
    connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT"
  in
  let m = track_thread m ~thread_id:"T1" ~parent_id:"C1" ~seq:4 in
  let payload =
    message_create_payload
      ~id:"BT1" ~channel_id:"T1" ~author_id:"OTHERBOT"
      ~content:"thread chatter" ~mention_ids:[] ~author_bot:true ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:14))
  in
  check bool "bot in thread does not start a turn" false
    (has_emit_event effects);
  check bool "bot in thread still recorded as ambient" true
    (has_emit_ambient effects)

let test_human_in_thread_still_passes_under_mention_or_thread () =
  let m =
    connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT"
  in
  let m = track_thread m ~thread_id:"T1" ~parent_id:"C1" ~seq:4 in
  let payload =
    message_create_payload
      ~id:"HT1" ~channel_id:"T1" ~author_id:"VINCENT"
      ~content:"thread question" ~mention_ids:[] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:15))
  in
  check bool "human in thread starts a turn" true (has_emit_event effects)

let test_bot_passes_when_user_only_targets_it () =
  (* Explicit per-snowflake opt-in: operator points User_only at a
     webhook/bot id on purpose. That intent is honored. *)
  let m =
    connected_with_policy ~policy:(S.User_only "OTHERBOT") ~bot_user_id:"BOT"
  in
  let payload =
    message_create_payload
      ~id:"UO1" ~channel_id:"C1" ~author_id:"OTHERBOT"
      ~content:"alert" ~mention_ids:[] ~author_bot:true ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:16))
  in
  check bool "explicit User_only opt-in honored for a bot author" true
    (has_emit_event effects)

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
(* Phase 1.4c — reconnect safety-net tests                         *)
(* ---------------------------------------------------------------- *)

let test_wss_closed_emits_close_wss () =
  (* Regression: Wss_closed from a connection state must emit Close_wss
     so the I/O layer can clear conn_ref. Without this, a stale conn_ref
     blocks the next Open_wss and the gateway stalls permanently in
     Awaiting_hello. *)
  let m =
    connected_at
      ~session_id:"sess-1"
      ~resume_url:"wss://resume.discord.gg/"
      ~user_id:"42"
  in
  let _m', effects =
    S.step m ~now_mono:10.0
      (S.Wss_closed { code = 1001; reason = "server requested reconnect" })
  in
  check bool "Close_wss emitted on Wss_closed from Connected" true
    (has_close_wss effects);
  check bool "Schedule_backoff also emitted" true
    (has_schedule_backoff effects)

let test_wss_closed_emits_close_wss_from_awaiting_hello () =
  (* Same regression check for Awaiting_hello (WSS opened but no Hello
     received before a remote close). *)
  let config =
    { S.token = "test-token"
    ; intents = [ S.Guilds; S.Message_content ]
    ; bot_user_id = None
    ; trigger_policy = S.Mention_only
    }
  in
  let m, _ = S.step (S.create ~config) ~now_mono:0.0 S.Connect_requested in
  (match S.state m with
   | S.Awaiting_hello -> ()
   | _ -> fail "expected Awaiting_hello");
  let _m', effects =
    S.step m ~now_mono:5.0
      (S.Wss_closed { code = 1000; reason = "remote close" })
  in
  check bool "Close_wss emitted on Wss_closed from Awaiting_hello" true
    (has_close_wss effects)

let test_awaiting_hello_timeout_escapes_to_reconnect () =
  (* Safety-net: Heartbeat_tick after the timeout threshold in
     Awaiting_hello should escape to Reconnect_pending instead of
     staying stuck forever. *)
  let config =
    { S.token = "test-token"
    ; intents = [ S.Guilds; S.Message_content ]
    ; bot_user_id = None
    ; trigger_policy = S.Mention_only
    }
  in
  let m, _ = S.step (S.create ~config) ~now_mono:0.0 S.Connect_requested in
  (match S.state m with
   | S.Awaiting_hello -> ()
   | _ -> fail "expected Awaiting_hello");
  (* Advance time past the 30s timeout *)
  let m', effects =
    S.step m ~now_mono:45.0 S.Heartbeat_tick
  in
  (match S.state m' with
   | S.Reconnect_pending _ -> ()
   | _ -> fail "expected Reconnect_pending after Awaiting_hello timeout");
  check bool "Schedule_backoff emitted" true
    (has_schedule_backoff effects)

let test_awaiting_hello_before_timeout_stays () =
  (* Heartbeat_tick arriving before the timeout should NOT trigger
     escape — still legitimately waiting for Hello. *)
  let config =
    { S.token = "test-token"
    ; intents = [ S.Guilds; S.Message_content ]
    ; bot_user_id = None
    ; trigger_policy = S.Mention_only
    }
  in
  let m, _ = S.step (S.create ~config) ~now_mono:0.0 S.Connect_requested in
  (* 10s < 30s timeout, should stay in Awaiting_hello *)
  let m', effects =
    S.step m ~now_mono:10.0 S.Heartbeat_tick
  in
  (match S.state m' with
   | S.Awaiting_hello -> ()
   | _ -> fail "expected Awaiting_hello (not timed out yet)");
  check bool "no Schedule_backoff before timeout" false
    (has_schedule_backoff effects)

(* ---------------------------------------------------------------- *)
(* Thread tracking + Mention_or_thread policy                      *)
(* ---------------------------------------------------------------- *)

let thread_create_frame ~thread_id ~parent_id ~seq : S.frame =
  { op = S.Op_dispatch
  ; s = Some seq
  ; t = Some "THREAD_CREATE"
  ; d =
      `Assoc
        [ ("id", `String thread_id)
        ; ("parent_id", `String parent_id)
        ; ("type", `Int 11)
        ]
  }

let guild_create_frame_with_threads ~threads ~seq : S.frame =
  let thread_items =
    List.map
      (fun (tid, pid) ->
         `Assoc [ ("id", `String tid); ("parent_id", `String pid); ("type", `Int 11) ])
      threads
  in
  { op = S.Op_dispatch
  ; s = Some seq
  ; t = Some "GUILD_CREATE"
  ; d =
      `Assoc
        [ ("id", `String "G1")
        ; ("name", `String "Test Guild")
        ; ("threads", `List thread_items)
        ]
  }

let has_emit_thread_tracked ~thread_id ~parent_channel_id effects =
  List.exists
    (function
      | S.Emit_event
          (S.Thread_tracked
            { thread_id = tid; parent_channel_id = pid }) ->
        String.equal tid thread_id && String.equal pid parent_channel_id
      | _ -> false)
    effects

let has_emit_threads_bulk_tracked effects =
  List.exists
    (function S.Emit_event (S.Threads_bulk_tracked _) -> true | _ -> false)
    effects

let test_decode_thread_create () =
  let payload =
    `Assoc [ ("id", `String "THR1"); ("parent_id", `String "PARENT1"); ("type", `Int 11) ]
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"THREAD_CREATE" ~payload with
  | Ok (S.Thread_tracked { thread_id = "THR1"; parent_channel_id = "PARENT1" }) ->
      ()
  | Ok _ -> fail "decoded wrong THREAD_CREATE fields"
  | Error msg -> fail msg

let test_decode_thread_create_missing_fields () =
  let payload = `Assoc [ ("id", `String "THR1") ] in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"THREAD_CREATE" ~payload with
  | Ok (S.Ignored _) -> ()
  | Ok _ -> fail "expected Ignored for THREAD_CREATE without parent_id"
  | Error msg -> fail msg

let test_decode_guild_create_with_threads () =
  let payload =
    `Assoc
      [ ("id", `String "G1")
      ; ("name", `String "Guild")
      ; ( "threads",
          `List
            [ `Assoc [ ("id", `String "T1"); ("parent_id", `String "C1"); ("type", `Int 11) ]
            ; `Assoc [ ("id", `String "T2"); ("parent_id", `String "C2"); ("type", `Int 12) ]
            ] )
      ]
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"GUILD_CREATE" ~payload with
  | Ok (S.Threads_bulk_tracked { threads }) ->
      check int "2 threads parsed" 2 (List.length threads);
      let has tid pid = List.exists (fun (t, p) -> t = tid && p = pid) threads in
      check bool "T1 -> C1 present" true (has "T1" "C1");
      check bool "T2 -> C2 present" true (has "T2" "C2")
  | Ok _ -> fail "expected Threads_bulk_tracked"
  | Error msg -> fail msg

let test_decode_guild_create_without_threads () =
  let payload =
    `Assoc [ ("id", `String "G1"); ("name", `String "Guild") ]
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"GUILD_CREATE" ~payload with
  | Ok (S.Ignored _) -> ()
  | Ok _ -> fail "expected Ignored for GUILD_CREATE without threads"
  | Error msg -> fail msg

let test_decode_thread_update_same_as_create () =
  let payload =
    `Assoc [ ("id", `String "THR1"); ("parent_id", `String "P1"); ("type", `Int 11) ]
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"THREAD_UPDATE" ~payload with
  | Ok (S.Thread_tracked { thread_id = "THR1"; parent_channel_id = "P1" }) -> ()
  | Ok _ -> fail "THREAD_UPDATE should decode same as THREAD_CREATE"
  | Error msg -> fail msg

(* Step-level: THREAD_CREATE populates thread_parents and emits event *)
let test_step_thread_create_updates_registry () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  let m', effects =
    S.step m ~now_mono:5.0
      (S.Frame_received (thread_create_frame ~thread_id:"THR1" ~parent_id:"CH1" ~seq:10))
  in
  check bool "Emit_event Thread_tracked emitted" true
    (has_emit_thread_tracked ~thread_id:"THR1" ~parent_channel_id:"CH1" effects);
  (* Verify thread_parents was updated: a message in THR1 should now
     pass Mention_or_thread policy without mention. *)
  let payload =
    message_create_payload
      ~id:"M_T1" ~channel_id:"THR1" ~author_id:"U1" ~content:"thread msg"
      ~mention_ids:[] ()
  in
  let _, effects2 =
    S.step m' ~now_mono:6.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:11))
  in
  check bool "Mention_or_thread: message in known thread passes" true
    (has_emit_event effects2)

let test_step_guild_create_bulk_tracks_threads () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  let m', effects =
    S.step m ~now_mono:5.0
      (S.Frame_received
         (guild_create_frame_with_threads
            ~threads:[ ("T1", "C1"); ("T2", "C2"); ("T3", "C1") ]
            ~seq:10))
  in
  check bool "Emit_event Threads_bulk_tracked emitted" true
    (has_emit_threads_bulk_tracked effects);
  (* Messages in all three threads should now pass policy *)
  let test_thread m channel_id =
    let payload =
      message_create_payload
        ~id:"M" ~channel_id ~author_id:"U1" ~content:"hi"
        ~mention_ids:[] ()
    in
    let _, eff =
      S.step m ~now_mono:6.0
        (S.Frame_received
           (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:11))
    in
    has_emit_event eff
  in
  check bool "T1 (parent C1) passes" true (test_thread m' "T1");
  check bool "T2 (parent C2) passes" true (test_thread m' "T2");
  check bool "T3 (parent C1) passes" true (test_thread m' "T3")

(* Mention_or_thread: regular channel still requires mention *)
let test_policy_mention_or_thread_regular_channel_requires_mention () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"M1" ~channel_id:"REGULAR" ~author_id:"U1" ~content:"no mention"
      ~mention_ids:[] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:5))
  in
  check bool "Mention_or_thread: regular channel without mention => suppressed"
    false (has_emit_event effects);
  check bool "Mention_or_thread: regular channel without mention => ambient"
    true (has_emit_ambient effects)

let test_policy_mention_or_thread_regular_channel_with_mention_passes () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  let payload =
    message_create_payload
      ~id:"M2" ~channel_id:"REGULAR" ~author_id:"U1" ~content:"<@BOT> hi"
      ~mention_ids:[ "BOT" ] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:5))
  in
  check bool "Mention_or_thread: regular channel with mention => passes"
    true (has_emit_event effects)

let test_policy_mention_or_thread_unknown_thread_still_requires_mention () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  (* No THREAD_CREATE dispatched — "UNKNOWN_THR" is not in thread_parents *)
  let payload =
    message_create_payload
      ~id:"M3" ~channel_id:"UNKNOWN_THR" ~author_id:"U1" ~content:"hi"
      ~mention_ids:[] ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:5))
  in
  check bool "Mention_or_thread: unknown thread => suppressed (no mention)"
    false (has_emit_event effects)

let test_policy_mention_or_thread_reaction_suppressed () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  let payload =
    reaction_add_payload
      ~channel_id:"C1" ~message_id:"M1" ~user_id:"U1" ~emoji_name:"👍" ()
  in
  let _, effects =
    S.step m ~now_mono:3.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_REACTION_ADD" ~payload ~seq:5))
  in
  check bool "Mention_or_thread: reaction suppressed (same as mention_only)"
    false (has_emit_event effects)

(* Regression: Mention_only ignores is_thread entirely *)
let test_policy_mention_only_ignores_thread () =
  let m = connected_with_policy ~policy:S.Mention_only ~bot_user_id:"BOT" in
  (* Register thread *)
  let m', _ =
    S.step m ~now_mono:5.0
      (S.Frame_received (thread_create_frame ~thread_id:"THR1" ~parent_id:"CH1" ~seq:10))
  in
  (* Thread_parents has THR1, but Mention_only ignores is_thread *)
  let payload =
    message_create_payload
      ~id:"M4" ~channel_id:"THR1" ~author_id:"U1" ~content:"thread msg"
      ~mention_ids:[] ()
  in
  let _, effects =
    S.step m' ~now_mono:6.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:11))
  in
  check bool "Mention_only: thread message without mention => suppressed"
    false (has_emit_event effects)

(* Thread tracking survives reconnect *)
let test_thread_registry_survives_reconnect () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  (* Register thread *)
  let m, _ =
    S.step m ~now_mono:5.0
      (S.Frame_received (thread_create_frame ~thread_id:"THR1" ~parent_id:"CH1" ~seq:10))
  in
  (* Reconnect cycle *)
  let m, _ =
    S.step m ~now_mono:10.0
      (S.Wss_closed { code = 1006; reason = "blip" })
  in
  let m, _ = S.step m ~now_mono:12.0 S.Backoff_elapsed in
  let m, _ =
    S.step m ~now_mono:13.0
      (S.Frame_received (hello_frame ~heartbeat_interval:41250))
  in
  let resumed : S.frame =
    { op = S.Op_dispatch; s = Some 99; t = Some "RESUMED"; d = `Assoc [] }
  in
  let m, _ = S.step m ~now_mono:14.0 (S.Frame_received resumed) in
  (* Thread should still be tracked after reconnect *)
  let payload =
    message_create_payload
      ~id:"M5" ~channel_id:"THR1" ~author_id:"U1" ~content:"after reconnect"
      ~mention_ids:[] ()
  in
  let _, effects =
    S.step m ~now_mono:15.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:100))
  in
  check bool "thread_parents survives reconnect cycle" true
    (has_emit_event effects)

(* ── Thread removal lifecycle ─────────────────────────────────────── *)

let thread_delete_frame ~thread_id ~seq : S.frame =
  { op = S.Op_dispatch
  ; s = Some seq
  ; t = Some "THREAD_DELETE"
  ; d =
      `Assoc
        [ ("id", `String thread_id)
        ; ("guild_id", `String "G1")
        ; ("parent_id", `String "CH1")
        ; ("type", `Int 11)
        ]
  }

let thread_update_archived_frame ~thread_id ~parent_id ~seq : S.frame =
  { op = S.Op_dispatch
  ; s = Some seq
  ; t = Some "THREAD_UPDATE"
  ; d =
      `Assoc
        [ ("id", `String thread_id)
        ; ("parent_id", `String parent_id)
        ; ("type", `Int 11)
        ; ("thread_metadata", `Assoc [ ("archived", `Bool true) ])
        ]
  }

let has_emit_thread_removed ~thread_id effects =
  List.exists
    (function
      | S.Emit_event (S.Thread_removed { thread_id = tid }) ->
          String.equal tid thread_id
      | _ -> false)
    effects

(* Decode: THREAD_DELETE => Thread_removed *)
let test_decode_thread_delete () =
  let payload =
    `Assoc [ ("id", `String "THR1"); ("parent_id", `String "CH1") ]
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"THREAD_DELETE" ~payload with
  | Ok (S.Thread_removed { thread_id = "THR1" }) -> ()
  | Ok _ -> fail "decoded THREAD_DELETE to wrong variant"
  | Error e -> fail (Printf.sprintf "THREAD_DELETE decode error: %s" e)

(* Decode: THREAD_DELETE missing id => Ignored *)
let test_decode_thread_delete_missing_id () =
  let payload = `Assoc [ ("parent_id", `String "CH1") ] in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"THREAD_DELETE" ~payload with
  | Ok (S.Ignored _) -> ()
  | Ok _ -> fail "expected Ignored for THREAD_DELETE without id"
  | Error e -> fail (Printf.sprintf "THREAD_DELETE decode error: %s" e)

(* Decode: THREAD_UPDATE with archived=true => Thread_removed *)
let test_decode_thread_update_archived () =
  let payload =
    `Assoc
      [ ("id", `String "THR1")
      ; ("parent_id", `String "P1")
      ; ("thread_metadata", `Assoc [ ("archived", `Bool true) ])
      ]
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"THREAD_UPDATE" ~payload with
  | Ok (S.Thread_removed { thread_id = "THR1" }) -> ()
  | Ok _ -> fail "THREAD_UPDATE archived=true should decode to Thread_removed"
  | Error e -> fail (Printf.sprintf "THREAD_UPDATE decode error: %s" e)

(* Decode: THREAD_UPDATE with archived=false => Thread_tracked (unchanged) *)
let test_decode_thread_update_active_still_tracked () =
  let payload =
    `Assoc
      [ ("id", `String "THR1")
      ; ("parent_id", `String "P1")
      ; ("thread_metadata", `Assoc [ ("archived", `Bool false) ])
      ]
  in
  match S.decode_dispatch ~bot_user_id:None ~event_name:"THREAD_UPDATE" ~payload with
  | Ok (S.Thread_tracked { thread_id = "THR1"; parent_channel_id = "P1" }) -> ()
  | Ok _ -> fail "THREAD_UPDATE archived=false should still be Thread_tracked"
  | Error e -> fail (Printf.sprintf "THREAD_UPDATE decode error: %s" e)

(* Step: THREAD_DELETE removes from thread_parents *)
let test_step_thread_delete_removes_from_registry () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  (* Register thread *)
  let m, _ =
    S.step m ~now_mono:5.0
      (S.Frame_received (thread_create_frame ~thread_id:"THR1" ~parent_id:"CH1" ~seq:10))
  in
  (* Verify thread is tracked *)
  let payload1 =
    message_create_payload
      ~id:"M1" ~channel_id:"THR1" ~author_id:"U1" ~content:"in thread"
      ~mention_ids:[] ()
  in
  let _, effects1 =
    S.step m ~now_mono:6.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload:payload1 ~seq:11))
  in
  check bool "before delete: thread message passes policy" true
    (has_emit_event effects1);
  (* Delete thread *)
  let m, effects2 =
    S.step m ~now_mono:7.0
      (S.Frame_received (thread_delete_frame ~thread_id:"THR1" ~seq:12))
  in
  check bool "Thread_removed emitted" true
    (has_emit_thread_removed ~thread_id:"THR1" effects2);
  (* Verify thread is no longer tracked *)
  let payload3 =
    message_create_payload
      ~id:"M3" ~channel_id:"THR1" ~author_id:"U1" ~content:"after delete"
      ~mention_ids:[] ()
  in
  let _, effects3 =
    S.step m ~now_mono:8.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload:payload3 ~seq:13))
  in
  check bool "after delete: thread message suppressed (no longer tracked)" true
    (not (has_emit_event effects3))

(* Step: THREAD_UPDATE archived=true removes from thread_parents *)
let test_step_thread_update_archived_removes_from_registry () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  (* Register thread *)
  let m, _ =
    S.step m ~now_mono:5.0
      (S.Frame_received (thread_create_frame ~thread_id:"THR1" ~parent_id:"CH1" ~seq:10))
  in
  (* Archive the thread *)
  let m, effects =
    S.step m ~now_mono:6.0
      (S.Frame_received
         (thread_update_archived_frame ~thread_id:"THR1" ~parent_id:"CH1" ~seq:11))
  in
  check bool "Thread_removed emitted on archive" true
    (has_emit_thread_removed ~thread_id:"THR1" effects);
  (* Verify thread is no longer tracked *)
  let payload =
    message_create_payload
      ~id:"M2" ~channel_id:"THR1" ~author_id:"U1" ~content:"in archived"
      ~mention_ids:[] ()
  in
  let _, effects2 =
    S.step m ~now_mono:7.0
      (S.Frame_received
         (dispatch_frame ~event_name:"MESSAGE_CREATE" ~payload ~seq:12))
  in
  check bool "after archive: thread message suppressed" true
    (not (has_emit_event effects2))

(* Step: deleting a non-existent thread is a no-op *)
let test_step_thread_delete_unknown_is_noop () =
  let m = connected_with_policy ~policy:S.Mention_or_thread ~bot_user_id:"BOT" in
  let _, effects =
    S.step m ~now_mono:5.0
      (S.Frame_received (thread_delete_frame ~thread_id:"NEVER_EXISTED" ~seq:10))
  in
  check bool "Thread_removed emitted for unknown thread" true
    (has_emit_thread_removed ~thread_id:"NEVER_EXISTED" effects)

(* ---------------------------------------------------------------- *)
(* Entry                                                            *)
(* ---------------------------------------------------------------- *)

let () =
  run "discord_gateway_state"
    [ ( "primitives"
      , [ test_case "opcode round-trip" `Quick test_opcode_round_trip
        ; test_case "intents bitmask" `Quick test_intents_bitmask
        ; test_case "presence status strings" `Quick
            test_presence_status_strings
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
    ; ( "presence"
      , [ test_case "Status_change (Connected) → opcode 3 STATUS_UPDATE"
            `Quick test_status_change_connected_emits_status_update
        ; test_case "Status_change Idle sets afk=true" `Quick
            test_status_change_idle_sets_afk
        ; test_case "Status_change ignored before Connected" `Quick
            test_status_change_ignored_when_not_connected
        ] )
    ; ( "dispatch decode"
      , [ test_case "MESSAGE_CREATE with mention sets mentions_bot=true"
            `Quick test_decode_message_create_with_mention
        ; test_case "MESSAGE_CREATE without mention sets mentions_bot=false"
            `Quick test_decode_message_create_without_mention
        ; test_case "MESSAGE_CREATE preserves guild_id" `Quick
            test_decode_message_create_preserves_guild_id
        ; test_case "MESSAGE_CREATE reply-ping is not explicit mention"
            `Quick test_decode_message_create_reply_ping_is_not_explicit_mention
        ; test_case "author_name prefers global_name" `Quick
            test_decode_author_name_prefers_global_name
        ; test_case "author_name falls back to username" `Quick
            test_decode_author_name_falls_back_to_username
        ; test_case "author_name absent when payload has neither" `Quick
            test_decode_author_name_absent_when_payload_has_neither
        ; test_case "MESSAGE_REACTION_ADD unicode emoji" `Quick
            test_decode_reaction_add_unicode
        ; test_case "MESSAGE_REACTION_ADD custom emoji => name:id" `Quick
            test_decode_reaction_add_custom_emoji
        ] )
    ; ( "trigger_policy filter"
      , [ test_case "mention_only + mentioned message => Emit_event" `Quick
            test_policy_mention_only_message_with_mention_passes
        ; test_case "mention_only + plain message => suppressed" `Quick
            test_policy_mention_only_message_without_mention_filtered
        ; test_case "mention_only + reaction => suppressed (always)" `Quick
            test_policy_mention_only_reaction_filtered
        ; test_case "user_only id + matching author => Emit_event" `Quick
            test_policy_user_only_message_matching_author_passes
        ; test_case
            "user_only id + other author + mention => suppressed (no \
             bypass)"
            `Quick test_policy_user_only_message_other_author_filtered
        ; test_case
            "user_only id + matching reactor => Emit_event"
            `Quick test_policy_user_only_reaction_matching_reactor_passes
        ; test_case "all + any message + any reaction => both Emit_event"
            `Quick test_policy_all_emits_messages_and_reactions
        ] )
    ; ( "ambient lane (RFC-0226)"
      , [ test_case "mention_only + plain message => Emit_ambient" `Quick
            test_ambient_mention_only_plain_message
        ; test_case "mention_only + reply-ping => Emit_ambient" `Quick
            test_ambient_mention_only_reply_ping_is_ambient
        ; test_case "policy pass => Emit_event only, no ambient" `Quick
            test_ambient_absent_when_policy_passes
        ; test_case "user_only + other author => Emit_ambient" `Quick
            test_ambient_user_only_other_author
        ; test_case "self echo => neither event nor ambient" `Quick
            test_ambient_never_for_self
        ; test_case "reactions never ambient" `Quick
            test_ambient_not_for_reactions
        ] )
    ; ( "self-skip guard"
      , [ test_case "self message suppressed under All" `Quick
            test_self_message_suppressed_under_all_policy
        ; test_case "self message suppressed when User_only id == bot id"
            `Quick
            test_self_message_suppressed_when_user_only_targets_bot_id
        ; test_case "self reaction suppressed under All" `Quick
            test_self_reaction_suppressed_under_all_policy
        ; test_case "non-self message still emits under All (regression)"
            `Quick test_non_self_message_still_emitted_under_all
        ] )
    ; ( "bot/webhook suppression (F940)"
      , [ test_case "decode: author.bot=true => author_is_bot" `Quick
            test_decode_sets_author_is_bot_from_bot_flag
        ; test_case "decode: webhook_id present => author_is_bot" `Quick
            test_decode_sets_author_is_bot_from_webhook_id
        ; test_case "decode: plain author => not bot" `Quick
            test_decode_human_author_is_not_bot
        ; test_case "bot mention suppressed under Mention_only" `Quick
            test_bot_mention_suppressed_under_mention_only
        ; test_case "webhook mention suppressed under Mention_only" `Quick
            test_webhook_mention_suppressed_under_mention_only
        ; test_case "human mention still passes (regression)" `Quick
            test_human_mention_still_passes_under_mention_only
        ; test_case "bot in thread suppressed under Mention_or_thread" `Quick
            test_bot_in_thread_suppressed_under_mention_or_thread
        ; test_case "human in thread still passes (regression)" `Quick
            test_human_in_thread_still_passes_under_mention_or_thread
        ; test_case "User_only opt-in honored for bot author" `Quick
            test_bot_passes_when_user_only_targets_it
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
        ; test_case
            "Wss_closed from Connected emits Close_wss (conn_ref cleanup)"
            `Quick test_wss_closed_emits_close_wss
        ; test_case
            "Wss_closed from Awaiting_hello emits Close_wss"
            `Quick test_wss_closed_emits_close_wss_from_awaiting_hello
        ; test_case
            "Awaiting_hello timeout escapes to Reconnect_pending"
            `Quick test_awaiting_hello_timeout_escapes_to_reconnect
        ; test_case
            "Awaiting_hello before timeout stays in Awaiting_hello"
            `Quick test_awaiting_hello_before_timeout_stays
        ] )
    ; ( "thread decode"
      , [ test_case "THREAD_CREATE with id + parent_id => Thread_tracked" `Quick
            test_decode_thread_create
        ; test_case "THREAD_CREATE missing parent_id => Ignored" `Quick
            test_decode_thread_create_missing_fields
        ; test_case "GUILD_CREATE with threads => Threads_bulk_tracked" `Quick
            test_decode_guild_create_with_threads
        ; test_case "GUILD_CREATE without threads => Ignored" `Quick
            test_decode_guild_create_without_threads
        ; test_case "THREAD_UPDATE decodes same as THREAD_CREATE" `Quick
            test_decode_thread_update_same_as_create
        ; test_case "THREAD_DELETE => Thread_removed" `Quick
            test_decode_thread_delete
        ; test_case "THREAD_DELETE missing id => Ignored" `Quick
            test_decode_thread_delete_missing_id
        ; test_case "THREAD_UPDATE archived=true => Thread_removed" `Quick
            test_decode_thread_update_archived
        ; test_case "THREAD_UPDATE archived=false => Thread_tracked" `Quick
            test_decode_thread_update_active_still_tracked
        ] )
    ; ( "thread tracking + Mention_or_thread policy"
      , [ test_case
            "THREAD_CREATE dispatch updates thread_parents + emits event"
            `Quick test_step_thread_create_updates_registry
        ; test_case
            "GUILD_CREATE bulk tracks all threads"
            `Quick test_step_guild_create_bulk_tracks_threads
        ; test_case
            "Mention_or_thread: regular channel without mention => suppressed"
            `Quick test_policy_mention_or_thread_regular_channel_requires_mention
        ; test_case
            "Mention_or_thread: regular channel with mention => passes"
            `Quick test_policy_mention_or_thread_regular_channel_with_mention_passes
        ; test_case
            "Mention_or_thread: unknown thread => suppressed"
            `Quick test_policy_mention_or_thread_unknown_thread_still_requires_mention
        ; test_case
            "Mention_or_thread: reaction suppressed"
            `Quick test_policy_mention_or_thread_reaction_suppressed
        ; test_case
            "Mention_only: ignores is_thread (no auto-respond in threads)"
            `Quick test_policy_mention_only_ignores_thread
        ; test_case
            "thread_parents survives reconnect cycle"
            `Quick test_thread_registry_survives_reconnect
        ; test_case
            "THREAD_DELETE removes from thread_parents"
            `Quick test_step_thread_delete_removes_from_registry
        ; test_case
            "THREAD_UPDATE archived=true removes from thread_parents"
            `Quick test_step_thread_update_archived_removes_from_registry
        ; test_case
            "THREAD_DELETE for unknown thread is a no-op"
            `Quick test_step_thread_delete_unknown_is_noop
        ] )
    ]
