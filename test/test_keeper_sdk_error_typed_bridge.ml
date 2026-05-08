(** RFC-0042 PR-2.5 invariant: the typed accessors
    [Keeper_agent_error.terminal_reason_code_of_sdk_error_typed] and
    [Keeper_agent_error.api_error_terminal_reason_code_typed] must
    produce wire bytes byte-for-byte identical to the existing untyped
    string accessors. PR-3 will swap [Keeper_turn_terminal.t.code]
    from [string] to [Keeper_turn_terminal_code.t]; this test guards
    that the swap does not change what dashboards / [bin/masc-trace]
    / Prometheus labels see.

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

let api_cases : (string * SdkE.api_error) list =
  [ "RateLimited", Retry.RateLimited { retry_after = Some 30.0; message = "" }
  ; "Overloaded", Retry.Overloaded { message = "" }
  ; "ServerError", Retry.ServerError { status = 502; message = "" }
  ; "AuthError", Retry.AuthError { message = "" }
  ; "InvalidRequest", Retry.InvalidRequest { message = "bad" }
  ; "NotFound", Retry.NotFound { message = "missing" }
  ; "ContextOverflow", Retry.ContextOverflow { message = "ctx"; limit = Some 8192 }
  ; ( "NetworkError"
    , Retry.NetworkError { message = "ECONNRESET"; kind = Http.Connection_refused } )
  ; "Timeout", Retry.Timeout { message = "60s" }
  ]
;;

(* All variants reached through the top-level dispatcher. *)
let sdk_cases : (string * SdkE.sdk_error) list =
  [ ( "Agent/MaxTurnsExceeded"
    , SdkE.Agent (SdkE.MaxTurnsExceeded { turns = 10; limit = 10 }) )
  ; "Agent/ExitConditionMet", SdkE.Agent (SdkE.ExitConditionMet { turn = 5 })
  ; ( "Agent/UnrecognizedStopReason"
    , SdkE.Agent (SdkE.UnrecognizedStopReason { reason = "abrupt" }) )
  ; ( "Agent/TokenBudgetExceeded"
    , SdkE.Agent (SdkE.TokenBudgetExceeded { kind = "token"; used = 4096; limit = 4096 })
    )
  ; ( "Agent/CostBudgetExceeded"
    , SdkE.Agent (SdkE.CostBudgetExceeded { spent_usd = 0.42; limit_usd = 0.40 }) )
  ; "Agent/IdleDetected", SdkE.Agent (SdkE.IdleDetected { consecutive_idle_turns = 3 })
  ; "Api/Timeout", SdkE.Api (Retry.Timeout { message = "60s" })
  ; "Mcp", SdkE.Mcp (SdkE.InitializeFailed { detail = "boot" })
  ; "Config", SdkE.Config (SdkE.MissingEnvVar { var_name = "X" })
  ; "Serialization", SdkE.Serialization (SdkE.JsonParseError { detail = "syntax" })
  ; "Io", SdkE.Io (SdkE.ValidationFailed { detail = "vfd" })
  ; "Orchestration", SdkE.Orchestration (SdkE.UnknownAgent { name = "ghost" })
  ; "A2a", SdkE.A2a (SdkE.TaskNotFound { task_id = "id" })
  ; "Internal", SdkE.Internal "internal issue"
  ]
;;

let test_api_byte_compat () =
  List.iter
    (fun (label, err) ->
       let expected = AE.api_error_terminal_reason_code err in
       let actual = typed_wire (AE.api_error_terminal_reason_code_typed err) in
       Alcotest.(check string) ("api/" ^ label) expected actual)
    api_cases
;;

let test_sdk_byte_compat () =
  List.iter
    (fun (label, err) ->
       let expected = AE.terminal_reason_code_of_sdk_error err in
       let actual = typed_wire (AE.terminal_reason_code_of_sdk_error_typed err) in
       Alcotest.(check string) ("sdk/" ^ label) expected actual)
    sdk_cases
;;

let () =
  Alcotest.run
    "keeper_sdk_error_typed_bridge"
    [ ( "api_error byte invariant"
      , [ Alcotest.test_case
            "all api_error cases match untyped"
            `Quick
            test_api_byte_compat
        ] )
    ; ( "sdk_error byte invariant"
      , [ Alcotest.test_case
            "all sdk_error cases match untyped"
            `Quick
            test_sdk_byte_compat
        ] )
    ]
;;
