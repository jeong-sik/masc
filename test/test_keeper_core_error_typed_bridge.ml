(** RFC-0042 PR-2.5 invariant: the typed accessors
    [Keeper_agent_error.terminal_reason_code_of_core_error_typed] and
    [Keeper_agent_error.api_error_terminal_reason_code_typed] produce
    canonical wire strings byte-for-byte identical to the historical
    untyped output.  PR-3 retired the untyped accessors; this test
    now guards the wire format directly so dashboards /
    [bin/masc-trace] / Otel_metric_store labels do not drift.

    Coverage:
    - all [api_error] variants (RateLimited / Overloaded / ServerError /
      AuthError / AuthorizationError / PaymentRequired / InvalidRequest /
      NotFound / ContextOverflow / InputCapacity / NetworkError / Timeout)
    - agent_error variants reached via [CoreError.Agent _] routing
    - all top-level non-Agent / non-Api wrappers (Mcp / Config /
      Serialization / Io / Orchestration / Internal) *)

module AE = Masc.Keeper_agent_error
module Code = Masc.Keeper_turn_terminal_code
module EC = Masc.Keeper_error_classify
module KFR = Keeper_runtime_failure_route
module KTD = Masc.Keeper_turn_driver
module RC = Runtime_candidate
module CoreError = Agent_core.Error
module Retry = Agent_core.Retry
module Http = Llm_provider.Http_client
module Tool_contract = Agent_core.Tool_contract

let typed_wire t = Code.to_wire t
let unknown_invalid_request message =
  Retry.InvalidRequest
    { message; reason = Retry.Unknown_invalid_request }

let serving_constraint =
  Llm_provider.Serving_constraint.make
    ~source_kind:Llm_provider.Serving_constraint.Probe
    ~source_ref:"probe://incident/2793"
    ~checked_at_unix_s:0
    ~confidence:Llm_provider.Serving_constraint.High
    ~expires_at_unix_s:200
    ~accepted_through:524298
    ~rejected_from:524299
    ()
  |> Result.get_ok
;;

let terminal_invocation tool_use_id =
  Tool_contract.Invocation.create
    ~tool_use_id
    ~turn:7
    ~schedule:
      { planned_index = 2
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Tool_contract.Serial
      }
    ~completion:
      (Tool_contract.Terminal_after_success Tool_contract.Effect_outcome_unknown)
;;

let terminal_effect_agent_error =
  CoreError.TerminalToolEffectFailed
    { tool_use_id = "tool-terminal"
    ; effect_disposition = CoreError.proven_post_terminal_effect
    ; detail = "terminal effect failed"
    }
;;

let terminal_durability_agent_error =
  CoreError.TerminalToolDurabilityFailed
    { invocation = terminal_invocation "tool-durable"
    ; effect_disposition = CoreError.unknown_terminal_effect
    ; detail = "receipt persistence failed"
    }
;;

let terminal_effect_core_error = CoreError.Agent terminal_effect_agent_error
let terminal_durability_core_error = CoreError.Agent terminal_durability_agent_error

let api_cases : (string * CoreError.api_error * string) list =
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
  ; ( "InputCapacityRejected"
    , Retry.InputCapacity
        { message = "capacity"
        ; constraint_ = serving_constraint
        ; reason =
            Retry.Serving_constraint_rejected
              (Llm_provider.Serving_constraint.Input_rejected
                 { input_tokens = 524299
                 ; accepted_through = 524298
                 ; rejected_from = 524299
                 })
        }
    , "api_error_input_capacity:serving_constraint_rejected" )
  ; ( "InputCapacityMeasurementUnavailable"
    , Retry.InputCapacity
        { message = "capacity"
        ; constraint_ = serving_constraint
        ; reason =
            Retry.Token_measurement_unavailable
              Llm_provider.Input_token_count.Anthropic_messages_count_tokens
        }
    , "api_error_input_capacity:measurement_unavailable" )
  ; ( "NetworkError"
    , Retry.NetworkError { message = "ECONNRESET"; kind = Http.Connection_refused }
    , "api_error_network" )
  ; "Timeout", Retry.Timeout { message = "60s"; phase = None }, "api_error_timeout"
  ; ( "TimeoutWithExecutionBudgetProse"
    , Retry.Timeout
        { message =
            "Turn wall-clock budget exhausted during runtime attempt (budget=554.9s)"
        ; phase = None
        }
    , "api_error_timeout" )
  ]
