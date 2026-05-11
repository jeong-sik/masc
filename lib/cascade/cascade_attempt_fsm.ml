(** Cascade_attempt_fsm — SDK error to FSM outcome, session/resumption analysis.

    Extracted from oas_worker_named.ml (God file decomposition).
    Converts OAS SDK errors into Cascade_fsm provider outcomes,
    classifies CLI-wrapped error patterns (hard quota, max turns,
    resumable sessions), and enriches errors with provider-specific hints.

    @since God file decomposition *)

(* DEPRECATED (RFC-0057 Phase 2): These string classifiers will be
   replaced by typed Provider_error variants. The new dispatch path
   receives CliWrapped { kind = Hard_quota | Max_turns | ... }
   directly from the provider adapter, eliminating the need for
   substring reconstruction.

   During the transition window, these functions remain for
   backward compatibility with old provider adapters that still
   emit InvalidRequest { message }. They will be removed once
   the Llm_provider opam pin is bumped to the RFC-0057 Phase 1
   version. *)
let retry_message_looks_like_not_found (message : string) : bool =
  String_util.contains_substring_ci message "not found"
  || String_util.contains_substring_ci message "status code: 404"
  || String_util.contains_substring_ci message "404 page not found"

let retry_message_looks_like_model_access_denied (message : string) : bool =
  String_util.contains_substring_ci message "permission to access"
  || String_util.contains_substring_ci message "not have access to"
  || String_util.contains_substring_ci message "does not have access to"
  || String_util.contains_substring_ci message "not authorized to access"

(** Convert an OAS sdk_error into a Cascade_fsm provider_outcome.
    API-level errors and model-capability-dependent agent errors are
    cascadeable (a different provider may succeed).  Structural agent
    errors (budget, idle, exit) are not — they would recur on any model. *)
