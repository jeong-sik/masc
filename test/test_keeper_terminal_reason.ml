(* Tests for keeper_agent_error.terminal_reason_code_of_sdk_error.

   Before this change, every Agent_sdk.Error.Api variant collapsed to a single
   "api_error" string, so the dashboard chip + the operator broadcast
   payload could not differentiate rate-limit / overload / auth / server
   faults. These tests pin down the per-variant terminal reason code so a
   future refactor cannot silently re-collapse the enum (memory:
   no-collapse-richer-enum-at-sdk-boundary). *)

open Alcotest
module KAE = Masc_mcp.Keeper_agent_error
module KT = Masc_mcp.Keeper_turn_terminal
module KTC = Masc_mcp.Keeper_turn_terminal_code

let mk_api err = Agent_sdk.Error.Api err
let mk_agent err = Agent_sdk.Error.Agent err
let code err = KAE.terminal_reason_code_of_sdk_error_typed err |> KTC.to_wire
let terminal_code (reason : KT.t) = KT.code reason
let terminal_next_action (reason : KT.t) = reason.next_action
let terminal_severity (reason : KT.t) = reason.severity

let test_rate_limited () =
  check
    string
    "rate_limited"
    "api_error_rate_limited"
    (code (mk_api (Agent_sdk.Retry.RateLimited { retry_after = None; message = "x" })))
;;

let test_overloaded () =
  check
    string
    "overloaded"
    "api_error_overloaded"
    (code (mk_api (Agent_sdk.Retry.Overloaded { message = "x" })))
;;

let test_server_error_includes_status () =
  check
    string
    "server 503"
    "api_error_server:503"
    (code (mk_api (Agent_sdk.Retry.ServerError { status = 503; message = "x" })));
  check
    string
    "server 500"
    "api_error_server:500"
    (code (mk_api (Agent_sdk.Retry.ServerError { status = 500; message = "x" })))
;;

let test_auth_error () =
  check
    string
    "auth"
    "api_error_auth"
    (code (mk_api (Agent_sdk.Retry.AuthError { message = "x" })))
;;

let test_invalid_request () =
  check
    string
    "invalid_request"
    "api_error_invalid_request"
    (code (mk_api (Agent_sdk.Retry.InvalidRequest { message = "x" })))
;;

let test_not_found () =
  check
    string
    "not_found"
    "api_error_not_found"
    (code (mk_api (Agent_sdk.Retry.NotFound { message = "x" })))
;;

let test_context_overflow () =
  check
    string
    "context_overflow"
    "api_error_context_overflow"
    (code
       (mk_api (Agent_sdk.Retry.ContextOverflow { message = "x"; limit = Some 200_000 })))
;;

let test_network_error () =
  check
    string
    "network"
    "api_error_network"
    (code
       (mk_api
          (Agent_sdk.Retry.NetworkError
             { message = "x"; kind = Llm_provider.Http_client.Connection_refused })))
;;

let test_timeout () =
  check
    string
    "timeout"
    "api_error_timeout"
    (code (mk_api (Agent_sdk.Retry.Timeout { message = "x" })))
;;

let outcome_code err =
  Masc_mcp.Keeper_execution_receipt.outcome_kind_to_string
    (KAE.receipt_outcome_kind_of_sdk_error err)
;;

let test_timeout_receipt_outcome_is_cancelled () =
  check
    string
    "timeout receipt outcome"
    "cancelled"
    (outcome_code (mk_api (Agent_sdk.Retry.Timeout { message = "x" })))
;;

let test_non_timeout_receipt_outcome_is_error () =
  check
    string
    "auth receipt outcome"
    "error"
    (outcome_code (mk_api (Agent_sdk.Retry.AuthError { message = "x" })))
;;

let test_agent_max_turns_exceeded_receipt_is_cancelled () =
  check
    string
    "max_turns receipt outcome"
    "cancelled"
    (outcome_code
       (Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded { turns = 1; limit = 1 })))
;;

let test_agent_idle_detected_receipt_is_cancelled () =
  check
    string
    "idle_detected receipt outcome"
    "cancelled"
    (outcome_code
       (Agent_sdk.Error.Agent
          (Agent_sdk.Error.IdleDetected { consecutive_idle_turns = 3 })))
;;

let test_agent_exit_condition_met_receipt_is_cancelled () =
  check
    string
    "exit_condition_met receipt outcome"
    "cancelled"
    (outcome_code (Agent_sdk.Error.Agent (Agent_sdk.Error.ExitConditionMet { turn = 5 })))
