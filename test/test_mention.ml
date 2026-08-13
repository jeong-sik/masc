open Alcotest

let check_extract label expected content =
  check (option string) label expected (Mention.extract content)
;;

let test_extract_exact_target () =
  check_extract "direct" (Some "ollama") "@ollama status?";
  check_extract
    "full hyphenated target"
    (Some "canary-feature-20260813-202635")
    "@canary-feature-20260813-202635 please ack";
  check_extract "underscore and digits" (Some "agent_v2") "hello @agent_v2";
  check_extract "fleet broadcast" (Some "gemini") "notice @@gemini"
;;

let test_extract_priority () =
  check_extract
    "fleet broadcast keeps priority"
    (Some "gemini")
    "@ollama please notify @@gemini";
  check_extract
    "first direct mention wins"
    (Some "ollama")
    "@ollama please ask @canary-feature-20260813-202635"
;;

let test_extract_requires_mention_boundaries () =
  check_extract "plain text" None "Hello world";
  check_extract "email is not a mention" None "mail test@example.com";
  check_extract "bare marker" None "@";
  check_extract "embedded marker" None "prefix@agent"
;;

let test_exact_target_matching () =
  check bool "exact direct mention" true
    (Mention.is_mentioned "agent-one" "please ask @agent-one now");
  check bool "prefix is not enough" false
    (Mention.is_mentioned "agent" "please ask @agent-one now");
  check bool "email is not a mention" false
    (Mention.is_mentioned "example" "mail test@example.com");
  check bool "case insensitive" true
    (Mention.is_mentioned "Agent-One" "please ask @agent-one now")
;;

let test_any_mentioned () =
  check bool "one exact target" true
    (Mention.any_mentioned
       ~targets:[ "agent-one"; "agent-two" ]
       "please ask @agent-two");
  check bool "no partial target" false
    (Mention.any_mentioned
       ~targets:[ "agent"; "agent-three" ]
       "please ask @agent-two")
;;

let () =
  run
    "Mention"
    [ ( "extract"
      , [ test_case "exact target" `Quick test_extract_exact_target
        ; test_case "priority" `Quick test_extract_priority
        ; test_case "boundaries" `Quick test_extract_requires_mention_boundaries
        ] )
    ; ( "matching"
      , [ test_case "exact target" `Quick test_exact_target_matching
        ; test_case "any target" `Quick test_any_mentioned
        ] )
    ]
;;