let sdk_error_to_cascade_outcome (err : Agent_sdk.Error.sdk_error)
    : Cascade_fsm.provider_outcome option =
  match Cascade_error_classify.classify_masc_internal_error err with
  | Some (Cascade_error_classify.Resumable_cli_session { detail; _ }) ->
    Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.NetworkError
            { message = detail; kind = Llm_provider.Http_client.Unknown }))
  (* All other MASC-internal classifications (and unclassified errors) fall
     through to the structured [match err with] below to derive the cascade
     outcome from the raw [sdk_error] payload. *)
  | Some (Cascade_error_classify.Cascade_exhausted _)
  | Some (Cascade_error_classify.No_tool_capable_provider _)
  | Some (Cascade_error_classify.Accept_rejected _)
  | Some (Cascade_error_classify.Admission_queue_timeout _)
  | Some (Cascade_error_classify.Admission_queue_rejected _)
  | Some (Cascade_error_classify.Turn_timeout _)
  | Some (Cascade_error_classify.Oas_timeout_budget _)
  | Some (Cascade_error_classify.Ambiguous_post_commit _)
  | None -> (
  match err with
  | Agent_sdk.Error.Api api_err ->
    let http_err = match[@warning "-8"] api_err with
      | Llm_provider.Retry.InvalidRequest { message } ->
        if retry_message_looks_like_model_access_denied message then
          Llm_provider.Http_client.ProviderFailure
            {
              kind =
                Llm_provider.Http_client.Capability_mismatch
                  { capability = Some "model_access" };
              message;
            }
        else
          let code =
            if retry_message_looks_like_not_found message then 404 else 400
          in
          Llm_provider.Http_client.HttpError { code; body = message }
      | Llm_provider.Retry.ContextOverflow { message; _ } ->
        Llm_provider.Http_client.HttpError { code = 400; body = message }
      | Llm_provider.Retry.RateLimited { message; _ } ->
        Llm_provider.Http_client.HttpError { code = 429; body = message }
      | Llm_provider.Retry.NotFound { message } ->
        Llm_provider.Http_client.HttpError { code = 404; body = message }
      | Llm_provider.Retry.ServerError { status; message } ->
        Llm_provider.Http_client.HttpError { code = status; body = message }
      | Llm_provider.Retry.AuthError { message } ->
        Llm_provider.Http_client.HttpError { code = 401; body = message }
      | Llm_provider.Retry.Overloaded { message } ->
        Llm_provider.Http_client.HttpError { code = 529; body = message }
      | Llm_provider.Retry.NetworkError { message; kind } ->
        Llm_provider.Http_client.NetworkError { message; kind }
      | Llm_provider.Retry.Timeout { message } ->
        Llm_provider.Http_client.NetworkError
          { message; kind = Llm_provider.Http_client.Timeout }
    in
    Some (Cascade_fsm.Call_err http_err)
  (* Model-capability errors: the next provider may handle these.
     CompletionContractViolation: model returned text when tool_use was
     required — a different model with better tool calling may succeed.
     UnrecognizedStopReason: model returned a non-standard stop reason
     that this provider does not map — another provider may not. *)
  | Agent_sdk.Error.Agent (Agent_sdk.Error.CompletionContractViolation { reason; _ }) ->
    Some (Cascade_fsm.Call_err
      (Llm_provider.Http_client.AcceptRejected { reason }))
  | Agent_sdk.Error.Agent (Agent_sdk.Error.UnrecognizedStopReason { reason }) ->
    Some (Cascade_fsm.Call_err
      (Llm_provider.Http_client.AcceptRejected { reason }))
  | Agent_sdk.Error.Config
      (Agent_sdk.Error.InvalidConfig { field = "runtime_mcp_auth"; detail })
  | Agent_sdk.Error.Config
      (Agent_sdk.Error.InvalidConfig { field = "tool_support"; detail }) ->
    Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.AcceptRejected { reason = detail }))
  (* Other Agent error variants are structural (budget, idle, exit, retries,
     guardrails, tripwires) and would recur on any model — not cascadeable. *)
  | Agent_sdk.Error.Agent (MaxTurnsExceeded _)
  | Agent_sdk.Error.Agent (TokenBudgetExceeded _)
  | Agent_sdk.Error.Agent (CostBudgetExceeded _)
  | Agent_sdk.Error.Agent (IdleDetected _)
  | Agent_sdk.Error.Agent (ToolRetryExhausted _)
  | Agent_sdk.Error.Agent (GuardrailViolation _)
  | Agent_sdk.Error.Agent (TripwireViolation _)
  | Agent_sdk.Error.Agent (ExitConditionMet _) -> None
  (* Other Config errors (different InvalidConfig field, MissingEnvVar,
     UnsupportedProvider) and non-Api / non-Agent / non-Config families are
     not cascade-recoverable. *)
  | Agent_sdk.Error.Config (InvalidConfig _)
  | Agent_sdk.Error.Config (MissingEnvVar _)
  | Agent_sdk.Error.Config (UnsupportedProvider _)
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> None)

let sdk_error_is_model_access_denied (err : Agent_sdk.Error.sdk_error) =
  match sdk_error_to_cascade_outcome err with
  | Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.ProviderFailure
            {
              kind =
                Llm_provider.Http_client.Capability_mismatch
                  { capability = Some "model_access" };
              _;
            })) ->
    true
  | _ -> false

let moonshot_auth_hint_marker = "Moonshot returned 401"
let openai_compat_not_found_hint_marker =
  "OpenAI-compatible endpoint returned 404"

let is_moonshot_provider (provider_cfg : Llm_provider.Provider_config.t) =
  String_util.contains_substring_ci provider_cfg.base_url "moonshot.ai"
  || String.starts_with ~prefix:"kimi" provider_cfg.model_id

let cascade_name_to_string = Cascade_error_classify.cascade_name_to_string

let resolve_kimi_api_key_env_name ~cascade_name =
  let cascade_name = cascade_name_to_string cascade_name in
  let fallback_env = "KIMI_API_KEY_SB" in
  let resolve_from_overrides overrides =
    let find_non_empty key =
      match List.assoc_opt key overrides with
      | Some value when String.trim value <> "" -> Some value
      | _ -> None
    in
    match find_non_empty "kimi" with
    | Some env_name -> env_name
    | None ->
      (match find_non_empty "*" with
       | Some env_name -> env_name
       | None -> fallback_env)
  in
  match Cascade_oas_runner.default_config_path () with
  | Some config_path ->
    let overrides =
      Cascade_config.resolve_api_key_env ~config_path ~name:cascade_name
    in
    resolve_from_overrides overrides
  | None -> fallback_env

