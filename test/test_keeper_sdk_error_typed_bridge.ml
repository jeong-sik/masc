(** RFC-0042 PR-2.5 invariant: the typed accessors
    [Keeper_agent_error.terminal_reason_code_of_sdk_error_typed] and
    [Keeper_agent_error.api_error_terminal_reason_code_typed] produce
    canonical wire strings byte-for-byte identical to the historical
    untyped output.  PR-3 retired the untyped accessors; this test
    now guards the wire format directly so dashboards /
    [bin/masc-trace] / Otel_metric_store labels do not drift.

    Coverage:
    - all [api_error] variants (RateLimited / Overloaded / ServerError /
      AuthError / AuthorizationError / PaymentRequired / InvalidRequest /
      NotFound / ContextOverflow / NetworkError / Timeout)
    - agent_error variants reached via [SdkE.Agent _] routing
    - all top-level non-Agent / non-Api wrappers (Mcp / Config /
      Serialization / Io / Orchestration / Internal) *)

module AE = Masc.Keeper_agent_error
module Code = Masc.Keeper_turn_terminal_code
module EC = Masc.Keeper_error_classify
module KTD = Masc.Keeper_turn_driver
module RC = Runtime_candidate
module SdkE = Agent_sdk.Error
module Retry = Agent_sdk.Retry
module Http = Llm_provider.Http_client

let typed_wire t = Code.to_wire t
let unknown_invalid_request message =
  Retry.InvalidRequest
    { message; reason = Retry.Unknown_invalid_request }