;;

let test_checkpoint_persistence_error_is_internal_error () =
  let err =
    KAE.checkpoint_persistence_error
      ~keeper_name:"sangsu"
      ~detail:"missing OAS checkpoint after run"
  in
  check string "kind" "internal" (KAE.sdk_error_kind err);
  check string "terminal reason" "internal_error" (code err);
  check string "receipt outcome" "error" (outcome_code err);
  check
    bool
    "message carries stable prefix"
    true
    (String.contains (Agent_sdk.Error.to_string err) ':')
;;

(* Agent variants no longer collapse to a single "agent_error" code.
   Pin the per-variant codes so a future refactor cannot re-collapse
   the enum (memory: no-collapse-richer-enum-at-sdk-boundary). *)

let test_agent_max_turns_exceeded () =
  check
    string
    "max_turns_exceeded"
    "agent_error_max_turns_exceeded:turns=1,limit=1"
    (code (mk_agent (Agent_sdk.Error.MaxTurnsExceeded { turns = 1; limit = 1 })))
;;

let test_agent_exit_condition_met () =
  check
    string
    "exit_condition_met"
    "agent_error_exit_condition_met:turn=5"
    (code (mk_agent (Agent_sdk.Error.ExitConditionMet { turn = 5 })))
;;

let test_agent_unrecognized_stop_reason () =
  check
    string
    "unrecognized_stop_reason"
    "agent_error_unrecognized_stop_reason:bad-stop"
    (code (mk_agent (Agent_sdk.Error.UnrecognizedStopReason { reason = "bad-stop" })))
;;

let test_agent_token_budget_exceeded () =
  check
    string
    "token_budget_exceeded"
    "agent_error_token_budget_exceeded:kind=Input,used=1000,limit=2000"
    (code
       (mk_agent
          (Agent_sdk.Error.TokenBudgetExceeded
             { kind = "Input"; used = 1000; limit = 2000 })))
;;

let test_agent_completion_contract_violation () =
  check
    string
    "completion_contract_violation"
    "completion_contract_violation:require_tool_use"
    (code
       (mk_agent
          (Agent_sdk.Error.CompletionContractViolation
             { contract = Agent_sdk.Completion_contract_id.Require_tool_use
             ; reason = "required tool contract unsatisfied"
             })))
;;

let test_agent_cost_budget_exceeded () =
  check
    string
    "cost_budget_exceeded"
    "agent_error_cost_budget_exceeded:spent_usd=5.50,limit_usd=10.00"
    (code
       (mk_agent
          (Agent_sdk.Error.CostBudgetExceeded { spent_usd = 5.5; limit_usd = 10.0 })))
;;

let test_agent_idle_detected () =
  check
    string
    "idle_detected"
    "agent_error_idle_detected:consecutive_idle_turns=3"
    (code (mk_agent (Agent_sdk.Error.IdleDetected { consecutive_idle_turns = 3 })))
;;

let test_agent_tool_retry_exhausted () =
  check
    string
    "tool_retry_exhausted"
    "agent_error_tool_retry_exhausted:attempts=3,limit=3"
    (code
       (mk_agent
          (Agent_sdk.Error.ToolRetryExhausted
             { attempts = 3; limit = 3; detail = "rate limited" })))
;;

let test_agent_guardrail_violation () =
  check
    string
    "guardrail_violation"
    "agent_error_guardrail_violation:validator=content_filter"
    (code
       (mk_agent
          (Agent_sdk.Error.GuardrailViolation
             { validator = "content_filter"; reason = "toxic" })))
;;

let test_agent_tripwire_violation () =
  check
    string
    "tripwire_violation"
    "agent_error_tripwire_violation:tripwire=disallow_shell"
    (code
       (mk_agent
          (Agent_sdk.Error.TripwireViolation
             { tripwire = "disallow_shell"; reason = "exec detected" })))
;;

(* Non-Agent variants kept their existing codes — guard against accidental
   churn in adjacent branches. *)

let test_non_agent_variants_unchanged () =
  check
    string
    "mcp"
    "mcp_error"
    (code (Agent_sdk.Error.Mcp (Agent_sdk.Error.InitializeFailed { detail = "x" })));
  check
    string
    "config"
    "config_error"
    (code (Agent_sdk.Error.Config (Agent_sdk.Error.MissingEnvVar { var_name = "X" })));
  check
    string
    "io"
    "io_error"
    (code (Agent_sdk.Error.Io (Agent_sdk.Error.ValidationFailed { detail = "x" })));
  check string "internal" "internal_error" (code (Agent_sdk.Error.Internal "x"))