let enrich_sdk_error ~cascade_name
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (err : Agent_sdk.Error.sdk_error) =
  let append_hint message hint_marker detail =
    if String_util.contains_substring_ci message hint_marker then
      message
    else
      Printf.sprintf "%s (%s: %s)" message hint_marker detail
  in
  match err with
  | Agent_sdk.Error.Api (Llm_provider.Retry.AuthError { message })
    when is_moonshot_provider provider_cfg ->
    let env_name =
      match resolve_kimi_api_key_env_name ~cascade_name with
      | "" -> "configured kimi API key env"
      | value -> value
    in
    let detail =
      if String.trim provider_cfg.api_key = "" then
        Printf.sprintf "%s is empty or unset in this process" env_name
      else
        Printf.sprintf
          "%s was loaded and the auth header was populated; verify that it is a valid Moonshot API key"
          env_name
    in
    Agent_sdk.Error.Api
      (Llm_provider.Retry.AuthError
         {
           message =
             append_hint message moonshot_auth_hint_marker detail;
         })
  | Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest { message })
    when retry_message_looks_like_not_found message ->
    (* Endpoint URL hint is shape-agnostic data — every provider_cfg carries
       [base_url] / [request_path] (empty strings for CLI agents) — so the
       not_found hint applies to any provider whose retry message matches the
       not_found pattern.  CLI providers' not_found errors rarely surface
       through this code path (they emit text errors, not the OpenAI-compat
       InvalidRequest shape), so the practical effect is a no-op for CLI
       agents while still helping HTTP providers (openai-compat, glm, etc.)
       diagnose endpoint drift.  RFC-0058 §2.4: no closed-variant dispatch. *)
    let detail =
      Printf.sprintf "base_url=%s request_path=%s endpoint=%s"
        provider_cfg.base_url provider_cfg.request_path
        (provider_cfg.base_url ^ provider_cfg.request_path)
    in
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         {
           message =
             append_hint message openai_compat_not_found_hint_marker detail;
         })
  | _ -> err

(** CLI-wrapped error variants where quota signals may appear serialized as
    text.  AuthError, NotFound, ContextOverflow, and Timeout never carry
    quota information — excluding them avoids unnecessary substring scans
    and makes the structural filter explicit. *)
let api_error_message_for_quota_scan (api_err : Llm_provider.Retry.api_error)
    : string option =
  match api_err with
  | Llm_provider.Retry.RateLimited { message; _ } ->
    (* Structured hard-quota check is handled separately by
       [Llm_provider.Retry.is_hard_quota]; this extractor is for the
       CLI-wrapped fallback path only.  RateLimited messages are included
       here so the compound CLI-exit-code heuristic can still fire on
       messages that [is_hard_quota] does not cover. *)
    Some message
  | Llm_provider.Retry.NetworkError { message; _ } -> Some message
  | Llm_provider.Retry.Overloaded { message } -> Some message
  | Llm_provider.Retry.ServerError { message; _ } -> Some message
  (* InvalidRequest covers Anthropic's HTTP 400 user-set monthly cap
     ("You have reached your specified API usage limits...").  Without
     this branch, direct (non-CLI) API calls treat the cap as a
     retryable client error and the cascade burns its full turn budget
     on a permanent failure.  Observed 2026-04-29. *)
  | Llm_provider.Retry.InvalidRequest { message } -> Some message
  | Llm_provider.Retry.AuthError _
  | Llm_provider.Retry.NotFound _
  | Llm_provider.Retry.ContextOverflow _
  | Llm_provider.Retry.Timeout _ ->
    None

(** Substring indicators for hard-quota signals in CLI-wrapped error text.

    These are necessary because CLI transports (Gemini CLI, Claude Code CLI)
    serialize provider errors as plain text in [NetworkError.message] or
    [InvalidRequest.message].  The structured [Llm_provider.Retry.is_hard_quota]
    only inspects the [RateLimited] variant, so CLI-wrapped messages require
    text-level pattern matching.

    [Llm_provider.Retry.is_hard_quota_message] exists in the external library
    but is not exposed in its .mli, so these indicators cannot delegate to it.
    If it becomes public in a future agent_sdk release, this list can be
    replaced with a call to that function plus the CLI-specific extras. *)
