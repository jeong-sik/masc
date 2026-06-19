(** RFC-0042 PR-2.5 invariant: the typed accessors
    [Keeper_agent_error.terminal_reason_code_of_sdk_error_typed] and
    [Keeper_agent_error.api_error_terminal_reason_code_typed] produce
    canonical wire strings byte-for-byte identical to the historical
    untyped output.  PR-3 retired the untyped accessors; this test
    now guards the wire format directly so dashboards /
    [bin/masc-trace] / Otel_metric_store labels do not drift.

    Coverage:
    - all [api_error] variants (RateLimited / Overloaded / ServerError /
      AuthError / InvalidRequest / NotFound / ContextOverflow /
      NetworkError / Timeout)
    - agent_error variants reached via [SdkE.Agent _] routing
    - all top-level non-Agent / non-Api wrappers (Mcp / Config /
      Serialization / Io / Orchestration / Internal) *)

module AE = Masc.Keeper_agent_error
module Code = Masc.Keeper_turn_terminal_code
module EC = Masc.Keeper_error_classify
module KTD = Masc.Keeper_turn_driver
module SdkE = Agent_sdk.Error
module Retry = Agent_sdk.Retry
module Http = Llm_provider.Http_client

let typed_wire t = Code.to_wire t

let api_cases : (string * SdkE.api_error * string) list =
  [ ( "RateLimited"
    , Retry.RateLimited { retry_after = Some 30.0; message = "" }
    , "api_error_rate_limited" )
  ; "Overloaded", Retry.Overloaded { message = "" }, "api_error_overloaded"
  ; ( "ServerError"
    , Retry.ServerError { status = 502; message = "" }
    , "api_error_server:502" )
  ; "AuthError", Retry.AuthError { message = "" }, "api_error_auth"
  ; ( "InvalidRequest"
    , Retry.InvalidRequest { message = "bad" }
    , "api_error_invalid_request" )
  ; "NotFound", Retry.NotFound { message = "missing" }, "api_error_not_found"
  ; ( "ContextOverflow"
    , Retry.ContextOverflow { message = "ctx"; limit = Some 8192 }
    , "api_error_context_overflow" )
  ; ( "NetworkError"
    , Retry.NetworkError { message = "ECONNRESET"; kind = Http.Connection_refused }
    , "api_error_network" )
  ; "Timeout", Retry.Timeout { message = "60s"; phase = None }, "api_error_timeout"
  ; ( "StructuralTimeout"
    , Retry.Timeout
        { message =
            "Turn wall-clock budget exhausted during runtime attempt (budget=554.9s)"
        ; phase = None
        }
    , "api_error_oas_agent_execution_timeout" )
  ]
;;

