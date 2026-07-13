(* masc#24314 / oas#2585: [Keeper_agent_error.failure_origin_of_sdk_error]
   is the typed classification seam this PR adds — it decides, from the
   OAS [Agent_sdk.Error.sdk_error] value itself (never from string
   matching), whether a keeper_msg turn failure originated at the
   wire-level Api/Provider boundary ([Transport_layer]) or from the
   agent's own execution/config/orchestration outcome ([Agent_layer]).
   Every constructor of [sdk_error] is exercised so a new variant added to
   the SDK forces a compile-time decision here, not a silent default.
   [Api] and [Provider] additionally descend into their nested payload —
   a missing local credential or an agent-authored malformed request is
   [Agent_layer] even though the top-level constructor is [Api]/[Provider],
   because no wire fault occurred (see
   [Keeper_agent_error.api_error_failure_origin] /
   [provider_error_failure_origin] for the full per-variant mapping). *)

open Alcotest
module Keeper_agent_error = Masc.Keeper_agent_error

let check_origin label expected err =
  check
    bool
    label
    true
    (match expected, Keeper_agent_error.failure_origin_of_sdk_error err with
     | Keeper_agent_error.Transport_layer, Keeper_agent_error.Transport_layer
     | Keeper_agent_error.Agent_layer, Keeper_agent_error.Agent_layer -> true
     | (Keeper_agent_error.Transport_layer | Keeper_agent_error.Agent_layer), _ ->
       false)
;;

let test_api_is_transport_layer () =
  check_origin
    "Api is Transport_layer"
    Keeper_agent_error.Transport_layer
    (Agent_sdk.Error.Api
       (Agent_sdk.Retry.RateLimited { retry_after = None; message = "rate limited" }))
;;

(* Contradiction fix: a missing local credential means no request ever
   reached the wire, so this must not classify the same as a genuine
   transport failure (was wrongly Transport_layer prior to this PR). *)
let test_provider_missing_api_key_is_agent_layer () =
  check_origin
    "Provider(MissingApiKey) is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Provider
       (Llm_provider.Error.MissingApiKey { var_name = "OPENAI_API_KEY" }))
;;

let test_provider_rate_limit_is_transport_layer () =
  check_origin
    "Provider(RateLimit) is Transport_layer"
    Keeper_agent_error.Transport_layer
    (Agent_sdk.Error.Provider
       (Llm_provider.Error.RateLimit
          { provider = "openai"; retry_after = None; detail = "rate limited" }))
;;

let test_api_context_overflow_is_agent_layer () =
  check_origin
    "Api(ContextOverflow) is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Api
       (Agent_sdk.Retry.ContextOverflow { message = "context too large"; limit = None }))
;;

let test_api_invalid_request_is_agent_layer () =
  check_origin
    "Api(InvalidRequest) is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Api
       (Agent_sdk.Retry.InvalidRequest
          { message = "bad payload"; reason = Agent_sdk.Retry.Unknown_invalid_request }))
;;

(* NotFound reached us as a definitive wire rejection (the provider told
   us the resource doesn't exist), unlike InvalidRequest/ContextOverflow
   which never leave agent-local territory --
   Keeper_runtime_failure_route.route_of_provider_error groups this with
   [rotate Model_unavailable], the same bucket as AuthError. *)
let test_provider_not_found_is_transport_layer () =
  check_origin
    "Provider(NotFound) is Transport_layer"
    Keeper_agent_error.Transport_layer
    (Agent_sdk.Error.Provider
       (Llm_provider.Error.NotFound { provider = "openai"; detail = "model not found" }))
;;

(* The exact case from the real incident (masc#24314 RCA): OAS's
   [ToolFailureRecoveryFailed] is an agent-side outcome, not a transport
   problem, and must not classify as [Transport_layer]. *)
let test_tool_failure_recovery_failed_is_agent_layer () =
  check_origin
    "Agent(ToolFailureRecoveryFailed) is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Agent
       (Agent_sdk.Error.ToolFailureRecoveryFailed
          { stage = Agent_sdk.Error.Judge_response; detail = "judge unreachable" }))
;;

let test_agent_other_variant_is_agent_layer () =
  check_origin
    "Agent(MaxTurnsExceeded) is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded { turns = 40; limit = 40 }))
;;

let test_mcp_is_agent_layer () =
  check_origin
    "Mcp is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Mcp
       (Agent_sdk.Error.ToolCallFailed { tool_name = "keeper_board_list"; detail = "boom" }))
;;

let test_config_is_agent_layer () =
  check_origin
    "Config is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Config (Agent_sdk.Error.MissingEnvVar { var_name = "MASC_BASE_PATH" }))
;;

let test_serialization_is_agent_layer () =
  check_origin
    "Serialization is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Serialization (Agent_sdk.Error.JsonParseError { detail = "bad json" }))
;;

let test_io_is_agent_layer () =
  check_origin
    "Io is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Io
       (Agent_sdk.Error.FileOpFailed { op = "read"; path = "/tmp/x"; detail = "ENOENT" }))
;;

let test_orchestration_is_agent_layer () =
  check_origin
    "Orchestration is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Orchestration (Agent_sdk.Error.UnknownAgent { name = "ghost" }))
;;

let test_internal_is_agent_layer () =
  check_origin
    "Internal is Agent_layer"
    Keeper_agent_error.Agent_layer
    (Agent_sdk.Error.Internal "unexpected internal state")
;;

let () =
  run
    "keeper_agent_error"
    [ ( "failure_origin_of_sdk_error"
      , [ test_case "Api -> Transport_layer" `Quick test_api_is_transport_layer
        ; test_case
            "Provider(MissingApiKey) -> Agent_layer"
            `Quick
            test_provider_missing_api_key_is_agent_layer
        ; test_case
            "Provider(RateLimit) -> Transport_layer"
            `Quick
            test_provider_rate_limit_is_transport_layer
        ; test_case
            "Api(ContextOverflow) -> Agent_layer"
            `Quick
            test_api_context_overflow_is_agent_layer
        ; test_case
            "Api(InvalidRequest) -> Agent_layer"
            `Quick
            test_api_invalid_request_is_agent_layer
        ; test_case
            "Provider(NotFound) -> Transport_layer"
            `Quick
            test_provider_not_found_is_transport_layer
        ; test_case
            "Agent(ToolFailureRecoveryFailed) -> Agent_layer"
            `Quick
            test_tool_failure_recovery_failed_is_agent_layer
        ; test_case
            "Agent(MaxTurnsExceeded) -> Agent_layer"
            `Quick
            test_agent_other_variant_is_agent_layer
        ; test_case "Mcp -> Agent_layer" `Quick test_mcp_is_agent_layer
        ; test_case "Config -> Agent_layer" `Quick test_config_is_agent_layer
        ; test_case "Serialization -> Agent_layer" `Quick test_serialization_is_agent_layer
        ; test_case "Io -> Agent_layer" `Quick test_io_is_agent_layer
        ; test_case "Orchestration -> Agent_layer" `Quick test_orchestration_is_agent_layer
        ; test_case "Internal -> Agent_layer" `Quick test_internal_is_agent_layer
        ] )
    ]
;;
