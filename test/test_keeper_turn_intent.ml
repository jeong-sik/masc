open Alcotest
module TI = Masc_mcp.Keeper_turn_intent

let intent_t : TI.t testable = testable (Fmt.of_to_string TI.to_string) TI.equal

let test_retry_positive () =
  let r =
    TI.classify ~last_tool_calls:[ "task_claim" ] ~last_user_message:None ~retry_count:1
  in
  check intent_t "retry=1 → Cognitive" TI.Cognitive r
;;

let test_mechanical_only () =
  let r =
    TI.classify
      ~last_tool_calls:[ "task_claim"; "board_list"; "fs_read" ]
      ~last_user_message:(Some "ok")
      ~retry_count:0
  in
  check intent_t "all mechanical tools → Mechanical" TI.Mechanical r
;;

let test_cognitive_keyword () =
  let r =
    TI.classify
      ~last_tool_calls:[ "task_claim" ]
      ~last_user_message:(Some "please PLAN the migration")
      ~retry_count:0
  in
  check intent_t "keyword 'plan' (case-insensitive) → Cognitive" TI.Cognitive r
;;

let test_idle_turn () =
  let r = TI.classify ~last_tool_calls:[] ~last_user_message:None ~retry_count:0 in
  check intent_t "empty tool calls → Cognitive (break idle)" TI.Cognitive r
;;

let test_mixed_mechanical_unknown () =
  let r =
    TI.classify
      ~last_tool_calls:[ "shell"; "foo_unknown_tool" ]
      ~last_user_message:(Some "ok")
      ~retry_count:0
  in
  check intent_t "unknown tool in list → Cognitive" TI.Cognitive r
;;

let test_default_no_message () =
  let r =
    TI.classify ~last_tool_calls:[ "task_claim" ] ~last_user_message:None ~retry_count:0
  in
  check intent_t "mechanical + no message + no retry → Mechanical" TI.Mechanical r
;;

let test_debug_keyword () =
  let r =
    TI.classify
      ~last_tool_calls:[ "shell" ]
      ~last_user_message:(Some "why did the build fail? help me debug")
      ~retry_count:0
  in
  check intent_t "keyword 'debug' → Cognitive" TI.Cognitive r
;;

let test_neutral_message_mechanical_tools () =
  let r =
    TI.classify
      ~last_tool_calls:[ "board_list"; "task_claim" ]
      ~last_user_message:(Some "proceed with next item")
      ~retry_count:0
  in
  check intent_t "neutral message + mechanical tools → Mechanical" TI.Mechanical r
;;

let () =
  Alcotest.run
    "keeper_turn_intent"
    [ ( "classify"
      , [ test_case "retry positive" `Quick test_retry_positive
        ; test_case "mechanical only" `Quick test_mechanical_only
        ; test_case "cognitive keyword" `Quick test_cognitive_keyword
        ; test_case "idle turn" `Quick test_idle_turn
        ; test_case "mixed unknown" `Quick test_mixed_mechanical_unknown
        ; test_case "default no message" `Quick test_default_no_message
        ; test_case "debug keyword" `Quick test_debug_keyword
        ; test_case "neutral + mechanical" `Quick test_neutral_message_mechanical_tools
        ] )
    ]
;;
