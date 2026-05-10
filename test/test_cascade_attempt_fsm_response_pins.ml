(** Pin tests for CLI-wrapped error response classifiers.

    These tests lock the current behavior of
    [message_looks_like_cli_wrapped_hard_quota] and
    [message_looks_like_cli_wrapped_max_turns] against known provider
    response fixtures.  If a provider changes error message phrasing,
    the corresponding test fails — catching silent classification
    drift before it reaches production.

    Each test case is a real (or representative) response body observed
    in production.  The test name encodes the provider + scenario for
    grep-ability. *)

open Masc_mcp

let check_bool = Alcotest.(check bool)

(* ── Hard quota pin tests ──────────────────────────────────────── *)

let hard_quota_fixtures =
  [ ( "anthropic_400_monthly_cap"
    , {|
{"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API usage limits. You will regain access on 2026-05-10 at 00:00 UTC."}}
|}
    , true )
  ; ( "anthropic_429_you_hit_limit"
    , {|
{"type":"error","error":{"type":"error","message":"You've hit your limit for claude-sonnet. Your usage will reset on 2026-05-10."}}
|}
    , true )
  ; ( "anthropic_429_exit_code_1"
    , {|claude exited with code 1 {"api_error_status":429,"error":"you've hit your limit for this model"}|}
    , true )
  ; ( "openrouter_quota_exhausted"
    , {|{"error":{"message":"This model's quota is exhausted. Quota will reset after 2026-05-10T00:00:00Z.","type":"insufficient_quota"}}|}
    , true )
  ; ( "openrouter_terminal_quota_error"
    , {|{"error":{"message":"TerminalQuotaError: exhausted your capacity on this model for this billing period.","type":"quota_error"}}|}
    , true )
  ; ( "generic_429_api_error_status"
    , {|{"api_error_status":429,"message":"rate limited"}|}
    , true )
  ; ( "monthly_usage_limit"
    , {|Your org's monthly usage limit has been reached. Please upgrade your plan.|}
    , true )
  ; "resets_date", {|Error: quota will reset after 2026-05-10T00:00:00Z|}, true
  ; ( "negative_unrelated_error"
    , {|{"type":"error","error":{"type":"authentication_error","message":"Invalid API key"}}|}
    , false )
  ; ( "negative_server_error"
    , {|{"type":"error","error":{"type":"api_error","message":"Internal server error"}}|}
    , false )
  ; ( "negative_max_turns_not_hard_quota"
    , {|{"subtype":"error_max_turns","message":"reached maximum number of turns"}|}
    , false )
  ]
;;

let test_hard_quota_pins () =
  List.iter
    (fun (name, message, expected) ->
       let result =
         Cascade_attempt_fsm.message_looks_like_cli_wrapped_hard_quota message
       in
       check_bool name expected result)
    hard_quota_fixtures
;;

(* ── Max turns pin tests ───────────────────────────────────────── *)

let max_turns_fixtures =
  [ ( "claude_code_error_max_turns"
    , {|{"subtype":"error_max_turns","cost_usd":0.05,"duration_ms":120000}|}
    , true )
  ; ( "claude_code_terminal_reason_max_turns"
    , {|{"terminal_reason":"max_turns","is_error":true}|}
    , true )
  ; "text_max_turns_exceeded", {|Error: max turns exceeded for this session.|}, true
  ; ( "text_reached_maximum"
    , {|You have reached maximum number of turns allowed in this conversation.|}
    , true )
  ; "negative_normal_completion", {|{"subtype":"success","cost_usd":0.03}|}, false
  ; ( "negative_auth_error"
    , {|{"type":"error","error":{"type":"authentication_error","message":"Invalid token"}}|}
    , false )
  ; ( "negative_hard_quota_not_max_turns"
    , {|{"error":{"message":"You've hit your limit for this model"}}|}
    , false )
  ]
;;

let test_max_turns_pins () =
  List.iter
    (fun (name, message, expected) ->
       let result =
         Cascade_attempt_fsm.message_looks_like_cli_wrapped_max_turns message
       in
       check_bool name expected result)
    max_turns_fixtures
;;

(* ── Case-insensitivity check ──────────────────────────────────── *)

let test_case_insensitive () =
  let upper =
    Cascade_attempt_fsm.message_looks_like_cli_wrapped_hard_quota "HARD_QUOTA: exceeded"
  in
  let mixed =
    Cascade_attempt_fsm.message_looks_like_cli_wrapped_hard_quota "Hard_Quota: Exceeded"
  in
  let lower =
    Cascade_attempt_fsm.message_looks_like_cli_wrapped_hard_quota "hard_quota: exceeded"
  in
  check_bool "UPPER" true upper;
  check_bool "MiXeD" true mixed;
  check_bool "lower" true lower
;;

let () =
  Alcotest.run
    "cascade_attempt_fsm_response_pins"
    [ "hard_quota", [ Alcotest.test_case "pin fixtures" `Quick test_hard_quota_pins ]
    ; "max_turns", [ Alcotest.test_case "pin fixtures" `Quick test_max_turns_pins ]
    ; "case_insensitive", [ Alcotest.test_case "ci check" `Quick test_case_insensitive ]
    ]
;;