let cli_wrapped_hard_quota_indicators = [
  "hard_quota";
  "terminalquotaerror";
  "quota_exhausted";
  "exhausted your capacity on this model";
  "quota will reset after";
  "\"api_error_status\":429";
  "you've hit your limit";
  "monthly usage limit";
  "org's monthly usage limit";
  "resets apr ";
  (* Anthropic console usage-limit error (HTTP 400 invalid_request_error,
     observed 2026-04-29 with 2-day reset window).  Body shape:
       {"type":"error","error":{"type":"invalid_request_error",
        "message":"You have reached your specified API usage limits.
        You will regain access on YYYY-MM-DD at HH:MM UTC."}}
     Earlier 429-based indicators don't match because Anthropic now
     returns 400 with the user-set monthly cap.  Without these markers
     [sdk_error_is_hard_quota] returns false → cascade keeps retrying
     claude_code:auto for the full OAS turn budget (~60min). *)
  "reached your specified api usage limits";
  "you will regain access on";
]

let message_looks_like_cli_wrapped_hard_quota (message : string) : bool =
  let contains needle =
    String_util.contains_substring_ci message needle
  in
  List.exists contains cli_wrapped_hard_quota_indicators
  ||
  (contains "claude exited with code 1"
   && contains "\"api_error_status\":429"
   && contains "you've hit your limit")

let cli_wrapped_max_turns_indicators = [
  "\"subtype\":\"error_max_turns\"";
  "error_max_turns";
  "\"terminal_reason\":\"max_turns\"";
  "terminal_reason\":\"max_turns";
  "reached maximum number of turns";
  "max turns exceeded";
]

let message_looks_like_cli_wrapped_max_turns (message : string) : bool =
  let contains needle =
    String_util.contains_substring_ci message needle
  in
  List.exists contains cli_wrapped_max_turns_indicators

let exit_code_of_message (message : string) : int option =
  let prefix = "exited with code " in
  match String.index_opt message ' ' with
  | None -> None
  | Some first_space ->
      let search_from = first_space + 1 in
      if search_from >= String.length message then None
      else
        let suffix =
          String.sub message search_from (String.length message - search_from)
        in
        if not (String.starts_with ~prefix suffix) then None
        else
          match String.index_from_opt suffix (String.length prefix) ':' with
          | None -> None
          | Some colon ->
              let raw =
                String.sub suffix (String.length prefix)
                  (colon - String.length prefix)
                |> String.trim
              in
              int_of_string_opt raw

let message_looks_like_resumable_cli_session (message : string) : bool =
  Cascade_runner.Kimi_cli_transport_local.text_looks_like_resumable_session
    message

let resumable_cli_session_detail (message : string) : string =
  Cascade_runner.Kimi_cli_transport_local.resumable_session_detail_of_text
    message

let resumable_cli_session_exit_code (message : string) : int option =
  Cascade_runner.Kimi_cli_transport_local.resumable_session_exit_code_of_text
    message

let sdk_error_to_resumable_cli_session ~cascade_name
    (err : Agent_sdk.Error.sdk_error) =
  match Cascade_error_classify.classify_masc_internal_error err with
  | Some (Cascade_error_classify.Resumable_cli_session _) -> Some err
  | _ ->
      let message = Agent_sdk.Error.to_string err in
      if message_looks_like_resumable_cli_session message then
        Some
          (Cascade_error_classify.sdk_error_of_masc_internal_error
             (Cascade_error_classify.Resumable_cli_session
                {
                  cascade_name =
                    cascade_name;
                  detail = resumable_cli_session_detail message;
                  exit_code = resumable_cli_session_exit_code message;
                }))
      else None

let sdk_error_is_resumable_cli_session (err : Agent_sdk.Error.sdk_error) : bool =
  match Cascade_error_classify.classify_masc_internal_error err with
  | Some (Cascade_error_classify.Resumable_cli_session _) -> true
  | _ ->
      let direct_api_message =
        match err with
        | Agent_sdk.Error.Api
            (Llm_provider.Retry.NetworkError { message; _ }
            | Llm_provider.Retry.Overloaded { message }
            | Llm_provider.Retry.ServerError { message; _ }
            | Llm_provider.Retry.InvalidRequest { message }
            | Llm_provider.Retry.RateLimited { message; _ }
            | Llm_provider.Retry.AuthError { message }
            | Llm_provider.Retry.NotFound { message }
            | Llm_provider.Retry.ContextOverflow { message; _ }
            | Llm_provider.Retry.Timeout { message }) ->
            message_looks_like_resumable_cli_session message
        | _ -> false
      in
      direct_api_message
      || message_looks_like_resumable_cli_session (Agent_sdk.Error.to_string err)

let message_looks_like_terminal_provider_runtime_failure message =
  let contains needle = String_util.contains_substring_ci message needle in
  (contains "kimi_cli rejected" && contains "startup crash")
  || contains "unicodedecodeerror"
  || (contains "jsonrpcmessage"
      && (contains "validationerror" || contains "invalid json"))
  || (contains "error parsing sse message"
      && (contains "jsonrpc" || contains "jsonrpcmessage"))

let sdk_error_is_terminal_provider_runtime_failure
    (err : Agent_sdk.Error.sdk_error) : bool =
  let direct_api_message =
    match err with
    | Agent_sdk.Error.Api
        (Llm_provider.Retry.NetworkError { message; _ }
        | Llm_provider.Retry.Overloaded { message }
        | Llm_provider.Retry.ServerError { message; _ }
        | Llm_provider.Retry.InvalidRequest { message }
        | Llm_provider.Retry.RateLimited { message; _ }
        | Llm_provider.Retry.AuthError { message }
        | Llm_provider.Retry.NotFound { message }
        | Llm_provider.Retry.ContextOverflow { message; _ }
        | Llm_provider.Retry.Timeout { message }) ->
        message_looks_like_terminal_provider_runtime_failure message
    | _ -> false
  in
  direct_api_message
  || message_looks_like_terminal_provider_runtime_failure
       (Agent_sdk.Error.to_string err)

let sdk_error_is_hard_quota (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Api api_err ->
    (* Layer 1: structured variant check — [is_hard_quota] inspects the
       [RateLimited] variant for known hard-quota message patterns. *)
    Llm_provider.Retry.is_hard_quota api_err
    ||
    (* Layer 2: CLI-wrapped fallback — extract message from variants that
       may carry serialized CLI output, then scan for quota indicators.
       Variants excluded by [api_error_message_for_quota_scan] (AuthError,
       NotFound, ContextOverflow, Timeout) never carry quota signals. *)
    (match api_error_message_for_quota_scan api_err with
     | Some message ->
       message_looks_like_cli_wrapped_hard_quota message
     | None -> false)
  (* Non-Api error families never carry provider-level hard-quota signals. *)
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> false

let provider_label provider =
  match String.trim provider with
  | "" -> "unknown"
  | value -> value

let transient_http_status code =
  code = 408 || code = 409 || code = 425 || code = 429 || code >= 500

let provider_capacity ?(scope = `Provider) provider =
  Some (Provider_error.CapacityExhausted { scope; affected = [ provider ] })

let retry_api_error_to_provider_error ~provider ~capacity_exhausted api_error =
  let provider = provider_label provider in
  match api_error with
  | Llm_provider.Retry.RateLimited { retry_after; _ } ->
      if capacity_exhausted then provider_capacity provider
      else Some (Provider_error.RateLimit { retry_after; provider })
  | Llm_provider.Retry.Overloaded _ ->
      if capacity_exhausted then provider_capacity provider
      else Some (Provider_error.ServerError { code = 529; transient = true })
  | Llm_provider.Retry.ServerError { status; _ } ->
      Some
        (Provider_error.ServerError
           { code = status; transient = transient_http_status status })
  | Llm_provider.Retry.AuthError _ ->
      Some (Provider_error.AuthError { provider })
  | Llm_provider.Retry.InvalidRequest { message } ->
      if capacity_exhausted then provider_capacity provider
      else Some (Provider_error.InvalidRequest { provider; reason = message })
  | Llm_provider.Retry.NotFound { message } ->
      Some (Provider_error.InvalidRequest { provider; reason = message })
  | Llm_provider.Retry.ContextOverflow _ ->
      provider_capacity ~scope:`Model provider
  | Llm_provider.Retry.NetworkError _
  | Llm_provider.Retry.Timeout _ ->
      if capacity_exhausted then provider_capacity provider else None

let sdk_error_to_provider_error ~provider err =
  match err with
  | Agent_sdk.Error.Api api_err ->
      retry_api_error_to_provider_error ~provider
        ~capacity_exhausted:(sdk_error_is_hard_quota err)
        api_err
  (* Non-Api families do not map to a provider-level error. *)
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> None

let provider_error_total_metric = "masc_provider_error_total"

let () =
  Prometheus.register_counter
    ~name:provider_error_total_metric
    ~help:
      "Total provider-level errors classified during cascade \
       attempts (rate limit, auth failure, capacity exhaustion, \
       server error, invalid request). Labels: kind \
       (Provider_error.to_error_kind), provider (provider debug \
       label), cascade_name (originating cascade), capacity_scope \
       (CapacityExhausted scope or \"none\")."
    ()

let provider_error_capacity_scope_label = function
  | Provider_error.CapacityExhausted { scope; _ } ->
      Provider_error.scope_to_string scope
  | Provider_error.RateLimit _
  | Provider_error.AuthError _
  | Provider_error.ServerError _
  | Provider_error.InvalidRequest _
  | Provider_error.CliWrappedHardQuota _
  | Provider_error.CliWrappedMaxTurns _
  | Provider_error.CliWrappedResumableSession _
  | Provider_error.PermissionDenied _
  | Provider_error.ModelNotFound _ ->
      "none"

let emit_provider_error_metric ~cascade_name ~provider error =
  let cascade_name = provider_label (cascade_name_to_string cascade_name) in
  let provider = provider_label provider in
  Dashboard_oas_bridge.record_provider_error ~cascade_name ~provider_id:provider
    error;
  Prometheus.inc_counter provider_error_total_metric
    ~labels:
      [
        ("kind", Provider_error.to_error_kind error);
        ("provider", provider);
        ("cascade_name", cascade_name);
        ("capacity_scope", provider_error_capacity_scope_label error);
      ]
    ()

(* #13923 / #13933: when the agent_sdk [with_optional_timeout] wrapper
   fires it produces a [Retry.Timeout] whose message starts with
   "Agent execution exceeded max_execution_time_s". Distinguish that
   from a transport-level provider timeout by substring so dashboards
   can tell whether our per-OAS-call ceiling actually engaged versus
   the upstream socket deadline. *)
let timeout_source_label (err : Agent_sdk.Error.sdk_error) : string =
  let is_max_execution_time =
    match err with
    | Agent_sdk.Error.Api (Llm_provider.Retry.Timeout { message }) ->
        String_util.contains_substring_ci message "max_execution_time_s"
    | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited _)
    | Agent_sdk.Error.Api (Llm_provider.Retry.Overloaded _)
    | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError _)
    | Agent_sdk.Error.Api (Llm_provider.Retry.AuthError _)
    | Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest _)
    | Agent_sdk.Error.Api (Llm_provider.Retry.NotFound _)
    | Agent_sdk.Error.Api (Llm_provider.Retry.ContextOverflow _)
    | Agent_sdk.Error.Api (Llm_provider.Retry.NetworkError _)
    | Agent_sdk.Error.Agent _
    | Agent_sdk.Error.Mcp _
    | Agent_sdk.Error.Config _
    | Agent_sdk.Error.Serialization _
    | Agent_sdk.Error.Io _
    | Agent_sdk.Error.Orchestration _
    | Agent_sdk.Error.A2a _
    | Agent_sdk.Error.Internal _ -> false
  in
  if is_max_execution_time then "max_execution_time" else "provider"

let emit_oas_run_timeout_metric ~cascade_name ~provider err =
  match err with
  | Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _) ->
      let cascade_name = provider_label (cascade_name_to_string cascade_name) in
      let provider = provider_label provider in
      Prometheus.inc_counter Keeper_metrics.metric_keeper_oas_run_timeout
        ~labels:
          [
            ("cascade", cascade_name);
            ("provider", provider);
            ("source", timeout_source_label err);
          ]
        ()
  | _ -> ()