;;

(* No two distinct API variants share a code — that's the whole point.
   Encode it as a property: the 9 returned codes are pairwise distinct. *)

let test_all_api_codes_distinct () =
  let codes =
    [ code (mk_api (Agent_sdk.Retry.RateLimited { retry_after = None; message = "" }))
    ; code (mk_api (Agent_sdk.Retry.Overloaded { message = "" }))
    ; code (mk_api (Agent_sdk.Retry.ServerError { status = 503; message = "" }))
    ; code (mk_api (Agent_sdk.Retry.AuthError { message = "" }))
    ; code (mk_api (Agent_sdk.Retry.InvalidRequest { message = "" }))
    ; code (mk_api (Agent_sdk.Retry.NotFound { message = "" }))
    ; code (mk_api (Agent_sdk.Retry.ContextOverflow { message = ""; limit = None }))
    ; code
        (mk_api
           (Agent_sdk.Retry.NetworkError
              { message = ""; kind = Llm_provider.Http_client.Connection_refused }))
    ; code (mk_api (Agent_sdk.Retry.Timeout { message = "" }))
    ]
  in
  let unique = List.sort_uniq String.compare codes |> List.length in
  check int "9 variants -> 9 distinct codes" 9 unique
;;

(* Same property for Agent variants: 10 distinct codes. *)

let test_all_agent_codes_distinct () =
  let codes =
    [ code
        (mk_agent
           (Agent_sdk.Error.CompletionContractViolation
              { contract = Agent_sdk.Completion_contract_id.Require_tool_use
              ; reason = "x"
              }))
    ; code (mk_agent (Agent_sdk.Error.MaxTurnsExceeded { turns = 1; limit = 1 }))
    ; code (mk_agent (Agent_sdk.Error.ExitConditionMet { turn = 5 }))
    ; code (mk_agent (Agent_sdk.Error.UnrecognizedStopReason { reason = "x" }))
    ; code
        (mk_agent
           (Agent_sdk.Error.TokenBudgetExceeded { kind = "Input"; used = 1; limit = 1 }))
    ; code
        (mk_agent
           (Agent_sdk.Error.CostBudgetExceeded { spent_usd = 1.0; limit_usd = 1.0 }))
    ; code (mk_agent (Agent_sdk.Error.IdleDetected { consecutive_idle_turns = 1 }))
    ; code
        (mk_agent
           (Agent_sdk.Error.ToolRetryExhausted { attempts = 1; limit = 1; detail = "x" }))
    ; code
        (mk_agent (Agent_sdk.Error.GuardrailViolation { validator = "x"; reason = "x" }))
    ; code (mk_agent (Agent_sdk.Error.TripwireViolation { tripwire = "x"; reason = "x" }))
    ]
  in
  let unique = List.sort_uniq String.compare codes |> List.length in
  check int "10 agent variants -> 10 distinct codes" 10 unique
;;

let test_structured_required_tool_no_tool_call () =
  let err =
    Agent_sdk.Error.Agent
      (Agent_sdk.Error.CompletionContractViolation
         { contract = Agent_sdk.Completion_contract_id.Require_tool_use
         ; reason =
             "required tool contract unsatisfied: tool_choice requested tool use, but \
              the model returned no ToolUse block"
         })
  in
  let terminal = KT.of_failure ~raw_error:(Agent_sdk.Error.to_string err) err in
  check string "code" "required_tool_use_no_tool_call" (terminal_code terminal);
  check
    (option string)
    "next action"
    (Some "inspect_provider_tool_contract")
    (terminal_next_action terminal)
;;

let test_structured_oas_timeout_budget () =
  let err =
    Masc_mcp.Keeper_turn_driver.sdk_error_of_masc_internal_error
      (Masc_mcp.Keeper_turn_driver.Oas_timeout_budget
         { budget_sec = 90.0
         ; keeper_turn_timeout_sec = 1200.0
         ; estimated_input_tokens = 10_000
         ; source = "test"
         ; remaining_turn_budget_sec = Some 42.0
         ; min_required_sec = 15.0
         ; phase = "test_phase"
         })
  in
  let terminal = KT.of_failure ~raw_error:(Agent_sdk.Error.to_string err) err in
  check string "code" "oas_timeout_budget" (terminal_code terminal);
  check string "severity" "warn" (KT.severity_to_string (terminal_severity terminal));
  check
    (option string)
    "next action"
    (Some "inspect_timeout_budget")
    (terminal_next_action terminal)
