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

let test_disabled_without_effort_is_omitted () =
  Host.resolve_reasoning_effort
    ~enable_thinking:(Some false)
    ~reasoning_effort:None
  |> expect_effort "no synthesized none" None
;;

let test_explicit_efforts_are_preserved () =
  Host.resolve_reasoning_effort
    ~enable_thinking:(Some true)
    ~reasoning_effort:(Some Effort.Medium)
  |> expect_effort "medium" (Some Effort.Medium);
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.Low)
  |> expect_effort "low" (Some Effort.Low);
  Host.resolve_reasoning_effort
    ~enable_thinking:(Some false)
    ~reasoning_effort:(Some Effort.None_)
  |> expect_effort "explicit none" (Some Effort.None_)
;;

let test_conflicting_controls_fail_closed () =
  (match
     Host.resolve_reasoning_effort
       ~enable_thinking:(Some false)
       ~reasoning_effort:(Some Effort.High)
   with
   | Error _ -> ()
   | Ok _ -> fail "disabled thinking admitted a non-none effort");
  match
    Host.resolve_reasoning_effort
      ~enable_thinking:(Some true)
      ~reasoning_effort:(Some Effort.None_)
  with
  | Error _ -> ()
  | Ok _ -> fail "enabled thinking admitted an explicit none effort"
;;

let () =
  run
    "keeper official-client host"
    [ ( "reasoning effort"
      , [ test_case
            "disabled without effort is omitted"
            `Quick
            test_disabled_without_effort_is_omitted
        ; test_case
            "explicit efforts are preserved"
            `Quick
            test_explicit_efforts_are_preserved
        ; test_case
            "conflicting controls fail closed"
            `Quick
            test_conflicting_controls_fail_closed
        ] )
    ]
;;