(* All variants reached through the top-level dispatcher. *)
let sdk_cases : (string * SdkE.sdk_error * string) list =
  [ ( "Agent/MaxTurnsExceeded"
    , SdkE.Agent (SdkE.MaxTurnsExceeded { turns = 10; limit = 10 })
    , "agent_error_max_turns_exceeded:turns=10,limit=10" )
  ; ( "Agent/AgentExecutionTimeout"
    , SdkE.Agent
        (SdkE.AgentExecutionTimeout
           { elapsed_sec = 572.5
           ; timeout_sec = 555.0
           ; turn_count = 24
           ; max_turns = 340
           })
    , "agent_error_execution_timeout:elapsed_sec=572.5,timeout_sec=555.0,turn_count=24,max_turns=340" )
  ; ( "Agent/ExitConditionMet"
    , SdkE.Agent (SdkE.ExitConditionMet { turn = 5 })
    , "agent_error_exit_condition_met:turn=5" )
  ; ( "Agent/UnrecognizedStopReason"
    , SdkE.Agent (SdkE.UnrecognizedStopReason { reason = "abrupt" })
    , "agent_error_unrecognized_stop_reason:abrupt" )
  ; ( "Agent/IdleDetected"
    , SdkE.Agent (SdkE.IdleDetected { consecutive_idle_turns = 3 })
    , "agent_error_idle_detected:consecutive_idle_turns=3" )
  ; ( "Api/Timeout"
    , SdkE.Api (Retry.Timeout { message = "60s"; phase = None })
    , "api_error_timeout" )
  ; "Mcp", SdkE.Mcp (SdkE.InitializeFailed { detail = "boot" }), "mcp_error"
  ; "Config", SdkE.Config (SdkE.MissingEnvVar { var_name = "X" }), "config_error"
  ; ( "Serialization"
    , SdkE.Serialization (SdkE.JsonParseError { detail = "syntax" })
    , "serialization_error" )
  ; "Io", SdkE.Io (SdkE.ValidationFailed { detail = "vfd" }), "io_error"
  ; ( "Orchestration"
    , SdkE.Orchestration (SdkE.UnknownAgent { name = "ghost" })
    , "orchestration_error" )
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

let check_parse_split label err ~provider ~model_ ~server =
  Alcotest.(check bool)
    (label ^ "/provider")
    provider
    (EC.is_provider_rejected_parse_error err);
  Alcotest.(check bool) (label ^ "/model") model_ (EC.is_model_rejected_parse_error err);
  Alcotest.(check bool) (label ^ "/server") server (EC.is_server_rejected_parse_error err)
;;

let test_server_parse_rejection_split () =
  check_parse_split
    "provider_parse_error"
    (SdkE.Provider (Llm_provider.Error.ParseError { detail = "yyjson rejected body" }))
    ~provider:true
    ~model_:false
    ~server:true;
  check_parse_split
    "provider_invalid_request_parse_error"
    (SdkE.Provider
       (Llm_provider.Error.InvalidRequest
          { provider = "claude"; reason = "unexpected character in JSON at byte 9" }))
    ~provider:true
    ~model_:false
    ~server:true;
  check_parse_split
    "api_invalid_request_parse_error"
    (SdkE.Api (Retry.InvalidRequest { message = "unexpected character in JSON at byte 9" }))
    ~provider:false
    ~model_:true
    ~server:true;
  check_parse_split
    "api_invalid_request_generic"
    (SdkE.Api (Retry.InvalidRequest { message = "missing required field: model" }))
    ~provider:false
    ~model_:false
    ~server:false
;;

let test_user_message_of_network_errors () =
  let api_dns =
    SdkE.Api
      (Retry.NetworkError
         { message = "failed to resolve hostname: ollama.com"
         ; kind = Http.Dns_failure
         })
  in
  Alcotest.(check string)
    "api dns user message"
    "Runtime provider unavailable: DNS lookup failed. Check network/DNS or select another runtime. Detail: failed to resolve hostname: ollama.com"
    (AE.user_message_of_sdk_error api_dns);
  Alcotest.(check bool)
    "api dns hides Agent.run prefix"
    false
    (String_util.contains_substring_ci
       (AE.user_message_of_sdk_error api_dns)
       "Agent.run failed");
  let provider_dns =
    SdkE.Provider
      (Llm_provider.Error.NetworkError
         { provider = "ollama_cloud"
         ; kind = Http.Dns_failure
         ; timeout_phase = None
         ; detail = "failed to resolve hostname: ollama.com"
         })
  in
  Alcotest.(check string)
    "provider dns user message"
    "Runtime provider 'ollama_cloud' unavailable: DNS lookup failed. Check network/DNS or select another runtime. Detail: failed to resolve hostname: ollama.com"
    (AE.user_message_of_sdk_error provider_dns);
  let guardrail =
    SdkE.Agent
      (SdkE.GuardrailViolation { validator = "policy"; reason = "blocked" })
  in
  Alcotest.(check string)
    "non-network errors preserve SDK message"
    (Agent_sdk.Error.to_string guardrail)
    (AE.user_message_of_sdk_error guardrail)
;;

let test_ollama_session_limit_is_hard_quota () =
  let message =
    "you (yousleepwhen) have reached your session usage limit, add extra usage: \
     https://ollama.com/settings"
  in
  let err = SdkE.Api (Retry.RateLimited { retry_after = None; message }) in
  Alcotest.(check bool)
    "session usage limit is hard quota"
    true
    (KTD.sdk_error_is_hard_quota err);
  match EC.recoverable_runtime_failure_reason err with
  | Some EC.Hard_quota -> ()
  | Some reason ->
    Alcotest.failf
      "expected hard_quota, got %s"
      (EC.degraded_retry_reason_to_string reason)
  | None -> Alcotest.fail "expected hard_quota recoverable reason"
;;

let test_soft_rate_limit_stays_on_provider_cooldown () =
  let api_err =
    SdkE.Api
      (Retry.RateLimited
         { retry_after = Some 30.0; message = "rate limited, retry later" })
  in
  let provider_err =
    SdkE.Provider
      (Llm_provider.Error.RateLimit
         { provider = "ollama_cloud"
         ; retry_after = Some 30.0
         ; detail = "rate limited, retry later"
         })
  in
  List.iter
    (fun (label, err) ->
       Alcotest.(check bool)
         (label ^ " is not hard quota")
         false
         (KTD.sdk_error_is_hard_quota err);
       Alcotest.(check bool)
         (label ^ " has no degraded rotation reason")
         false
         (Option.is_some (EC.recoverable_runtime_failure_reason err)))
    [ "api", api_err; "provider", provider_err ]
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
    ; ( "server parse rejection split"
      , [ Alcotest.test_case
            "provider and model parse rejections remain distinguishable"
            `Quick
            test_server_parse_rejection_split
        ] )
    ; ( "user-facing error message"
      , [ Alcotest.test_case
            "network errors are presented as runtime availability failures"
            `Quick
            test_user_message_of_network_errors
        ] )
    ; ( "runtime quota guard"
      , [ Alcotest.test_case
            "ollama cloud session usage limit is classified as hard quota"
            `Quick
            test_ollama_session_limit_is_hard_quota
        ; Alcotest.test_case
            "soft rate limits do not trigger degraded runtime rotation"
            `Quick
            test_soft_rate_limit_stays_on_provider_cooldown
        ] )
    ]
;;