;;

let test_structured_turn_wall_clock_timeout () =
  let err =
    Masc_mcp.Keeper_turn_driver.sdk_error_of_masc_internal_error
      (Masc_mcp.Keeper_turn_driver.Turn_timeout { elapsed_sec = 1200.0 })
  in
  let terminal = KT.of_failure ~raw_error:(Agent_sdk.Error.to_string err) err in
  check string "code" "turn_wall_clock_timeout" (terminal_code terminal)
;;

let test_legacy_gh_worktree_text () =
  let terminal =
    KT.of_legacy_error_text
      "keeper_shell failed: gh_repo_context_missing_worktree: active task has no linked \
       worktree"
  in
  check string "code" "gh_repo_context_missing_worktree" (terminal_code terminal);
  check
    (option string)
    "next action"
    (Some "create_or_link_worktree")
    (terminal_next_action terminal)
;;

let () =
  run
    "keeper_terminal_reason"
    [ ( "api_error variants"
      , [ test_case "RateLimited" `Quick test_rate_limited
        ; test_case "Overloaded" `Quick test_overloaded
        ; test_case "ServerError carries status" `Quick test_server_error_includes_status
        ; test_case "AuthError" `Quick test_auth_error
        ; test_case "InvalidRequest" `Quick test_invalid_request
        ; test_case "NotFound" `Quick test_not_found
        ; test_case "ContextOverflow" `Quick test_context_overflow
        ; test_case "NetworkError" `Quick test_network_error
        ; test_case "Timeout" `Quick test_timeout
        ] )
    ; ( "regression"
      , [ test_case
            "provider timeout receipt outcome -> cancelled"
            `Quick
            test_timeout_receipt_outcome_is_cancelled
        ; test_case
            "non-timeout receipt outcome -> error"
            `Quick
            test_non_timeout_receipt_outcome_is_error
        ; test_case
            "agent max_turns receipt outcome -> cancelled"
            `Quick
            test_agent_max_turns_exceeded_receipt_is_cancelled
        ; test_case
            "agent idle_detected receipt outcome -> cancelled"
            `Quick
            test_agent_idle_detected_receipt_is_cancelled
        ; test_case
            "agent exit_condition_met receipt outcome -> cancelled"
            `Quick
            test_agent_exit_condition_met_receipt_is_cancelled
        ; test_case
            "checkpoint persistence failure is terminal error"
            `Quick
            test_checkpoint_persistence_error_is_internal_error
        ; test_case
            "non-Agent variants unchanged"
            `Quick
            test_non_agent_variants_unchanged
        ; test_case
            "all 9 api codes are pairwise distinct"
            `Quick
            test_all_api_codes_distinct
        ; test_case
            "all 10 agent codes are pairwise distinct"
            `Quick
            test_all_agent_codes_distinct
        ] )
    ; ( "agent_error variants"
      , [ test_case
            "CompletionContractViolation"
            `Quick
            test_agent_completion_contract_violation
        ; test_case "MaxTurnsExceeded" `Quick test_agent_max_turns_exceeded
        ; test_case "ExitConditionMet" `Quick test_agent_exit_condition_met
        ; test_case "UnrecognizedStopReason" `Quick test_agent_unrecognized_stop_reason
        ; test_case "TokenBudgetExceeded" `Quick test_agent_token_budget_exceeded
        ; test_case "CostBudgetExceeded" `Quick test_agent_cost_budget_exceeded
        ; test_case "IdleDetected" `Quick test_agent_idle_detected
        ; test_case "ToolRetryExhausted" `Quick test_agent_tool_retry_exhausted
        ; test_case "GuardrailViolation" `Quick test_agent_guardrail_violation
        ; test_case "TripwireViolation" `Quick test_agent_tripwire_violation
        ] )
    ; ( "structured terminal reason"
      , [ test_case
            "required tool no tool call"
            `Quick
            test_structured_required_tool_no_tool_call
        ; test_case "oas timeout budget" `Quick test_structured_oas_timeout_budget
        ; test_case
            "turn wall-clock timeout"
            `Quick
            test_structured_turn_wall_clock_timeout
        ; test_case "legacy gh missing worktree text" `Quick test_legacy_gh_worktree_text
        ] )
    ]
;;