;;

(* All variants reached through the top-level dispatcher. *)
let core_error_cases : (string * CoreError.t * string) list =
  [ ( "Agent/HookExecutionFailed"
    , CoreError.Agent
        (CoreError.HookExecutionFailed
           { hook_name = "post_tool_use"
           ; stage = "execute"
           ; tool_name = Some "Execute"
           ; tool_use_id = Some "tool-1"
           ; detail = "hook failed"
           })
    , "agent_error_hook_execution_failed:hook=post_tool_use,stage=execute" )
  ; ( "Agent/TerminalToolEffectFailed"
    , terminal_effect_core_error
    , "agent_error_terminal_tool_effect_failed:tool_use_id=tool-terminal,effect_disposition=proven_post_effect"
    )
  ; ( "Agent/TerminalToolDurabilityFailed"
    , terminal_durability_core_error
    , "agent_error_terminal_tool_durability_failed:tool_use_id=tool-durable,effect_disposition=effect_outcome_unknown"
    )
  ; ( "Agent/UnrecognizedStopReason"
    , CoreError.Agent (CoreError.UnrecognizedStopReason { reason = "abrupt" })
    , "agent_error_unrecognized_stop_reason:abrupt" )
  ; ( "Api/Timeout"
    , CoreError.Api (Retry.Timeout { message = "60s"; phase = None })
    , "api_error_timeout" )
  ; ( "Api/AuthorizationError"
    , CoreError.Api (Retry.AuthorizationError { message = "permission refused" })
    , "api_error_authorization" )
  ; ( "Provider/AuthorizationError"
    , CoreError.Provider
        (Llm_provider.Error.AuthorizationError
           { provider = "provider"; detail = "permission refused" })
    , "provider_error_authorization" )
  ; "Mcp", CoreError.Mcp (CoreError.InitializeFailed { detail = "boot" }), "mcp_error"
  ; "Config", CoreError.Config (CoreError.MissingEnvVar { var_name = "X" }), "config_error"
  ; ( "Serialization"
    , CoreError.Serialization (CoreError.JsonParseError { detail = "syntax" })
    , "serialization_error" )
  ; "Io", CoreError.Io (CoreError.ValidationFailed { detail = "vfd" }), "io_error"
  ; ( "Orchestration"
    , CoreError.Orchestration (CoreError.UnknownAgent { name = "ghost" })
    , "orchestration_error" )
  ; "Internal", CoreError.Internal "internal issue", "internal_error"
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
       let actual = typed_wire (AE.terminal_reason_code_of_core_error_typed err) in
       Alcotest.(check string) ("sdk/" ^ label) expected actual)
    core_error_cases
;;

let test_phased_network_error_preserves_typed_timeout () =
  let error =
    CoreError.Provider
      (Llm_provider.Error.NetworkError
         { provider = "provider"
         ; kind = Http.Dns_failure
         ; timeout_phase = Some Http.First_token
         ; detail = "resolver timed out during first-token wait"
         })
  in
  match AE.terminal_reason_code_of_core_error_typed error with
  | Code.Agent_core_error
      { wire; timeout = Some { phase = Some Http.First_token } } ->
    Alcotest.(check string)
      "wire remains byte-compatible"
      "provider_error_network:dns_failure:first_token"
      wire
  | code ->
    Alcotest.failf
      "phased network error lost typed timeout: %s"
      (Code.to_wire code)
;;

