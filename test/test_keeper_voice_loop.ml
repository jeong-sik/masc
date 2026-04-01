open Alcotest

(* ============================================================ *)
(* Pure function tests                                           *)
(* ============================================================ *)

let test_extract_text_from_stt_valid () =
  let json = `Assoc [("text", `String "hello world")] in
  check (option string) "extracts text"
    (Some "hello world")
    (Keeper_voice_loop.extract_text_from_stt json)

let test_extract_text_from_stt_empty () =
  let json = `Assoc [("text", `String "   ")] in
  check (option string) "empty text returns None"
    None
    (Keeper_voice_loop.extract_text_from_stt json)

let test_extract_text_from_stt_missing () =
  let json = `Assoc [("other", `String "data")] in
  check (option string) "missing text returns None"
    None
    (Keeper_voice_loop.extract_text_from_stt json)

let test_extract_reply_text_valid () =
  let json_str = Yojson.Safe.to_string
    (`Assoc [("reply", `String "keeper says hi")]) in
  check (option string) "extracts reply"
    (Some "keeper says hi")
    (Keeper_voice_loop.extract_reply_text json_str)

let test_extract_reply_text_missing () =
  let json_str = Yojson.Safe.to_string
    (`Assoc [("status", `String "ok")]) in
  check (option string) "missing reply returns None"
    None
    (Keeper_voice_loop.extract_reply_text json_str)

let test_is_stop_command_english () =
  check bool "stop" true (Keeper_voice_loop.is_stop_command "stop");
  check bool "EXIT" true (Keeper_voice_loop.is_stop_command "EXIT");
  check bool "  quit  " true (Keeper_voice_loop.is_stop_command "  quit  ")

let test_is_stop_command_korean () =
  check bool "종료" true (Keeper_voice_loop.is_stop_command "종료");
  check bool "그만" true (Keeper_voice_loop.is_stop_command "그만");
  check bool "끝" true (Keeper_voice_loop.is_stop_command "끝")

let test_is_stop_command_negative () =
  check bool "hello" false (Keeper_voice_loop.is_stop_command "hello");
  check bool "empty" false (Keeper_voice_loop.is_stop_command "")

(* ============================================================ *)
(* Integration tests via mock injection                          *)
(* ============================================================ *)

let make_record responses =
  let idx = ref 0 in
  fun ~agent_id:_ ?language_code:_ () ->
    let r = List.nth responses !idx in
    idx := min (!idx + 1) (List.length responses - 1);
    r

let noop_speak _text = Ok (`Assoc [("status", `String "ok")])

let echo_send text =
  (true, Yojson.Safe.to_string
    (`Assoc [("reply", `String (Printf.sprintf "echo: %s" text))]))

let test_run_stop_command () =
  let record = make_record [
    Ok (`Assoc [("text", `String "hello")]);
    Ok (`Assoc [("text", `String "종료")]);
  ] in
  let (success, msg) =
    Keeper_voice_loop.run ~agent_id:"test" ~send_message:echo_send
      ~speak:noop_speak ~record ~max_turns:10 ()
  in
  check bool "success" true success;
  check bool "contains user exit"
    true (String.length msg > 0 &&
          let re = Re.compile (Re.str "user exit") in
          Re.execp re msg)

let test_run_max_turns () =
  let record = make_record [
    Ok (`Assoc [("text", `String "talk")]);
  ] in
  let (success, msg) =
    Keeper_voice_loop.run ~agent_id:"test" ~send_message:echo_send
      ~speak:noop_speak ~record ~max_turns:3 ()
  in
  check bool "success" true success;
  check bool "contains max reached"
    true (String.length msg > 0 &&
          let re = Re.compile (Re.str "max reached") in
          Re.execp re msg)

let test_run_consecutive_empty_stops () =
  let record = make_record [
    Ok (`Assoc [("text", `String "")]);
  ] in
  let (success, msg) =
    Keeper_voice_loop.run ~agent_id:"test" ~send_message:echo_send
      ~speak:noop_speak ~record ~max_turns:100 ()
  in
  check bool "success" true success;
  check bool "contains empty STT"
    true (String.length msg > 0 &&
          let re = Re.compile (Re.str "empty STT") in
          Re.execp re msg)

let test_run_empty_resets_on_success () =
  let call_count = ref 0 in
  let record ~agent_id:_ ?language_code:_ () =
    incr call_count;
    if !call_count <= 3 then
      Ok (`Assoc [("text", `String "")])
    else if !call_count = 4 then
      Ok (`Assoc [("text", `String "hello")])
    else if !call_count <= 7 then
      Ok (`Assoc [("text", `String "")])
    else
      Ok (`Assoc [("text", `String "종료")])
  in
  let (success, msg) =
    Keeper_voice_loop.run ~agent_id:"test" ~send_message:echo_send
      ~speak:noop_speak ~record ~max_turns:100 ()
  in
  check bool "success" true success;
  check bool "exited via stop not empty limit"
    true (String.length msg > 0 &&
          let re = Re.compile (Re.str "user exit") in
          Re.execp re msg)

let test_run_error_on_first_turn () =
  let record = make_record [
    Error "mic not found";
  ] in
  let (success, _msg) =
    Keeper_voice_loop.run ~agent_id:"test" ~send_message:echo_send
      ~speak:noop_speak ~record ~max_turns:10 ()
  in
  check bool "fails on first turn" false success

let () =
  run "Keeper_voice_loop"
    [
      ( "extract_text_from_stt",
        [
          test_case "valid text" `Quick test_extract_text_from_stt_valid;
          test_case "empty text" `Quick test_extract_text_from_stt_empty;
          test_case "missing field" `Quick test_extract_text_from_stt_missing;
        ] );
      ( "extract_reply_text",
        [
          test_case "valid reply" `Quick test_extract_reply_text_valid;
          test_case "missing reply" `Quick test_extract_reply_text_missing;
        ] );
      ( "is_stop_command",
        [
          test_case "english" `Quick test_is_stop_command_english;
          test_case "korean" `Quick test_is_stop_command_korean;
          test_case "negative" `Quick test_is_stop_command_negative;
        ] );
      ( "run",
        [
          test_case "stop command ends loop" `Quick test_run_stop_command;
          test_case "max turns ends loop" `Quick test_run_max_turns;
          test_case "consecutive empty STT stops loop" `Quick test_run_consecutive_empty_stops;
          test_case "empty count resets on success" `Quick test_run_empty_resets_on_success;
          test_case "error on first turn" `Quick test_run_error_on_first_turn;
        ] );
    ]
