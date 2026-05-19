(** SDK error classification tests for [test_oas_worker]. *)

open Masc_mcp

let contains_substring ~needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    i + n <= h
    && (String.sub haystack i n = needle || loop (i + 1))
  in
  n = 0 || loop 0
;;

let test_sdk_error_is_hard_quota_detects_gemini_cli_network_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message =
             "gemini exited with code 1: TerminalQuotaError: You have exhausted your \
              capacity on this model. Your quota will reset after 4h41m7s. \
              reason=QUOTA_EXHAUSTED"
         ; kind = Llm_provider.Http_client.Unknown
         })
  in
  Alcotest.(check bool)
    "Gemini CLI quota wrapper counts as hard quota"
    true
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

let test_sdk_error_is_hard_quota_detects_claude_cli_limit_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message =
             "claude exited with code 1: \
              {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've \
              hit your limit · resets Apr 24 at 4am (Asia/Seoul)\"}"
         ; kind = Llm_provider.Http_client.Unknown
         })
  in
  Alcotest.(check bool)
    "Claude CLI limit wrapper counts as hard quota"
    true
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

let test_sdk_error_is_hard_quota_detects_claude_org_monthly_limit_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message =
             "claude exited with code 1: \
              {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've \
              hit your org's monthly usage limit\"}"
         ; kind = Llm_provider.Http_client.Unknown
         })
  in
  Alcotest.(check bool)
    "Claude org monthly usage limit counts as hard quota"
    true
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

(* Anthropic console can return user-set monthly caps as HTTP 400
   [invalid_request_error] rather than 429.  Keep both the CLI wrapper and
   direct API path pinned so fallback behavior does not silently regress. *)
let test_sdk_error_is_hard_quota_detects_claude_specified_limit_cli_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message =
             "claude exited with code 1: API Error: 400 \
              {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"You \
              have reached your specified API usage limits. You will regain access on \
              2026-05-01 at 00:00 UTC.\"}}"
         ; kind = Llm_provider.Http_client.Unknown
         })
  in
  Alcotest.(check bool)
    "Claude CLI 400-wrapped specified-limit counts as hard quota"
    true
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

let test_sdk_error_is_hard_quota_detects_anthropic_invalid_request_specified_limit () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message =
             "You have reached your specified API usage limits. You will regain access \
              on 2026-05-01 at 00:00 UTC."
         })
  in
  Alcotest.(check bool)
    "Direct Anthropic InvalidRequest specified-limit counts as hard quota"
    true
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

let test_sdk_error_is_max_turns_detects_claude_cli_wrapper () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message =
             "claude exited with code 1: \
              {\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"terminal_reason\":\"max_turns\",\"errors\":[\"Reached \
              maximum number of turns (10)\"]}"
         ; kind = Llm_provider.Http_client.Unknown
         })
  in
  Alcotest.(check bool)
    "Claude CLI max turns counts as max-turns"
    true
    (Keeper_turn_driver.sdk_error_is_max_turns_exceeded err);
  Alcotest.(check bool)
    "Claude CLI max turns is not hard quota"
    false
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

let test_sdk_error_is_hard_quota_keeps_transient_network_errors_false () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message = "gemini exited with code 1: connection reset by peer"
         ; kind = Llm_provider.Http_client.Connection_refused
         })
  in
  Alcotest.(check bool)
    "transient network error stays transient"
    false
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

let test_sdk_error_is_hard_quota_preserves_rate_limited_detection () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.RateLimited
         { retry_after = None; message = "resource exhausted" })
  in
  Alcotest.(check bool)
    "existing RateLimited hard quota still works"
    true
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

let test_sdk_error_is_hard_quota_keeps_not_found_false () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest { message = {|{"detail":"Not Found"}|} })
  in
  Alcotest.(check bool)
    "404-like InvalidRequest stays non-hard-quota"
    false
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

let test_sdk_error_to_cascade_outcome_maps_not_found_to_404 () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest { message = {|{"detail":"Not Found"}|} })
  in
  match Keeper_turn_driver.sdk_error_to_cascade_outcome err with
  | Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.HttpError
            { code = 404; body = {|{"detail":"Not Found"}|} })) -> ()
  | outcome ->
    Alcotest.failf
      "expected Some (Call_err (HttpError 404)) for 404-like InvalidRequest, got %s"
      (Cascade_fsm.provider_outcome_option_to_string outcome)
;;

let test_sdk_error_to_cascade_outcome_keeps_invalid_request_as_400 () =
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest { message = {|{"detail":"Bad Request"}|} })
  in
  match Keeper_turn_driver.sdk_error_to_cascade_outcome err with
  | Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.HttpError
            { code = 400; body = {|{"detail":"Bad Request"}|} })) -> ()
  | outcome ->
    Alcotest.failf
      "expected Some (Call_err (HttpError 400)) for ordinary InvalidRequest, got %s"
      (Cascade_fsm.provider_outcome_option_to_string outcome)