let test_terminal_tool_error_semantics () =
  List.iter
    (fun (label, error) ->
       Alcotest.(check string)
         (label ^ " termination")
         "core_error_failure"
         (AE.core_termination_semantics error
          |> AE.core_termination_semantics_to_string);
       Alcotest.(check bool)
         (label ^ " is not input required")
         false
         (EC.is_input_required_error error))
    [ "effect", terminal_effect_core_error
    ; "durability", terminal_durability_core_error
    ]
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
    (CoreError.Provider (Llm_provider.Error.ParseError { detail = "yyjson rejected body" }))
    ~provider:true
    ~model_:false
    ~server:true;
  check_parse_split
    "provider_invalid_request_json_message_is_not_typed_parse_error"
    (CoreError.Provider
       (Llm_provider.Error.InvalidRequest
          { provider = "claude"; reason = "unexpected character in JSON at byte 9" }))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_json_message_is_not_typed_parse_error"
    (CoreError.Api (unknown_invalid_request "unexpected character in JSON at byte 9"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "provider_invalid_request_yyjson_message_is_not_typed_parse_error"
    (CoreError.Provider
       (Llm_provider.Error.InvalidRequest
          { provider = "ollama"
          ; reason = "yyjson parse error: unexpected token at byte 9"
          }))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_json_parse_message_is_not_typed_parse_error"
    (CoreError.Api (unknown_invalid_request "JSON parse error at byte 9"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_xml_parse_error"
    (CoreError.Api (unknown_invalid_request "XML parse error at line 3"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "provider_invalid_request_invalid_json_is_not_typed_parse_error"
    (CoreError.Provider
       (Llm_provider.Error.InvalidRequest
          { provider = "claude"; reason = "invalid json in tool call arguments" }))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_invalid_json_is_not_typed_parse_error"
    (CoreError.Api (unknown_invalid_request "invalid json in tool call arguments"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_query_parse_error"
    (CoreError.Api (unknown_invalid_request "parse error in query parameters"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_cant_find_tool"
    (CoreError.Api (unknown_invalid_request "Can't find the specified tool"))
    ~provider:false
    ~model_:false
    ~server:false;
  check_parse_split
    "api_invalid_request_generic"
    (CoreError.Api (unknown_invalid_request "missing required field: model"))
    ~provider:false
    ~model_:false
    ~server:false
;;

let test_user_message_of_network_errors () =
  let api_dns =
    CoreError.Api
      (Retry.NetworkError
         { message = "failed to resolve hostname: ollama.com"
         ; kind = Http.Dns_failure
         })
  in
  Alcotest.(check string)
    "api dns user message"
    "Runtime provider: failed to resolve hostname: ollama.com"
    (AE.user_message_of_core_error api_dns);
  Alcotest.(check bool)
    "api dns hides Agent.run prefix"
    false
    (String_util.contains_substring_ci
       (AE.user_message_of_core_error api_dns)
       "Agent.run failed");
  let provider_dns =
    CoreError.Provider
      (Llm_provider.Error.NetworkError
         { provider = "ollama_cloud"
         ; kind = Http.Dns_failure
         ; timeout_phase = None
         ; detail = "failed to resolve hostname: ollama.com"
         })
  in
  Alcotest.(check string)
    "provider dns user message"
    "Runtime provider 'ollama_cloud': failed to resolve hostname: ollama.com"
    (AE.user_message_of_core_error provider_dns);
  (* The shape an operator reported: an argument-less exception renders its own
     constructor, so the message stated the same failure twice -- once in the
     operator's words ("connection closed") and once in OCaml's ("Detail:
     End_of_file") -- after two more namings ahead of both. *)
  let provider_eof =
    CoreError.Provider
      (Llm_provider.Error.NetworkError
         { provider = "ollama_cloud"
         ; kind = Http.End_of_file
         ; timeout_phase = None
         ; detail = "End_of_file"
         })
  in
  Alcotest.(check string)
    "a closed connection is named once"
    "Runtime provider 'ollama_cloud' closed the connection"
    (AE.user_message_of_core_error provider_eof);
  let guardrail =
    CoreError.Agent
      (CoreError.GuardrailViolation { validator = "policy"; reason = "blocked" })
  in
  Alcotest.(check string)
    "non-network errors preserve agent-core message"
    (Agent_core.Error.to_string guardrail)
    (AE.user_message_of_core_error guardrail);
  (* The raw overflow diagnostic must not reach chat verbatim (2026-07-21:
     "Context overflow: empty completion (stop_reason=…)" was stored in
     dashboard chat four times). Only the typed Api arm exists — the
     Provider path collapses overflow into InvalidRequest (RFC-0353). *)
  let overflow =
    CoreError.Api
      (Agent_core.Retry.ContextOverflow
         { message =
             "Context overflow: empty completion \
              (stop_reason=model_context_window_exceeded): provider returned \
              an empty assistant turn (no thinking, text, or tool calls)"
         ; limit = Some 262144
         })
  in
  Alcotest.(check string)
    "context overflow renders the user condition, not the raw diagnostic"
    "This conversation no longer fits the model's context window (model \
     window ~262144 tokens). The message was not processed; a shorter \
     message may fit."
    (AE.user_message_of_core_error overflow);
  Alcotest.(check bool)
    "context overflow hides the raw stop_reason payload"
    false
    (String_util.contains_substring_ci
       (AE.user_message_of_core_error overflow)
       "stop_reason")
;;

let test_user_message_of_masc_accept_rejected () =
  let err =
    KTD.core_error_of_masc_internal_error
      (KTD.Accept_rejected
         { scope = "runpod_fable5.gemma4-coder-fable5"
         ; model = None
         ; reason_kind = Some KTD.Accept_no_usable_progress
         ; response_shape = Some KTD.Accept_response_empty
         ; stop_reason = None
         ; reason =
             "response rejected by accept (runtime=runpod_fable5.gemma4-coder-fable5): \
              shape=empty; stop_reason=end_turn"
         })
  in
  let message = AE.user_message_of_core_error err in
  Alcotest.(check string)
    "accept rejection user message"
    "Provider returned an empty assistant turn for runtime runpod_fable5.gemma4-coder-fable5; no text or tool progress was produced."
    message;
  Alcotest.(check bool)
    "message hides agent-core internal wrapper"
    false
    (String_util.contains_substring_ci message "Internal error");
  Alcotest.(check bool)
    "message hides structured payload prefix"
    false
    (String_util.contains_substring_ci message "[masc_agent_core_error]")
;;

let test_quota_prose_does_not_override_typed_rate_limit () =
  let message =
    "you (yousleepwhen) have reached your session usage limit, add extra usage: \
     https://ollama.com/settings"
  in
  let err = CoreError.Api (Retry.RateLimited { retry_after = None; message }) in
  Alcotest.(check bool)
    "provider prose does not invent hard quota"
    false
    (KFR.core_error_is_hard_quota err);
  match EC.recoverable_runtime_failure_reason err with
  | Some EC.Rate_limit -> ()
  | Some reason ->
    Alcotest.failf
      "expected typed rate_limit, got %s"
      (EC.degraded_retry_reason_to_string reason)
  | None -> Alcotest.fail "expected rate_limit recoverable reason"
;;

let test_payment_required_is_hard_quota () =
  let err = CoreError.Api (Retry.PaymentRequired { message = "Insufficient Balance" }) in
  Alcotest.(check bool)
    "payment required is hard quota"
    true
    (KFR.core_error_is_hard_quota err);
  match EC.recoverable_runtime_failure_reason err with
  | Some EC.Hard_quota -> ()
  | Some reason ->
    Alcotest.failf
      "expected hard_quota, got %s"
      (EC.degraded_retry_reason_to_string reason)
  | None -> Alcotest.fail "expected hard_quota recoverable reason"
;;

let test_input_capacity_is_not_runtime_recovery () =
  let err =
    CoreError.Api
      (Retry.InputCapacity
         { message = "measurement unavailable"
         ; constraint_ = serving_constraint
         ; reason =
             Retry.Token_measurement_unavailable
               Llm_provider.Input_token_count.Anthropic_messages_count_tokens
         })
  in
  match EC.recoverable_runtime_failure_reason err with
  | None -> ()
  | Some reason ->
    Alcotest.failf
      "InputCapacity must not select MASC runtime recovery, got %s"
      (EC.degraded_retry_reason_to_string reason)
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
  let err = CoreError.Api (Retry.Overloaded { message }) in
  Alcotest.(check bool)
    "transient overload with quota prose is not hard quota"
    false
    (KFR.core_error_is_hard_quota err)
;;

(* Deleting the month-hardcoded "resets apr " indicator loses no coverage: the
   real signal is carried by the month-agnostic "you've hit your limit" /
   "monthly usage limit" indicators. This also fixes the 11-months-of-the-year
   false negative the April literal caused. *)
let test_soft_rate_limit_classifies_as_rate_limit () =
  let api_err =
    CoreError.Api
      (Retry.RateLimited
         { retry_after = Some 30.0; message = "rate limited, retry later" })
  in
  let provider_err =
    CoreError.Provider
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
         (KFR.core_error_is_hard_quota err);
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
  CoreError.Api
    (Retry.RateLimited
       { retry_after = Some 30.0; message = "rate limited, retry later" })
;;

let hard_quota_err =
  CoreError.Provider
    (Llm_provider.Error.HardQuota
       { provider = "typed-provider"
       ; retry_after = None
       ; detail = "typed quota exhaustion"
       })
;;

let server_error_500 =
  CoreError.Api
    (Retry.ServerError { status = 500; message = "Internal Server Error" })
;;

let provider_unavailable =
  CoreError.Provider
    (Llm_provider.Error.ProviderUnavailable
       { provider = "server-error-test"; detail = "HTTP 503 retry-after exhausted" })
;;

let generic_accept_rejected_err ~scope =
  KTD.core_error_of_masc_internal_error
    (KTD.Accept_rejected
       { scope
       ; model = None
       ; reason_kind = Some KTD.Accept_predicate_rejected
       ; response_shape = Some KTD.Accept_response_mixed_without_deliverable_content
       ; stop_reason = None
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

let test_soft_rate_limit_preserves_declared_same_credential_runtime () =
  init_rate_limit_pool_runtime ();
  match
    EC.degraded_rotation_after_recoverable_error
      ~fallback_hint:"same.b"
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:[ "same.a" ]
      soft_rate_limit_err
  with
  | Some { EC.next_runtime; fallback_reason = EC.Rate_limit } ->
    Alcotest.(check string)
      "declared same-credential runtime remains eligible"
      "same.b"
      next_runtime
  | Some { fallback_reason; next_runtime } ->
    Alcotest.failf
      "expected rate_limit -> same.b, got %s -> %s"
      (EC.degraded_retry_reason_to_string fallback_reason)
      next_runtime
  | None -> Alcotest.fail "expected declared same-credential runtime fallback"
;;

let test_soft_rate_limit_preserves_other_declared_runtime () =
  init_rate_limit_pool_runtime ();
  match
    EC.degraded_rotation_after_recoverable_error
      ~fallback_hint:"other.c"
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:[ "same.a" ]
      soft_rate_limit_err
  with
  | Some { EC.next_runtime; fallback_reason = EC.Rate_limit } ->
    Alcotest.(check string)
      "other declared runtime remains eligible"
      "other.c"
      next_runtime
  | Some { fallback_reason; next_runtime } ->
    Alcotest.failf
      "expected rate_limit -> other.c, got %s -> %s"
      (EC.degraded_retry_reason_to_string fallback_reason)
      next_runtime
  | None -> Alcotest.fail "expected other declared runtime fallback"
;;

let test_hard_quota_preserves_declared_same_credential_runtime () =
  init_rate_limit_pool_runtime ();
  match
    EC.degraded_rotation_after_recoverable_error
      ~fallback_hint:"same.b"
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:[ "same.a" ]
      hard_quota_err
  with
  | Some { EC.next_runtime; fallback_reason = EC.Hard_quota } ->
    Alcotest.(check string)
      "declared same-credential runtime remains eligible"
      "same.b"
      next_runtime
  | Some { fallback_reason; next_runtime } ->
    Alcotest.failf
      "expected hard_quota -> same.b, got %s -> %s"
      (EC.degraded_retry_reason_to_string fallback_reason)
      next_runtime
  | None -> Alcotest.fail "expected declared same-credential runtime fallback"
;;

let test_hard_quota_preserves_other_declared_runtime () =
  init_rate_limit_pool_runtime ();
  match
    EC.degraded_rotation_after_recoverable_error
      ~fallback_hint:"other.c"
      ~base_runtime:"same.a"
      ~effective_runtime:"same.a"
      ~attempted_runtimes:[ "same.a" ]
      hard_quota_err
  with
  | Some { EC.next_runtime; fallback_reason = EC.Hard_quota } ->
    Alcotest.(check string)
      "other declared runtime remains eligible"
      "other.c"
      next_runtime
  | Some { fallback_reason; next_runtime } ->
    Alcotest.failf
      "expected hard_quota -> other.c, got %s -> %s"
      (EC.degraded_retry_reason_to_string fallback_reason)
      next_runtime
  | None -> Alcotest.fail "expected other declared runtime fallback"
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

let test_rate_limit_exhaustion_stops_after_candidate_pass () =
  init_rate_limit_pool_runtime ();
  let attempted = [ "same.a"; "same.b"; "other.c" ] in
  match
    EC.degraded_rotation_after_recoverable_error
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

let test_receipt_persistence_failure_is_typed () =
  let err =
    KTD.core_error_of_masc_internal_error
      (KTD.Receipt_persistence_failed { detail = "disk unavailable" })
  in
  Alcotest.(check bool)
    "typed receipt failure is recognized"
    true
    (EC.is_receipt_lost_error err);
  Alcotest.(check bool)
    "similar free-form prose is not recognized"
    false
    (EC.is_receipt_lost_error
       (CoreError.Internal "execution_receipt_append_failed: disk unavailable"));
  match KTD.classify_masc_internal_error err with
  | Some (KTD.Receipt_persistence_failed { detail }) ->
    Alcotest.(check string) "detail round-trips" "disk unavailable" detail
  | Some other ->
    Alcotest.failf
      "expected typed receipt failure, got %s"
      (KTD.kind_of_masc_internal_error other)
  | None -> Alcotest.fail "typed receipt failure did not decode"
;;

let test_gate_replay_repair_failure_is_typed () =
  let err =
    KTD.core_error_of_masc_internal_error
      (KTD.Gate_replay_repair_required
         { approval_id = "approval-repair"
         ; operation = "connector_post"
         ; stage = KTD.Replay_journal
         ; detail = "journal fsync failed"
         })
  in
  match KTD.classify_masc_internal_error err with
  | Some
      (KTD.Gate_replay_repair_required
         { approval_id; operation; stage; detail }) ->
    Alcotest.(check string) "approval" "approval-repair" approval_id;
    Alcotest.(check string) "operation" "connector_post" operation;
    Alcotest.(check bool) "stage" true (stage = KTD.Replay_journal);
    Alcotest.(check string) "detail" "journal fsync failed" detail
  | Some other ->
    Alcotest.failf
      "expected typed Gate replay repair, got %s"
      (KTD.kind_of_masc_internal_error other)
  | None -> Alcotest.fail "typed Gate replay repair did not decode"
;;

let () =
  Alcotest.run
    "keeper_core_error_typed_bridge"
    [ ( "api_error wire invariant"
      , [ Alcotest.test_case
            "all api_error cases produce expected wire"
            `Quick
            test_api_typed_wire
        ] )
    ; ( "core_error wire invariant"
      , [ Alcotest.test_case
            "all core_error cases produce expected wire"
            `Quick
            test_sdk_typed_wire
        ; Alcotest.test_case
            "terminal tool errors preserve typed conservative semantics"
            `Quick
            test_terminal_tool_error_semantics
        ; Alcotest.test_case
            "phased network errors preserve typed timeout regardless of kind"
            `Quick
            test_phased_network_error_preserves_typed_timeout
        ] )
    ; ( "server parse rejection split"
      , [ Alcotest.test_case
            "provider and model parse rejections remain distinguishable"
            `Quick
            test_server_parse_rejection_split
        ] )
    ; ( "receipt persistence"
      , [ Alcotest.test_case
            "receipt failure uses typed provenance"
            `Quick
            test_receipt_persistence_failure_is_typed
        ; Alcotest.test_case
            "Gate replay repair carries exact provenance"
            `Quick
            test_gate_replay_repair_failure_is_typed
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
            "payment required is classified as hard quota"
            `Quick
            test_payment_required_is_hard_quota
        ; Alcotest.test_case
            "input capacity is not MASC runtime recovery"
            `Quick
            test_input_capacity_is_not_runtime_recovery
        ; Alcotest.test_case
            "transient overload with quota prose is not hard quota"
            `Quick
            test_overloaded_with_quota_prose_is_not_hard_quota
        ; Alcotest.test_case
            "soft rate limits preserve declared same-credential runtimes"
            `Quick
            test_soft_rate_limit_preserves_declared_same_credential_runtime
        ; Alcotest.test_case
            "soft rate limits preserve other declared runtimes"
            `Quick
            test_soft_rate_limit_preserves_other_declared_runtime
        ; Alcotest.test_case
            "hard quota preserves declared same-credential runtimes"
            `Quick
            test_hard_quota_preserves_declared_same_credential_runtime
        ; Alcotest.test_case
            "hard quota preserves other declared runtimes"
            `Quick
            test_hard_quota_preserves_other_declared_runtime
        ; Alcotest.test_case
            "500 classifies as recoverable server_error"
            `Quick
            test_server_error_classifies_as_runtime_recoverable
        ; Alcotest.test_case
            "generic accept rejection is not locally recoverable"
            `Quick
            test_generic_accept_rejected_is_not_locally_recoverable
        ; Alcotest.test_case
            "rate-limit exhaustion stops after one candidate pass"
            `Quick
            test_rate_limit_exhaustion_stops_after_candidate_pass
        ] )
    ]
;;
