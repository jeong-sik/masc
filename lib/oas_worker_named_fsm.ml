(** Oas_worker_named_fsm — SDK error to FSM outcome, session/resumption analysis.

    Extracted from oas_worker_named.ml (God file decomposition).
    Converts OAS SDK errors into Cascade_fsm provider outcomes,
    classifies CLI-wrapped error patterns (hard quota, max turns,
    resumable sessions), and enriches errors with provider-specific hints.

    @since God file decomposition *)

let retry_message_looks_like_not_found (message : string) : bool =
  String_util.contains_substring_ci message "not found"
  || String_util.contains_substring_ci message "status code: 404"
  || String_util.contains_substring_ci message "404 page not found"

(** Convert an OAS sdk_error into a Cascade_fsm provider_outcome.
    API-level errors and model-capability-dependent agent errors are
    cascadeable (a different provider may succeed).  Structural agent
    errors (budget, idle, exit) are not — they would recur on any model. *)
let sdk_error_to_cascade_outcome (err : Oas.Error.sdk_error)
    : Cascade_fsm.provider_outcome option =
  match Oas_worker_named_error.classify_masc_internal_error err with
  | Some (Oas_worker_named_error.Resumable_cli_session { detail; _ }) ->
    Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.NetworkError
            { message = detail; kind = Llm_provider.Http_client.Unknown }))
  | _ -> (
  match err with
  | Oas.Error.Api api_err ->
    let http_err = match[@warning "-8"] api_err with
      | Llm_provider.Retry.InvalidRequest { message } ->
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
  | Oas.Error.Agent (Oas.Error.CompletionContractViolation { reason; _ }) ->
    Some (Cascade_fsm.Call_err
      (Llm_provider.Http_client.AcceptRejected { reason }))
  | Oas.Error.Agent (Oas.Error.UnrecognizedStopReason { reason }) ->
    Some (Cascade_fsm.Call_err
      (Llm_provider.Http_client.AcceptRejected { reason }))
  | Oas.Error.Config
      (Oas.Error.InvalidConfig { field = "runtime_mcp_auth"; detail })
  | Oas.Error.Config
      (Oas.Error.InvalidConfig { field = "tool_support"; detail }) ->
    Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.AcceptRejected { reason = detail }))
  | _ -> None)

let moonshot_auth_hint_marker = "Moonshot returned 401"
let openai_compat_not_found_hint_marker =
  "OpenAI-compatible endpoint returned 404"

let is_moonshot_provider (provider_cfg : Llm_provider.Provider_config.t) =
  String_util.contains_substring_ci provider_cfg.base_url "moonshot.ai"
  || String.starts_with ~prefix:"kimi" provider_cfg.model_id

let cascade_name_to_string = Oas_worker_named_error.cascade_name_to_string

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
  match Oas_worker_named_cascade.default_config_path () with
  | Some config_path ->
    let overrides =
      Cascade_config.resolve_api_key_env ~config_path ~name:cascade_name
    in
    resolve_from_overrides overrides
  | None -> fallback_env

let enrich_sdk_error ~cascade_name
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (err : Oas.Error.sdk_error) =
  let append_hint message hint_marker detail =
    if String_util.contains_substring_ci message hint_marker then
      message
    else
      Printf.sprintf "%s (%s: %s)" message hint_marker detail
  in
  match err with
  | Oas.Error.Api (Llm_provider.Retry.AuthError { message })
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
    Oas.Error.Api
      (Llm_provider.Retry.AuthError
         {
           message =
             append_hint message moonshot_auth_hint_marker detail;
         })
  | Oas.Error.Api (Llm_provider.Retry.InvalidRequest { message })
    when provider_cfg.kind = Llm_provider.Provider_config.OpenAI_compat
      && retry_message_looks_like_not_found message ->
    let detail =
      Printf.sprintf "base_url=%s request_path=%s endpoint=%s"
        provider_cfg.base_url provider_cfg.request_path
        (provider_cfg.base_url ^ provider_cfg.request_path)
    in
    Oas.Error.Api
      (Llm_provider.Retry.InvalidRequest
         {
           message =
             append_hint message openai_compat_not_found_hint_marker detail;
         })
  | _ -> err

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
  Oas_worker_exec.Kimi_cli_transport_local.text_looks_like_resumable_session
    message

let resumable_cli_session_detail (message : string) : string =
  Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail_of_text
    message

let resumable_cli_session_exit_code (message : string) : int option =
  Oas_worker_exec.Kimi_cli_transport_local.resumable_session_exit_code_of_text
    message

let sdk_error_to_resumable_cli_session ~cascade_name
    (err : Oas.Error.sdk_error) =
  match Oas_worker_named_error.classify_masc_internal_error err with
  | Some (Oas_worker_named_error.Resumable_cli_session _) -> Some err
  | _ ->
      let message = Oas.Error.to_string err in
      if message_looks_like_resumable_cli_session message then
        Some
          (Oas_worker_named_error.sdk_error_of_masc_internal_error
             (Oas_worker_named_error.Resumable_cli_session
                {
                  cascade_name =
                    cascade_name;
                  detail = resumable_cli_session_detail message;
                  exit_code = resumable_cli_session_exit_code message;
                }))
      else None