let api_cases : (string * SdkE.api_error * string) list =
  [ ( "RateLimited"
    , Retry.RateLimited { retry_after = Some 30.0; message = "" }
    , "api_error_rate_limited" )
  ; "Overloaded", Retry.Overloaded { message = "" }, "api_error_overloaded"
  ; ( "ServerError"
    , Retry.ServerError { status = 502; message = "" }
    , "api_error_server:502" )
  ; "AuthError", Retry.AuthError { message = "" }, "api_error_auth"
  ; ( "AuthorizationError"
    , Retry.AuthorizationError { message = "permission refused" }
    , "api_error_authorization" )
  ; ( "PaymentRequired"
    , Retry.PaymentRequired { message = "billing required" }
    , "api_error_payment_required" )
  ; ( "InvalidRequest"
    , unknown_invalid_request "bad"
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
  ; ( "Api/AuthorizationError"
    , SdkE.Api (Retry.AuthorizationError { message = "permission refused" })
    , "api_error_authorization" )
  ; ( "Provider/AuthorizationError"
    , SdkE.Provider
        (Llm_provider.Error.AuthorizationError
           { provider = "provider"; detail = "permission refused" })
    , "provider_error_authorization" )
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

let test_idle_detected_receipt_is_failure () =
  let outcome =
    AE.receipt_outcome_kind_of_sdk_error
      (SdkE.Agent (SdkE.IdleDetected { consecutive_idle_turns = 3 }))
  in
  Alcotest.(check string)
    "IdleDetected is not cancellation"
    "error"
    (Masc.Keeper_execution_receipt.outcome_kind_to_string outcome)
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
    "provider_invalid_request_json_message_is_not_typed_parse_error"
    (SdkE.Provider
       (Llm_provider.Error.InvalidRequest
          { provider = "claude"; reason = "unexpected character in JSON at byte 9" }))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_json_message_is_not_typed_parse_error"
    (SdkE.Api (unknown_invalid_request "unexpected character in JSON at byte 9"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "provider_invalid_request_yyjson_message_is_not_typed_parse_error"
    (SdkE.Provider
       (Llm_provider.Error.InvalidRequest
          { provider = "ollama"
          ; reason = "yyjson parse error: unexpected token at byte 9"
          }))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_json_parse_message_is_not_typed_parse_error"
    (SdkE.Api (unknown_invalid_request "JSON parse error at byte 9"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_xml_parse_error"
    (SdkE.Api (unknown_invalid_request "XML parse error at line 3"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "provider_invalid_request_invalid_json_is_not_typed_parse_error"
    (SdkE.Provider
       (Llm_provider.Error.InvalidRequest
          { provider = "claude"; reason = "invalid json in tool call arguments" }))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_invalid_json_is_not_typed_parse_error"
    (SdkE.Api (unknown_invalid_request "invalid json in tool call arguments"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_query_parse_error"
    (SdkE.Api (unknown_invalid_request "parse error in query parameters"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_cant_find_tool"
    (SdkE.Api (unknown_invalid_request "Can't find the specified tool"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_generic"
    (SdkE.Api (unknown_invalid_request "missing required field: model"))
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

let test_user_message_of_masc_accept_rejected () =
  let err =
    KTD.sdk_error_of_masc_internal_error
      (KTD.Accept_rejected
         { scope = "runpod_fable5.gemma4-coder-fable5"
         ; model = None
         ; reason_kind = Some KTD.Accept_no_usable_progress
         ; response_shape = Some KTD.Accept_response_empty
         ; stop_reason = None
         ; last_tool_effect = None
         ; any_mutating_tool = None
         ; tool_effects_seen = []
         ; reason =
             "response rejected by accept (runtime=runpod_fable5.gemma4-coder-fable5): \
              shape=empty; stop_reason=end_turn"
         })
  in
  let message = AE.user_message_of_sdk_error err in
  Alcotest.(check string)
    "accept rejection user message"
    "Provider returned an empty assistant turn for runtime runpod_fable5.gemma4-coder-fable5; no text or tool progress was produced."
    message;
  Alcotest.(check bool)
    "message hides SDK internal wrapper"
    false
    (String_util.contains_substring_ci message "Internal error");
  Alcotest.(check bool)
    "message hides structured payload prefix"
    false
    (String_util.contains_substring_ci message "[masc_oas_error]")
;;

let test_quota_prose_does_not_override_typed_rate_limit () =
  let message =
    "you (yousleepwhen) have reached your session usage limit, add extra usage: \
     https://ollama.com/settings"
  in
  let err = SdkE.Api (Retry.RateLimited { retry_after = None; message }) in
  Alcotest.(check bool)
    "provider prose does not invent hard quota"
    false
    (KTD.sdk_error_is_hard_quota err);
  match EC.recoverable_runtime_failure_reason err with
  | Some EC.Rate_limit -> ()
  | Some reason ->
    Alcotest.failf
      "expected typed rate_limit, got %s"
      (EC.degraded_retry_reason_to_string reason)
  | None -> Alcotest.fail "expected rate_limit recoverable reason"
;;

let test_payment_required_is_hard_quota () =
  let err = SdkE.Api (Retry.PaymentRequired { message = "Insufficient Balance" }) in
  Alcotest.(check bool)
    "payment required is hard quota"
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

(* Regression: a transient Overloaded (529/CapacityExhausted) whose prose
   coincidentally contains a hard-quota indicator must NOT be classified as hard
   quota. The typed variant already says transient; the message scan previously
   overrode it to permanent (immediate pool-wide 1h cooldown). Fails PRE-fix
   (true), passes POST-fix (false). *)
let test_overloaded_with_quota_prose_is_not_hard_quota () =
  let message =
    "You have exhausted your capacity on this model. Your quota will reset after \
     4h41m7s. reason=QUOTA_EXHAUSTED"
  in
  let err = SdkE.Api (Retry.Overloaded { message }) in
  Alcotest.(check bool)
    "transient overload with quota prose is not hard quota"
    false
    (KTD.sdk_error_is_hard_quota err)
;;

(* Deleting the month-hardcoded "resets apr " indicator loses no coverage: the
   real signal is carried by the month-agnostic "you've hit your limit" /
   "monthly usage limit" indicators. This also fixes the 11-months-of-the-year
   false negative the April literal caused. *)
let test_soft_rate_limit_classifies_as_rate_limit () =
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
       match EC.recoverable_runtime_failure_reason err with
       | Some EC.Rate_limit -> ()
       | Some reason ->
         Alcotest.failf
           "%s expected rate_limit, got %s"
           label
           (EC.degraded_retry_reason_to_string reason)
      | None -> Alcotest.failf "%s expected rate_limit recoverable reason" label)
    [ "api", api_err; "provider", provider_err ]
;;

let classification_to_string = function
  | EC.Transient_network -> "transient_network"
  | EC.Transient_internal_runner -> "transient_internal_runner"
  | EC.Transient_oas_timeout -> "transient_oas_timeout"
  | EC.Transient_rate_limit -> "transient_rate_limit"
  | EC.Transient_capacity -> "transient_capacity"
  | EC.Non_transient -> "non_transient"
  | EC.Unclassified -> "unclassified"
;;

let check_classification label expected err =
  Alcotest.(check string)
    label
    (classification_to_string expected)
    (classification_to_string (EC.classify_error err))
;;

let runtime_runner_tls_error () =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Internal_unhandled_exception
       { site = KTD.runtime_runner_execute_site
       ; exn_repr = "TLS alert from peer: handshake failure"
       ; transport_error_kind = Some Http.Tls_error
       })
;;

let runtime_runner_legacy_tls_text_error () =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Internal_unhandled_exception
       { site = KTD.runtime_runner_execute_site
       ; exn_repr = "TLS alert from peer: handshake failure"
       ; transport_error_kind = None
       })
;;

let test_static_error_classification_preserves_retry_semantics () =
  let structural_timeout =
    "Turn wall-clock budget exhausted during runtime attempt (budget=554.9s)"
  in
  check_classification
    "api network"
    EC.Transient_network
    (SdkE.Api
       (Retry.NetworkError
          { message = "connection refused"; kind = Http.Connection_refused }));
  check_classification
    "api structural timeout"
    EC.Transient_oas_timeout
    (SdkE.Api (Retry.Timeout { message = structural_timeout; phase = None }));
  check_classification
    "api transport timeout"
    EC.Transient_network
    (SdkE.Api (Retry.Timeout { message = "read timed out"; phase = None }));
  check_classification
    "internal runner tls"
    EC.Transient_internal_runner
    (runtime_runner_tls_error ());
  check_classification
    "legacy internal runner tls text is not parsed"
    EC.Unclassified
    (runtime_runner_legacy_tls_text_error ());
  check_classification
    "api overloaded"
    EC.Transient_capacity
    (SdkE.Api (Retry.Overloaded { message = "capacity exhausted" }));
  check_classification
    "api server 503"
    EC.Transient_network
    (SdkE.Api (Retry.ServerError { status = 503; message = "unavailable" }));
  check_classification
    "api server 522"
    EC.Transient_network
    (SdkE.Api (Retry.ServerError { status = 522; message = "origin timeout" }));
  check_classification
    "api server 500"
    EC.Non_transient
    (SdkE.Api (Retry.ServerError { status = 500; message = "server error" }));
  check_classification
    "provider tls"
    EC.Non_transient
    (SdkE.Provider
       (Llm_provider.Error.NetworkError
          { provider = "p"
          ; kind = Http.Tls_error
          ; timeout_phase = None
          ; detail = "tls failed"
          }));
  check_classification
    "provider timeout structural"
    EC.Transient_oas_timeout
    (SdkE.Provider
       (Llm_provider.Error.Timeout
          { provider = "p"; timeout_phase = None; detail = structural_timeout }));
  check_classification
    "provider server 524"
    EC.Transient_network
    (SdkE.Provider
       (Llm_provider.Error.ServerError
          { provider = "p"; code = 524; transient = false; detail = "timeout" }));
  check_classification
    "provider server transient"
    EC.Transient_network
    (SdkE.Provider
       (Llm_provider.Error.ServerError
          { provider = "p"; code = 500; transient = true; detail = "retryable" }));
  check_classification
    "provider server terminal"
    EC.Non_transient
    (SdkE.Provider
       (Llm_provider.Error.ServerError
          { provider = "p"; code = 500; transient = false; detail = "terminal" }));
  check_classification
    "api rate limit"
    EC.Transient_rate_limit
    (SdkE.Api (Retry.RateLimited { retry_after = Some 30.0; message = "slow down" }));
  check_classification
    "provider rate limit"
    EC.Transient_rate_limit
    (SdkE.Provider
       (Llm_provider.Error.RateLimit
          { provider = "p"; retry_after = Some 30.0; detail = "slow down" }));
  check_classification
    "provider capacity"
    EC.Transient_capacity
    (SdkE.Provider
       (Llm_provider.Error.CapacityExhausted
          { scope = Llm_provider.Error.CapacityModel
          ; affected = [ "p:m" ]
          ; retry_after = Some 10.0
          ; detail = "capacity"
          }));
  check_classification
    "provider hard quota"
    EC.Non_transient
    (SdkE.Provider
       (Llm_provider.Error.HardQuota
          { provider = "p"; retry_after = None; detail = "billing required" }));
  check_classification
    "unknown variant"
    EC.Unclassified
    (SdkE.Provider
       (Llm_provider.Error.UnknownVariant { type_name = "provider"; value = "new" }))
;;

let rate_limit_pool_of_runtime_id = function
  | "same.a"
  | "same.b" -> Some "pool:same"
  | "other.c" -> Some "pool:other"
  | _ -> Some "pool:same"
;;

let with_temp_runtime_toml content f =
  let path = Filename.temp_file "runtime-rate-limit-pool" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () -> f path)
;;

let rate_limit_pool_runtime_toml =
  {|
[runtime]
default = "same.a"

[providers.same]
display-name = "Same Pool"
protocol = "openai-compatible-http"
endpoint = "https://same.example/v1"

[providers.same.credentials]
type = "env"
key = "SAME_POOL_API_KEY"

[providers.other]
display-name = "Other Pool"
protocol = "openai-compatible-http"
endpoint = "https://other.example/v1"

[providers.other.credentials]
type = "env"
key = "OTHER_POOL_API_KEY"

[models.a]
api-name = "a"
max-context = 1024
tools-support = true
thinking-support = true

[models.no_tool]
api-name = "no-tool"
max-context = 1024
tools-support = false
thinking-support = true

[models.b]
api-name = "b"
max-context = 1024
tools-support = true
thinking-support = true

[models.c]
api-name = "c"
max-context = 1024
tools-support = true
thinking-support = true

[same.a]

[same.no_tool]

[same.b]

[other.c]
|}
;;

let init_rate_limit_pool_runtime () =
  with_temp_runtime_toml rate_limit_pool_runtime_toml (fun path ->
    match Runtime.init_default ~config_path:path with
    | Ok () -> ()
    | Error msg -> Alcotest.failf "Runtime.init_default failed: %s" msg)
;;

let soft_rate_limit_err =
  SdkE.Api
    (Retry.RateLimited
       { retry_after = Some 30.0; message = "rate limited, retry later" })
;;

let hard_quota_err =
  SdkE.Provider
    (Llm_provider.Error.HardQuota
       { provider = "typed-provider"
       ; retry_after = None
       ; detail = "typed quota exhaustion"
       })
;;

let server_error_500 =
  SdkE.Api
    (Retry.ServerError { status = 500; message = "Internal Server Error" })
;;

let provider_unavailable =
  SdkE.Provider
    (Llm_provider.Error.ProviderUnavailable
       { provider = "server-error-test"; detail = "HTTP 503 retry-after exhausted" })
;;

let read_only_no_progress_err ~scope =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Accept_rejected
       { scope
       ; model = None
       ; reason_kind = Some KTD.Accept_no_usable_progress
       ; response_shape = Some KTD.Accept_response_thinking_only
       ; stop_reason = None
       ; last_tool_effect = Some KTD.Tool_effect_read_only
       ; any_mutating_tool = Some false
       ; tool_effects_seen = [ KTD.Tool_effect_read_only ]
       ; reason =
           "response rejected by accept (runtime=same.b): shape=thinking_only; \
            stop_reason=end_turn; last_tool=WebFetch; last_tool_effect=read_only"
       })
;;

let generic_accept_rejected_err ~scope =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Accept_rejected
       { scope
       ; model = None
       ; reason_kind = Some KTD.Accept_predicate_rejected
       ; response_shape = Some KTD.Accept_response_mixed_without_deliverable_content
       ; stop_reason = None
       ; last_tool_effect = None
       ; any_mutating_tool = Some false
       ; tool_effects_seen = []
       ; reason =
           "response rejected by accept: predicate failed without accepted \
            deliverable content"
       })
;;

let test_generic_accept_rejected_is_not_locally_recoverable () =
  let err = generic_accept_rejected_err ~scope:"same.a" in
  match EC.recoverable_runtime_failure_reason err with
  | None -> ()
  | Some reason ->
    Alcotest.failf
      "generic accept rejection should not be recoverable, got %s"
      (EC.degraded_retry_reason_to_string reason)
;;

let test_read_only_no_progress_remains_recoverable_not_contract () =
  let err = read_only_no_progress_err ~scope:"same.a" in
  match EC.recoverable_runtime_failure_reason err with
  | Some EC.Read_only_no_progress -> ()
  | Some reason ->
    Alcotest.failf
      "expected read_only_no_progress, got %s"
      (EC.degraded_retry_reason_to_string reason)
  | None -> Alcotest.fail "expected read_only_no_progress recoverable reason"
;;

let test_soft_rate_limit_skips_same_credential_pool () =
  init_rate_limit_pool_runtime ();
  let retry =
    EC.degraded_rotation_after_recoverable_error
      ~credential_pool_of_runtime_id:rate_limit_pool_of_runtime_id
      ~fallback_hint:"same.b"
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:[ "same.a" ]
      soft_rate_limit_err
  in
  Alcotest.(check bool)
    "same credential pool is not a rotation target"
    false
    (Option.is_some retry)
;;

let test_soft_rate_limit_preserves_independent_pool_failover () =
  init_rate_limit_pool_runtime ();
  match
    EC.degraded_rotation_after_recoverable_error
      ~credential_pool_of_runtime_id:rate_limit_pool_of_runtime_id
      ~fallback_hint:"other.c"
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:[ "same.a" ]
      soft_rate_limit_err
  with
  | Some { EC.next_runtime; fallback_reason = EC.Rate_limit } ->
    Alcotest.(check string)
      "independent credential pool remains eligible"
      "other.c"
      next_runtime
  | Some { fallback_reason; next_runtime } ->
    Alcotest.failf
      "expected rate_limit -> other.c, got %s -> %s"
      (EC.degraded_retry_reason_to_string fallback_reason)
      next_runtime
  | None -> Alcotest.fail "expected independent credential pool failover"
;;

let test_hard_quota_skips_same_credential_pool () =
  init_rate_limit_pool_runtime ();
  let retry =
    EC.degraded_rotation_after_recoverable_error
      ~credential_pool_of_runtime_id:rate_limit_pool_of_runtime_id
      ~fallback_hint:"same.b"
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:[ "same.a" ]
      hard_quota_err
  in
  Alcotest.(check bool)
    "hard quota does not fan out to the same credential pool"
    false
    (Option.is_some retry)
;;

let test_hard_quota_preserves_independent_pool_failover () =
  init_rate_limit_pool_runtime ();
  match
    EC.degraded_rotation_after_recoverable_error
      ~credential_pool_of_runtime_id:rate_limit_pool_of_runtime_id
      ~fallback_hint:"other.c"
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:[ "same.a" ]
      hard_quota_err
  with
  | Some { EC.next_runtime; fallback_reason = EC.Hard_quota } ->
    Alcotest.(check string)
      "independent credential pool remains eligible"
      "other.c"
      next_runtime
  | Some { fallback_reason; next_runtime } ->
    Alcotest.failf
      "expected hard_quota -> other.c, got %s -> %s"
      (EC.degraded_retry_reason_to_string fallback_reason)
      next_runtime
  | None -> Alcotest.fail "expected independent credential pool failover"
;;

let test_server_error_classifies_as_runtime_recoverable () =
  Alcotest.(check bool)
    "500 is not same-runtime transient retry"
    false
    (EC.is_transient_network_error server_error_500);
  match EC.recoverable_runtime_failure_reason server_error_500 with
  | Some EC.Server_error -> ()
  | Some reason ->
    Alcotest.failf
      "expected server_error, got %s"
      (EC.degraded_retry_reason_to_string reason)
  | None -> Alcotest.fail "expected server_error recoverable reason"
;;

let test_read_only_no_progress_rotates_to_default_runtime () =
  init_rate_limit_pool_runtime ();
  let err = read_only_no_progress_err ~scope:"same.b" in
  (match EC.recoverable_runtime_failure_reason err with
   | Some EC.Read_only_no_progress -> ()
   | Some reason ->
     Alcotest.failf
       "expected read_only_no_progress, got %s"
       (EC.degraded_retry_reason_to_string reason)
   | None -> Alcotest.fail "expected read_only_no_progress recoverable reason");
  match
    EC.degraded_rotation_after_recoverable_error
      ~base_runtime:"same.b"
      ~effective_runtime:"same.b"
      ~attempted_runtimes:[ "same.b" ]
      err
  with
  | Some { EC.next_runtime = "same.a"; fallback_reason = EC.Read_only_no_progress } ->
    ()
  | Some { next_runtime; fallback_reason } ->
    Alcotest.failf
      "expected read_only_no_progress -> same.a, got %s -> %s"
      (EC.degraded_retry_reason_to_string fallback_reason)
      next_runtime
  | None -> Alcotest.fail "expected read-only no-progress rotation"
;;

let test_read_only_no_progress_default_runtime_uses_tool_capable_candidate () =
  init_rate_limit_pool_runtime ();
  let err = read_only_no_progress_err ~scope:"same.a" in
  match
    EC.degraded_rotation_after_recoverable_error
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:[ "same.a" ]
      err
  with
  | Some { EC.next_runtime = "same.b"; fallback_reason = EC.Read_only_no_progress } ->
    ()
  | Some { next_runtime; fallback_reason } ->
    Alcotest.failf
      "expected read_only_no_progress -> same.b, got %s -> %s"
      (EC.degraded_retry_reason_to_string fallback_reason)
      next_runtime
  | None ->
    Alcotest.fail "expected read-only no-progress to rotate to a tool-capable runtime"
;;

let test_rate_limit_exhaustion_stops_after_candidate_pass () =
  init_rate_limit_pool_runtime ();
  let attempted = [ "same.a"; "same.b"; "other.c" ] in
  match
    EC.degraded_rotation_after_recoverable_error
      ~credential_pool_of_runtime_id:rate_limit_pool_of_runtime_id
      ~fallback_hint:"other.c"
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:attempted
      soft_rate_limit_err
  with
  | None -> ()
  | Some { EC.next_runtime; _ } ->
    Alcotest.failf
      "an exhausted candidate pass must not invent another cycle, got %s"
      next_runtime
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
        ; Alcotest.test_case
            "IdleDetected receipt remains a failure"
            `Quick
            test_idle_detected_receipt_is_failure
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
        ; Alcotest.test_case
            "structured accept rejection is presented without internal wrapper"
            `Quick
            test_user_message_of_masc_accept_rejected
        ] )
    ; ( "runtime quota guard"
      , [ Alcotest.test_case
            "quota prose does not override typed rate limit"
            `Quick
            test_quota_prose_does_not_override_typed_rate_limit
        ; Alcotest.test_case
            "soft rate limits remain rate_limit reasons"
            `Quick
            test_soft_rate_limit_classifies_as_rate_limit
        ; Alcotest.test_case
            "static error classification preserves retry semantics"
            `Quick
            test_static_error_classification_preserves_retry_semantics
        ; Alcotest.test_case
            "payment required is classified as hard quota"
            `Quick
            test_payment_required_is_hard_quota
        ; Alcotest.test_case
            "transient overload with quota prose is not hard quota"
            `Quick
            test_overloaded_with_quota_prose_is_not_hard_quota
        ; Alcotest.test_case
            "soft rate limits skip same credential-pool candidates"
            `Quick
            test_soft_rate_limit_skips_same_credential_pool
        ; Alcotest.test_case
            "soft rate limits preserve independent credential-pool failover"
            `Quick
            test_soft_rate_limit_preserves_independent_pool_failover
        ; Alcotest.test_case
            "hard quota skips same credential-pool candidates"
            `Quick
            test_hard_quota_skips_same_credential_pool
        ; Alcotest.test_case
            "hard quota preserves independent credential-pool failover"
            `Quick
            test_hard_quota_preserves_independent_pool_failover
        ; Alcotest.test_case
            "500 classifies as recoverable server_error"
            `Quick
            test_server_error_classifies_as_runtime_recoverable
        ; Alcotest.test_case
            "generic accept rejection is not locally recoverable"
            `Quick
            test_generic_accept_rejected_is_not_locally_recoverable
        ; Alcotest.test_case
            "read-only no-progress remains recoverable"
            `Quick
            test_read_only_no_progress_remains_recoverable_not_contract
        ; Alcotest.test_case
            "read-only no-progress accept rejection rotates to default runtime"
            `Quick
            test_read_only_no_progress_rotates_to_default_runtime
        ; Alcotest.test_case
            "default runtime read-only no-progress uses tool-capable candidate"
            `Quick
            test_read_only_no_progress_default_runtime_uses_tool_capable_candidate
        ; Alcotest.test_case
            "rate-limit exhaustion stops after one candidate pass"
            `Quick
            test_rate_limit_exhaustion_stops_after_candidate_pass
        ] )
    ]
;;