;;

let test_sdk_error_to_cascade_outcome_cascades_model_access_denied () =
  let message = "Invalid request: You do not have permission to access glm-5-code" in
  let err = Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest { message }) in
  match Keeper_turn_driver.sdk_error_to_cascade_outcome err with
  | Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.ProviderFailure
            { kind =
                Llm_provider.Http_client.Capability_mismatch
                  { capability = Some "model_access" }
            ; message = actual_message
            } as http_err)) ->
    Alcotest.(check string) "message preserved" message actual_message;
    Alcotest.(check bool)
      "failed model name visible"
      true
      (contains_substring ~needle:"glm-5-code" actual_message);
    Alcotest.(check bool)
      "model access denial cascades"
      true
      (Oas_compat.Http_client.should_cascade http_err)
  | outcome ->
    Alcotest.failf
      "expected model access InvalidRequest to cascade as ProviderFailure \
       Capability_mismatch, got %s"
      (Cascade_fsm.provider_outcome_option_to_string outcome)
;;

let test_sdk_error_is_model_access_denied_predicate () =
  let denied =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message = "Invalid request: You do not have permission to access glm-5-code" })
  in
  let ordinary =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest { message = {|{"detail":"Bad Request"}|} })
  in
  Alcotest.(check bool)
    "model access denied is detected"
    true
    (Keeper_turn_driver.sdk_error_is_model_access_denied denied);
  Alcotest.(check bool)
    "ordinary invalid request is not model access denial"
    false
    (Keeper_turn_driver.sdk_error_is_model_access_denied ordinary)
;;

let test_sdk_error_to_cascade_outcome_cascades_runtime_mcp_auth_config () =
  let detail = "codex_cli runtime MCP cannot carry keeper-bound auth headers" in
  let err =
    Agent_sdk.Error.Config
      (Agent_sdk.Error.InvalidConfig { field = "runtime_mcp_auth"; detail })
  in
  match Keeper_turn_driver.sdk_error_to_cascade_outcome err with
  | Some (Cascade_fsm.Call_err (Llm_provider.Http_client.AcceptRejected { reason })) ->
    Alcotest.(check string) "reason preserved" detail reason
  | outcome ->
    Alcotest.failf
      "expected runtime_mcp_auth InvalidConfig to cascade as AcceptRejected, got %s"
      (Cascade_fsm.provider_outcome_option_to_string outcome)
;;

let test_sdk_error_to_cascade_outcome_cascades_resumable_cli_session () =
  let raw_message =
    "cli-tool exited with code 1: \n\
     To resume this session: cli-tool -r 5de0f199-6bd7-4509-bfa6-3308e0ebd97f"
  in
  let detail =
    Cascade_transport.Json_stream_cli_transport_local.resumable_session_detail_of_text raw_message
  in
  let sdk_error =
    Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest { message = detail })
  in
  let structured =
    match
      Keeper_turn_driver.sdk_error_to_resumable_cli_session
        ~cascade_name:(Keeper_turn_driver.cascade_name_of_string "tool_use_strict")
        sdk_error
    with
    | Some structured -> structured
    | None -> Alcotest.fail "expected structured resumable CLI session"
  in
  match Keeper_turn_driver.sdk_error_to_cascade_outcome structured with
  | Some (Cascade_fsm.Call_err (Llm_provider.Http_client.NetworkError { message; kind }))
    ->
    Alcotest.(check bool)
      "detail remains resumable marker"
      true
      (Keeper_turn_driver.message_looks_like_resumable_cli_session message);
    Alcotest.(check bool)
      "unknown network kind"
      true
      (kind = Llm_provider.Http_client.Unknown)
  | outcome ->
    Alcotest.failf
      "expected resumable CLI session to cascade as NetworkError, got %s"
      (Cascade_fsm.provider_outcome_option_to_string outcome)
;;

let test_sdk_error_is_resumable_cli_session_detects_structured_error () =
  let err =
    Keeper_turn_driver.sdk_error_of_masc_internal_error
      (Keeper_turn_driver.Resumable_cli_session
         { cascade_name = Keeper_turn_driver.cascade_name_of_string "governance_judge"
         ; detail =
             "CLI JSON-stream transport reported a resumable session (exit 1). \
              Resumable session available via -r."
         ; exit_code = Some 1
         })
  in
  Alcotest.(check bool)
    "structured resumable CLI session detected"
    true
    (Keeper_turn_driver.sdk_error_is_resumable_cli_session err);
  Alcotest.(check bool)
    "resumable CLI session is not hard quota"
    false
    (Keeper_turn_driver.sdk_error_is_hard_quota err)
;;