let sdk_error_is_resumable_cli_session (err : Oas.Error.sdk_error) : bool =
  match Oas_worker_named_error.classify_masc_internal_error err with
  | Some (Oas_worker_named_error.Resumable_cli_session _) -> true
  | _ ->
      let direct_api_message =
        match err with
        | Oas.Error.Api
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
      || message_looks_like_resumable_cli_session (Oas.Error.to_string err)

let sdk_error_is_hard_quota (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Api api_err ->
    Llm_provider.Retry.is_hard_quota api_err
    ||
    (match[@warning "-8"] api_err with
     | Llm_provider.Retry.NetworkError { message; _ }
     | Llm_provider.Retry.Overloaded { message }
     | Llm_provider.Retry.ServerError { message; _ }
     (* InvalidRequest covers Anthropic's HTTP 400 user-set monthly cap
        ("You have reached your specified API usage limits...").  Without
        this branch, direct (non-CLI) API calls treat the cap as a
        retryable client error and the cascade burns its full turn budget
        on a permanent failure.  Observed 2026-04-29.  CLI-wrapped form
        already lands in [NetworkError] above. *)
     | Llm_provider.Retry.InvalidRequest { message } ->
       message_looks_like_cli_wrapped_hard_quota message
     | Llm_provider.Retry.RateLimited _
     | Llm_provider.Retry.AuthError _
     | Llm_provider.Retry.NotFound _
     | Llm_provider.Retry.ContextOverflow _
     | Llm_provider.Retry.Timeout _ ->
       false)
  | _ -> false

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
  | Oas.Error.Api api_err ->
      retry_api_error_to_provider_error ~provider
        ~capacity_exhausted:(sdk_error_is_hard_quota err)
        api_err
  | _ -> None

let provider_error_total_metric = "masc_provider_error_total"

let provider_error_capacity_scope_label = function
  | Provider_error.CapacityExhausted { scope; _ } ->
      Provider_error.scope_to_string scope
  | Provider_error.RateLimit _
  | Provider_error.AuthError _
  | Provider_error.ServerError _
  | Provider_error.InvalidRequest _ ->
      "none"

let emit_provider_error_metric ~cascade_name ~provider error =
  let cascade_name = provider_label (cascade_name_to_string cascade_name) in
  let provider = provider_label provider in
  Prometheus.inc_counter provider_error_total_metric
    ~labels:
      [
        ("kind", Provider_error.to_error_kind error);
        ("provider", provider);
        ("cascade_name", cascade_name);
        ("capacity_scope", provider_error_capacity_scope_label error);
      ]
    ()

let emit_sdk_provider_error_metric ~cascade_name ~provider err =
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
let sdk_error_soft_rate_limited (err : Oas.Error.sdk_error)
  : float option option =
  match err with
  | Oas.Error.Api (Llm_provider.Retry.RateLimited { retry_after; _ } as api_err)
    when not (Llm_provider.Retry.is_hard_quota api_err) ->
    Some retry_after
  | _ -> None

let sdk_error_is_max_turns_exceeded (err : Oas.Error.sdk_error) : bool =
  match Oas_worker_named_error.classify_masc_internal_error err with
  | Some
      (Oas_worker_named_error.Cascade_exhausted
         { reason = Keeper_types.Max_turns_exceeded; _ }) ->
      true
  | Some
      (Oas_worker_named_error.Cascade_exhausted
         { reason = Keeper_types.Other_detail detail; _ }) ->
      message_looks_like_cli_wrapped_max_turns detail
  | Some (Oas_worker_named_error.Cascade_exhausted _)
  | Some (Oas_worker_named_error.Resumable_cli_session _)
  | Some (Oas_worker_named_error.No_tool_capable_provider _)
  | Some (Oas_worker_named_error.Accept_rejected _)
  | Some (Oas_worker_named_error.Admission_queue_timeout _)
  | Some (Oas_worker_named_error.Admission_queue_rejected _)
  | Some (Oas_worker_named_error.Turn_timeout _)
  | Some (Oas_worker_named_error.Oas_timeout_budget _)
  | Some (Oas_worker_named_error.Ambiguous_post_commit _) ->
      false
  | None -> (
      match err with
      | Oas.Error.Agent (Oas.Error.MaxTurnsExceeded _) -> true
      | Oas.Error.Api
          (Llm_provider.Retry.NetworkError { message; _ }
          | Llm_provider.Retry.Overloaded { message }
          | Llm_provider.Retry.ServerError { message; _ }
          | Llm_provider.Retry.InvalidRequest { message }
          | Llm_provider.Retry.Timeout { message }) ->
          message_looks_like_cli_wrapped_max_turns message
      | Oas.Error.Api
          (Llm_provider.Retry.RateLimited _
          | Llm_provider.Retry.AuthError _
          | Llm_provider.Retry.NotFound _
          | Llm_provider.Retry.ContextOverflow _) ->
          false
      | Oas.Error.Internal message ->
          message_looks_like_cli_wrapped_max_turns message
      | _ -> false)
