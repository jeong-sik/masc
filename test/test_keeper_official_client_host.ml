open Alcotest
open Masc

module Effort = Llm_provider.Reasoning_effort
module Host = Keeper_official_client_host

let effort_string = Option.map Effort.to_string

let expect_effort label expected result =
  match result with
  | Ok actual -> check (option string) label (effort_string expected) (effort_string actual)
  | Error _ -> fail (label ^ ": unexpected configuration error")
;;

let test_absent_controls_are_omitted () =
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:None
  |> expect_effort "absent" None
;;

let test_explicit_efforts_are_preserved () =
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.Medium)
  |> expect_effort "medium" (Some Effort.Medium);
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.Low)
  |> expect_effort "low" (Some Effort.Low);
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.None_)
  |> expect_effort "explicit none" (Some Effort.None_)
;;

let test_generic_toggle_is_rejected () =
  (match
     Host.resolve_reasoning_effort
       ~enable_thinking:(Some false)
       ~reasoning_effort:None
   with
   | Error _ -> ()
   | Ok _ -> fail "disabled generic toggle was admitted");
  match
    Host.resolve_reasoning_effort
      ~enable_thinking:(Some true)
      ~reasoning_effort:(Some Effort.Medium)
  with
  | Error _ -> ()
  | Ok _ -> fail "enabled generic toggle was admitted"
;;

let () =
  run
    "keeper official-client host"
    [ ( "reasoning effort"
      , [ test_case
            "absent controls are omitted"
            `Quick
            test_absent_controls_are_omitted
        ; test_case
            "explicit efforts are preserved"
            `Quick
            test_explicit_efforts_are_preserved
        ; test_case
            "generic toggle is rejected"
            `Quick
            test_generic_toggle_is_rejected
        ] )
    ]
;;
