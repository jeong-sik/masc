(** RFC-0042 PR-2.5 invariant: the typed accessors
    [Keeper_agent_error.terminal_reason_code_of_sdk_error_typed] and
    [Keeper_agent_error.api_error_terminal_reason_code_typed] produce
    canonical wire strings byte-for-byte identical to the historical
    untyped output.  PR-3 retired the untyped accessors; this test
    now guards the wire format directly so dashboards /
    [bin/masc-trace] / Prometheus labels do not drift.

    Coverage:
    - all 9 [api_error] variants (RateLimited / Overloaded / ServerError /
      AuthError / InvalidRequest / NotFound / ContextOverflow /
      NetworkError / Timeout)
    - all 9 [agent_error] variants reached via [SdkE.Agent _] routing
    - all 7 top-level non-Agent / non-Api wrappers (Mcp / Config /
      Serialization / Io / Orchestration / A2a / Internal) *)

module AE = Masc_mcp.Keeper_agent_error
module Code = Masc_mcp.Keeper_turn_terminal_code
module SdkE = Agent_sdk.Error
module Retry = Agent_sdk.Retry
module Http = Llm_provider.Http_client

let typed_wire t = Code.to_wire t

let api_cases : (string * SdkE.api_error * string) list =
  [ "RateLimited", Retry.RateLimited { retry_after = Some 30.0; message = "" }, "api_error_rate_limited"
  ; "Overloaded", Retry.Overloaded { message = "" }, "api_error_overloaded"
  ; "ServerError", Retry.ServerError { status = 502; message = "" }, "api_error_server:502"
  ; "AuthError", Retry.AuthError { message = "" }, "api_error_auth"
  ; "InvalidRequest", Retry.InvalidRequest { message = "bad" }, "api_error_invalid_request"
  ; "NotFound", Retry.NotFound { message = "missing" }, "api_error_not_found"
  ; "ContextOverflow", Retry.ContextOverflow { message = "ctx"; limit = Some 8192 }, "api_error_context_overflow"
  ; ( "NetworkError"
    , Retry.NetworkError { message = "ECONNRESET"; kind = Http.Connection_refused }
    , "api_error_network" )
  ; "Timeout", Retry.Timeout { message = "60s" }, "api_error_timeout"
  ]
;;

(* All variants reached through the top-level dispatcher. *)
let sdk_cases : (string * SdkE.sdk_error * string) list =
  [ ( "Agent/MaxTurnsExceeded"
    , SdkE.Agent (SdkE.MaxTurnsExceeded { turns = 10; limit = 10 })
    , "agent_error_max_turns_exceeded:turns=10,limit=10" )
  ; ( "Agent/ExitConditionMet"
    , SdkE.Agent (SdkE.ExitConditionMet { turn = 5 })
    , "agent_error_exit_condition_met:turn=5" )
  ; ( "Agent/UnrecognizedStopReason"
    , SdkE.Agent (SdkE.UnrecognizedStopReason { reason = "abrupt" })
    , "agent_error_unrecognized_stop_reason:abrupt" )
  ; ( "Agent/TokenBudgetExceeded"
    , SdkE.Agent (SdkE.TokenBudgetExceeded { kind = "token"; used = 4096; limit = 4096 })
    , "agent_error_token_budget_exceeded:kind=token,used=4096,limit=4096" )
  ; ( "Agent/CostBudgetExceeded"
    , SdkE.Agent (SdkE.CostBudgetExceeded { spent_usd = 0.42; limit_usd = 0.40 })
    , "agent_error_cost_budget_exceeded:spent_usd=0.42,limit_usd=0.40" )
  ; ( "Agent/IdleDetected"
    , SdkE.Agent (SdkE.IdleDetected { consecutive_idle_turns = 3 })
    , "agent_error_idle_detected:consecutive_idle_turns=3" )
  ; "Api/Timeout", SdkE.Api (Retry.Timeout { message = "60s" }), "api_error_timeout"
  ; "Mcp", SdkE.Mcp (SdkE.InitializeFailed { detail = "boot" }), "mcp_error"
  ; "Config", SdkE.Config (SdkE.MissingEnvVar { var_name = "X" }), "config_error"
  ; "Serialization", SdkE.Serialization (SdkE.JsonParseError { detail = "syntax" }), "serialization_error"
  ; "Io", SdkE.Io (SdkE.ValidationFailed { detail = "vfd" }), "io_error"
  ; "Orchestration", SdkE.Orchestration (SdkE.UnknownAgent { name = "ghost" }), "orchestration_error"
  ; "A2a", SdkE.A2a (SdkE.TaskNotFound { task_id = "id" }), "a2a_error"
  ; "Internal", SdkE.Internal "internal issue", "internal_error"
  ]
;;

let test_api_typed_wire () =
  List.iter
    (fun (label, err, expected) ->
       let actual = typed_wire (AE.api_error_terminal_reason_code_typed err) in
       Alcotest.(check string) ("api/" ^ label) expected actual)
    api_cases
;;

let test_sdk_typed_wire () =
  List.iter
    (fun (label, err, expected) ->
       let actual = typed_wire (AE.terminal_reason_code_of_sdk_error_typed err) in
       Alcotest.(check string) ("sdk/" ^ label) expected actual)
    sdk_cases
;;

let () =
  Alcotest.run
    "keeper_sdk_error_typed_bridge"
    [ ( "api_error wire invariant"
      , [ Alcotest.test_case
            "all api_error cases produce expected wire"
            `Quick
            test_api_typed_wire
        ] )
    ; ( "sdk_error wire invariant"
      , [ Alcotest.test_case
            "all sdk_error cases produce expected wire"
            `Quick
            test_sdk_typed_wire
        ] )
    ]
;;