let emit_sdk_provider_error_metric ~cascade_name ~provider err =
  emit_oas_run_timeout_metric ~cascade_name ~provider err;
  match sdk_error_to_provider_error ~provider err with
  | None -> None
  | Some provider_error ->
      emit_provider_error_metric ~cascade_name ~provider provider_error;
      Some provider_error

(* When the SDK surfaces a transient HTTP 429 that is *not* a hard-quota
   in disguise, expose the [retry_after] hint that [Llm_provider.Retry]
   already extracted from the response body.  Used by the cascade error
   classifier to feed [Cascade_health_tracker.record_soft_rate_limited]
   so a single 429 trips an immediate short cooldown instead of waiting
   for [cooldown_threshold] consecutive [record_failure] events.

   Returns [None] when the error is not a non-quota [RateLimited], or
   when [retry_after] is absent.  A [Some 0.] / [Some <0.] is preserved
   here and clamped/defaulted at the tracker boundary so the caller's
   semantics ("the 429 still happened, so cool down at least the
   default") are maintained centrally. *)
let sdk_error_soft_rate_limited (err : Agent_sdk.Error.sdk_error)
  : float option option =
  match err with
  | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited { retry_after; _ } as api_err)
    when not (Llm_provider.Retry.is_hard_quota api_err) ->
    Some retry_after
  (* Hard-quota RateLimited is handled separately and other Api / non-Api
     errors do not represent soft rate limiting. *)
  | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.Overloaded _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.AuthError _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.NotFound _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.ContextOverflow _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.NetworkError _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> None

let sdk_error_is_max_turns_exceeded (err : Agent_sdk.Error.sdk_error) : bool =
  match Cascade_error_classify.classify_masc_internal_error err with
  | Some
      (Cascade_error_classify.Cascade_exhausted
         { reason = Keeper_types.Max_turns_exceeded; _ }) ->
      true
  | Some
      (Cascade_error_classify.Cascade_exhausted
         { reason = Keeper_types.Other_detail detail; _ }) ->
      message_looks_like_cli_wrapped_max_turns detail
  | Some (Cascade_error_classify.Cascade_exhausted _)
  | Some (Cascade_error_classify.Resumable_cli_session _)
  | Some (Cascade_error_classify.No_tool_capable_provider _)
  | Some (Cascade_error_classify.Accept_rejected _)
  | Some (Cascade_error_classify.Admission_queue_timeout _)
  | Some (Cascade_error_classify.Admission_queue_rejected _)
  | Some (Cascade_error_classify.Turn_timeout _)
  | Some (Cascade_error_classify.Oas_timeout_budget _)
  | Some (Cascade_error_classify.Ambiguous_post_commit _) ->
      false
  | None -> (
      match err with
      | Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded _) -> true
      | Agent_sdk.Error.Api
          (Llm_provider.Retry.NetworkError { message; _ }
          | Llm_provider.Retry.Overloaded { message }
          | Llm_provider.Retry.ServerError { message; _ }
          | Llm_provider.Retry.InvalidRequest { message }
          | Llm_provider.Retry.Timeout { message }) ->
          message_looks_like_cli_wrapped_max_turns message
      | Agent_sdk.Error.Api
          (Llm_provider.Retry.RateLimited _
          | Llm_provider.Retry.AuthError _
          | Llm_provider.Retry.NotFound _
          | Llm_provider.Retry.ContextOverflow _) ->
          false
      | Agent_sdk.Error.Internal message ->
          message_looks_like_cli_wrapped_max_turns message
      | _ -> false)

let sdk_error_cascade_fallback_class (err : Agent_sdk.Error.sdk_error) :
    string option =
  if sdk_error_is_hard_quota err then Some "hard_quota"
  else if sdk_error_is_max_turns_exceeded err then Some "max_turns"
  else if sdk_error_is_resumable_cli_session err then
    Some "resumable_cli_session"
  else None