let test_sdk_error_is_resumable_cli_session_detects_raw_cli_hint () =
  let raw_message =
    "cli-tool exited with code 1: \n\
     To resume this session: cli-tool -r 5de0f199-6bd7-4509-bfa6-3308e0ebd97f"
  in
  let err =
    Agent_sdk.Error.Api
      (Llm_provider.Retry.NetworkError
         { message = raw_message; kind = Llm_provider.Http_client.Unknown })
  in
  Alcotest.(check bool)
    "raw CLI resume hint detected"
    true
    (Keeper_turn_driver.sdk_error_is_resumable_cli_session err)
;;

let test_fallback_class_labels_resumable_cli_session () =
  let err =
    Keeper_turn_driver.sdk_error_of_masc_internal_error
      (Keeper_turn_driver.Resumable_cli_session
         { cascade_name = Keeper_turn_driver.cascade_name_of_string "primary"
         ; detail =
             "CLI JSON-stream transport reported a resumable session (exit 1). \
              Resumable session available via -r."
         ; exit_code = Some 1
         })
  in
  Alcotest.(check (option string))
    "resumable session fallback class"
    (Some "resumable_cli_session")
    (Keeper_turn_driver.sdk_error_cascade_fallback_class err)
;;

let cases =
  [ Alcotest.test_case
      "sdk_error_is_hard_quota detects Gemini CLI wrapper"
      `Quick
      test_sdk_error_is_hard_quota_detects_gemini_cli_network_wrapper
  ; Alcotest.test_case
      "sdk_error_is_hard_quota detects Claude CLI limit wrapper"
      `Quick
      test_sdk_error_is_hard_quota_detects_claude_cli_limit_wrapper
  ; Alcotest.test_case
      "sdk_error_is_hard_quota detects Claude org monthly limit wrapper"
      `Quick
      test_sdk_error_is_hard_quota_detects_claude_org_monthly_limit_wrapper
  ; Alcotest.test_case
      "sdk_error_is_hard_quota detects Claude 400 specified-limit CLI wrapper"
      `Quick
      test_sdk_error_is_hard_quota_detects_claude_specified_limit_cli_wrapper
  ; Alcotest.test_case
      "sdk_error_is_hard_quota detects Anthropic direct InvalidRequest specified-limit"
      `Quick
      test_sdk_error_is_hard_quota_detects_anthropic_invalid_request_specified_limit
  ; Alcotest.test_case
      "sdk_error_is_max_turns detects Claude CLI wrapper"
      `Quick
      test_sdk_error_is_max_turns_detects_claude_cli_wrapper
  ; Alcotest.test_case
      "sdk_error_is_hard_quota keeps transient network errors false"
      `Quick
      test_sdk_error_is_hard_quota_keeps_transient_network_errors_false
  ; Alcotest.test_case
      "sdk_error_is_hard_quota preserves RateLimited detection"
      `Quick
      test_sdk_error_is_hard_quota_preserves_rate_limited_detection
  ; Alcotest.test_case
      "sdk_error_is_hard_quota keeps NotFound false"
      `Quick
      test_sdk_error_is_hard_quota_keeps_not_found_false
  ; Alcotest.test_case
      "sdk_error_to_cascade_outcome maps NotFound to 404"
      `Quick
      test_sdk_error_to_cascade_outcome_maps_not_found_to_404
  ; Alcotest.test_case
      "sdk_error_to_cascade_outcome keeps ordinary InvalidRequest at 400"
      `Quick
      test_sdk_error_to_cascade_outcome_keeps_invalid_request_as_400
  ; Alcotest.test_case
      "sdk_error_to_cascade_outcome cascades model access denial"
      `Quick
      test_sdk_error_to_cascade_outcome_cascades_model_access_denied
  ; Alcotest.test_case
      "sdk_error_is_model_access_denied classifies model access denial"
      `Quick
      test_sdk_error_is_model_access_denied_predicate
  ; Alcotest.test_case
      "sdk_error_to_cascade_outcome cascades runtime MCP auth config"
      `Quick
      test_sdk_error_to_cascade_outcome_cascades_runtime_mcp_auth_config
  ; Alcotest.test_case
      "sdk_error_to_cascade_outcome cascades resumable CLI session"
      `Quick
      test_sdk_error_to_cascade_outcome_cascades_resumable_cli_session
  ; Alcotest.test_case
      "sdk_error_is_resumable_cli_session detects structured error"
      `Quick
      test_sdk_error_is_resumable_cli_session_detects_structured_error
  ; Alcotest.test_case
      "sdk_error_is_resumable_cli_session detects raw CLI hint"
      `Quick
      test_sdk_error_is_resumable_cli_session_detects_raw_cli_hint
  ; Alcotest.test_case
      "fallback class labels resumable CLI session"
      `Quick
      test_fallback_class_labels_resumable_cli_session
  ]
;;
