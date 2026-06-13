(** SDK error mapping for keeper-managed provider attempts. *)

let retry_message_looks_like_not_found message =
  String_util.contains_substring_ci message "not found"
  || String_util.contains_substring_ci message "status code: 404"
  || String_util.contains_substring_ci message "404 page not found"

let retry_message_looks_like_model_access_denied message =
  String_util.contains_substring_ci message "permission to access"
  || String_util.contains_substring_ci message "not have access to"
  || String_util.contains_substring_ci message "does not have access to"
  || String_util.contains_substring_ci message "not authorized to access"

let capacity_backpressure_source_to_failure_scope = function
  | Keeper_internal_error.Provider_capacity ->
    Llm_provider.Http_client.Failure_scope_provider
  | Keeper_internal_error.Client_capacity ->
    Llm_provider.Http_client.Failure_scope_account
  | Keeper_internal_error.Runtime_slot ->
    Llm_provider.Http_client.Failure_scope_unknown

let provider_error_to_http_error = function
  | Llm_provider.Error.RateLimit { retry_after; detail; _ }
  | Llm_provider.Error.HardQuota { retry_after; detail; _ } ->
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Capacity_exhausted
            { scope = Failure_scope_provider; retry_after; model = None }
      ; message = detail
      }
  | Llm_provider.Error.CapacityExhausted { retry_after; detail; _ } ->
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Capacity_exhausted
            { scope = Failure_scope_provider; retry_after; model = None }
      ; message = detail
      }
  | Llm_provider.Error.AuthError { detail; _ } ->
    Llm_provider.Http_client.HttpError { code = 401; body = detail }
  | Llm_provider.Error.ServerError { code; detail; _ } ->
    Llm_provider.Http_client.HttpError { code; body = detail }
  | Llm_provider.Error.InvalidRequest { reason; _ } ->
    Llm_provider.Http_client.HttpError { code = 400; body = reason }
  | Llm_provider.Error.ProviderTerminal { reason; detail; _ } ->
    let body = if String.trim detail = "" then reason else detail in
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Capability_mismatch
            { capability = Some "permission" }
      ; message = body
      }
  | Llm_provider.Error.NotFound { detail; _ } ->
    Llm_provider.Http_client.HttpError
      { code = 404; body = if String.trim detail = "" then "model not found" else detail }
  | Llm_provider.Error.Timeout { detail; timeout_phase; _ } ->
    Llm_provider.Http_client.TimeoutError
      { message = detail
      ; phase =
          Option.value
            timeout_phase
            ~default:Llm_provider.Http_client.Unknown_timeout
      }
  | Llm_provider.Error.NetworkError { detail; kind; _ } ->
    Llm_provider.Http_client.NetworkError { message = detail; kind }
  | Llm_provider.Error.ParseError { detail } ->
    Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Other "protocol_error"
      ; message = detail
      }
  | Llm_provider.Error.MissingApiKey { var_name } ->
    Llm_provider.Http_client.HttpError
      { code = 401; body = Printf.sprintf "missing API key: %s" var_name }
  | Llm_provider.Error.InvalidConfig { field; detail } ->
    Llm_provider.Http_client.HttpError
      { code = 400; body = Printf.sprintf "%s: %s" field detail }
  | Llm_provider.Error.UnknownVariant { type_name; value } ->
    Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Other "unknown_variant"
      ; message = Printf.sprintf "%s: %s" type_name value
      }
  | Llm_provider.Error.ProviderUnavailable { detail; _ } ->
    Llm_provider.Http_client.NetworkError
      { message = detail; kind = Llm_provider.Http_client.Unknown }

let sdk_error_to_runtime_outcome err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Resumable_cli_session { detail; _ }) ->
    Some
      (Runtime_attempt_fsm.Call_err
         (Llm_provider.Http_client.NetworkError
            { message = detail; kind = Llm_provider.Http_client.Unknown }))
  | Some
      (Keeper_internal_error.Capacity_backpressure { detail; retry_after; source; _ }) ->
    let retry_after =
      match retry_after with
      | Keeper_internal_error.Explicit s -> Some s
      | Synthetic_default _
      | No_retry_hint -> None
    in
    Some
      (Runtime_attempt_fsm.Call_err
         (Llm_provider.Http_client.ProviderFailure
            { kind =
                Llm_provider.Http_client.Capacity_exhausted
                  { scope = capacity_backpressure_source_to_failure_scope source
                  ; retry_after
                  ; model = None
                  }
            ; message = detail
            }))
  | Some _
  | None ->
    (match err with
     | Agent_sdk.Error.Api api_err ->
       let http_err =
         match api_err with
         | Llm_provider.Retry.InvalidRequest { message } ->
           if retry_message_looks_like_model_access_denied message
           then
             Llm_provider.Http_client.ProviderFailure
               { kind =
                   Llm_provider.Http_client.Capability_mismatch
                     { capability = Some "model_access" }
               ; message
               }
           else
             let code = if retry_message_looks_like_not_found message then 404 else 400 in
             Llm_provider.Http_client.HttpError { code; body = message }
         | ContextOverflow { message; _ } ->
           Llm_provider.Http_client.HttpError { code = 400; body = message }
         | RateLimited { message; _ } ->
           Llm_provider.Http_client.HttpError { code = 429; body = message }
         | NotFound { message } ->
           Llm_provider.Http_client.HttpError { code = 404; body = message }
         | ServerError { status; message } ->
           Llm_provider.Http_client.HttpError { code = status; body = message }
         | AuthError { message } ->
           Llm_provider.Http_client.HttpError { code = 401; body = message }
         | Overloaded { message } ->
           Llm_provider.Http_client.HttpError { code = 529; body = message }
         | NetworkError { message; kind } ->
           Llm_provider.Http_client.NetworkError { message; kind }
         | Timeout { message } ->
           Llm_provider.Http_client.NetworkError
             { message; kind = Llm_provider.Http_client.Timeout }
       in
       Some (Runtime_attempt_fsm.Call_err http_err)
     | Agent_sdk.Error.Provider provider_err ->
       Some (Runtime_attempt_fsm.Call_err (provider_error_to_http_error provider_err))
     | Agent_sdk.Error.Agent (Agent_sdk.Error.UnrecognizedStopReason { reason }) ->
       Some
         (Runtime_attempt_fsm.Call_err
            (Llm_provider.Http_client.AcceptRejected { reason }))
    | Agent_sdk.Error.Config
        (Agent_sdk.Error.InvalidConfig { field = "runtime_mcp_auth"; detail }) ->
       Some
         (Runtime_attempt_fsm.Call_err
            (Llm_provider.Http_client.AcceptRejected { reason = detail }))
     | Agent_sdk.Error.Agent _
     | Agent_sdk.Error.Config _
     | Agent_sdk.Error.Mcp _
     | Agent_sdk.Error.Serialization _
     | Agent_sdk.Error.Io _
     | Agent_sdk.Error.Orchestration _
     | Agent_sdk.Error.Internal _ -> None)

let sdk_error_is_model_access_denied err =
  match sdk_error_to_runtime_outcome err with
  | Some
      (Runtime_attempt_fsm.Call_err
         (Llm_provider.Http_client.ProviderFailure
            { kind =
                Llm_provider.Http_client.Capability_mismatch
                  { capability = Some "model_access" }
            ; _
            })) -> true
  | _ -> false

let provider_auth_hint_marker = "Provider auth returned 401"
let openai_compat_not_found_hint_marker = "OpenAI-compatible endpoint returned 404"

let resolve_provider_api_key_env_name ~runtime_id:_ ~provider_cfg =
  Llm_provider.Provider_config.default_api_key_env
    provider_cfg.Llm_provider.Provider_config.kind
  |> Option.value ~default:""

let enrich_sdk_error ~runtime_id ~(provider_cfg : Llm_provider.Provider_config.t) err =
  let append_hint message hint_marker detail =
    if String_util.contains_substring_ci message hint_marker
    then message
    else Printf.sprintf "%s (%s: %s)" message hint_marker detail
  in
  match err with
  | Agent_sdk.Error.Api (Llm_provider.Retry.AuthError { message }) ->
    let env_name =
      match resolve_provider_api_key_env_name ~runtime_id ~provider_cfg with
      | "" -> "configured provider API key env"
      | value -> value
    in
    let detail =
      if String.trim provider_cfg.Llm_provider.Provider_config.api_key = ""
      then Printf.sprintf "%s is empty or unset in this process" env_name
      else
        Printf.sprintf
          "%s was loaded and the auth header was populated; verify that it is valid for the configured provider"
          env_name
    in
    Agent_sdk.Error.Api
      (Llm_provider.Retry.AuthError
         { message = append_hint message provider_auth_hint_marker detail })
  | Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest { message })
    when retry_message_looks_like_not_found message ->
    let detail =
      Printf.sprintf
        "base_url=%s request_path=%s endpoint=%s"
        provider_cfg.Llm_provider.Provider_config.base_url
        provider_cfg.Llm_provider.Provider_config.request_path
        (provider_cfg.Llm_provider.Provider_config.base_url
         ^ provider_cfg.Llm_provider.Provider_config.request_path)
    in
    Agent_sdk.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message =
             append_hint message openai_compat_not_found_hint_marker detail
         })
  | _ -> err

let cli_wrapped_hard_quota_indicators =
  [ "hard_quota"
  ; "terminalquotaerror"
  ; "quota_exhausted"
  ; "exhausted your capacity on this model"
  ; "quota will reset after"
  ; "\"api_error_status\":429"
  ; "you've hit your limit"
  ; "monthly usage limit"
  ; "org's monthly usage limit"
  ; "reached your specified api usage limits"
  ; "you will regain access on"
  ]

let message_looks_like_cli_wrapped_hard_quota message =
  List.exists
    (fun needle -> String_util.contains_substring_ci message needle)
    cli_wrapped_hard_quota_indicators

let capacity_backpressure_indicators =
  [ "client capacity"; "capacity exhausted"; "local_resource_exhaustion"; "slot full" ]

let message_looks_like_capacity_backpressure message =
  List.exists
    (fun needle -> String_util.contains_substring_ci message needle)
    capacity_backpressure_indicators

let exit_code_of_message message =
  let prefix = "exited with code " in
  match String.index_opt message ' ' with
  | None -> None
  | Some first_space ->
    let search_from = first_space + 1 in
    if search_from >= String.length message
    then None
    else
      let suffix =
        String.sub message search_from (String.length message - search_from)
      in
      if not (String.starts_with ~prefix suffix)
      then None
      else
        match String.index_from_opt suffix (String.length prefix) ':' with
        | None -> None
        | Some colon ->
          String.sub suffix (String.length prefix) (colon - String.length prefix)
          |> String.trim
          |> int_of_string_opt

let sdk_error_is_resumable_cli_session err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Resumable_cli_session _) -> true
  | _ -> false

let message_looks_like_terminal_provider_runtime_failure message =
  let contains needle = String_util.contains_substring_ci message needle in
  (contains "provider cli rejected" && contains "exit 1")
  || (contains "provider cli startup crash" && contains "unicodedecodeerror")
  || contains "unicodedecodeerror"
  || (contains "jsonrpcmessage"
      && (contains "validationerror" || contains "invalid json"))
  || (contains "error parsing sse message"
      && (contains "jsonrpc" || contains "jsonrpcmessage"))

let sdk_error_is_terminal_provider_runtime_failure = function
  | Agent_sdk.Error.Internal message
  | Agent_sdk.Error.Api (Llm_provider.Retry.NetworkError { message; _ })
  | Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest { message }) ->
    message_looks_like_terminal_provider_runtime_failure message
  | _ -> false

let sdk_error_is_hard_quota = function
  | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited _ as err)
    when Llm_provider.Retry.is_hard_quota err -> true
  | Agent_sdk.Error.Api
      (Llm_provider.Retry.RateLimited { message; _ }
      | InvalidRequest { message }
      | NetworkError { message; _ }
      | Overloaded { message }
      | ServerError { message; _ }) ->
    message_looks_like_cli_wrapped_hard_quota message
  | _ -> false

let retry_api_error_to_provider_error ~provider:_ ~capacity_backpressure api_err =
  match api_err with
  | Llm_provider.Retry.RateLimited { retry_after; _ } ->
    Some (Provider_error.RateLimit { retry_after })
  | Overloaded _ when capacity_backpressure ->
    Some (Provider_error.CapacityBackpressure { scope = `Provider })
  | AuthError _ -> Some Provider_error.AuthError
  | NotFound _ -> Some Provider_error.ModelNotFound
  | InvalidRequest { message } -> Some (Provider_error.InvalidRequest { reason = message })
  | ServerError { status; _ } ->
    Some (Provider_error.ServerError { code = status; transient = status >= 500 })
  | ContextOverflow _
  | NetworkError _
  | Timeout _
  | Overloaded _ -> None

let sdk_error_to_provider_error ~provider = function
  | Agent_sdk.Error.Api api_err ->
    retry_api_error_to_provider_error
      ~provider
      ~capacity_backpressure:false
      api_err
  | Agent_sdk.Error.Provider (Llm_provider.Error.CapacityExhausted _) ->
    Some (Provider_error.CapacityBackpressure { scope = `Provider })
  | Agent_sdk.Error.Provider (Llm_provider.Error.RateLimit { retry_after; _ }) ->
    Some (Provider_error.RateLimit { retry_after })
  | Agent_sdk.Error.Provider (Llm_provider.Error.AuthError _) ->
    Some Provider_error.AuthError
  | Agent_sdk.Error.Provider (Llm_provider.Error.InvalidRequest { reason; _ }) ->
    Some (Provider_error.InvalidRequest { reason })
  | Agent_sdk.Error.Provider (Llm_provider.Error.ProviderTerminal { detail; _ }) ->
    Some (Provider_error.PermissionDenied { resource = Some detail })
  | Agent_sdk.Error.Provider (Llm_provider.Error.NotFound _) ->
    Some Provider_error.ModelNotFound
  | _ -> None

let provider_error_total_metric = "masc_provider_error_total"
let label_kind = "kind"
let label_runtime = "runtime_id"

let provider_label label =
  let label = String.trim label in
  if label = "" then "unknown_provider" else label

let emit_provider_error_metric ~runtime_id ~provider error =
  Otel_metric_store.inc_counter
    provider_error_total_metric
    ~labels:
      [ label_kind, Provider_error.to_error_kind error
      ; label_runtime, runtime_id
      ; "provider", provider_label provider
      ]
    ()

let emit_sdk_provider_error_metric ~runtime_id ~provider err =
  match sdk_error_to_provider_error ~provider err with
  | None -> None
  | Some provider_error ->
    emit_provider_error_metric ~runtime_id ~provider provider_error;
    Some provider_error

let sdk_error_soft_rate_limited = function
  | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited { retry_after; _ } as err) ->
    if Llm_provider.Retry.is_hard_quota err then None else Some retry_after
  | Agent_sdk.Error.Provider (Llm_provider.Error.RateLimit { retry_after; _ }) ->
    Some retry_after
  | _ -> None

type capacity_backpressure_retry_hint =
  | Cbr_explicit of float
  | Cbr_synthetic_default of float

let sdk_error_capacity_backpressure_source err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Capacity_backpressure { source; _ }) -> Some source
  | _ -> None

let sdk_error_capacity_backpressure_retry_hint err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Capacity_backpressure { retry_after = Explicit s; _ }) ->
    Some (Cbr_explicit s)
  | Some
      (Keeper_internal_error.Capacity_backpressure
         { retry_after = Synthetic_default s; _ }) -> Some (Cbr_synthetic_default s)
  | _ -> None

let sdk_error_capacity_backpressure_retry_after_s = function
  | Agent_sdk.Error.Provider (Llm_provider.Error.CapacityExhausted { retry_after; _ }) ->
    Some retry_after
  | _ -> None

let sdk_error_is_max_turns_exceeded = function
  | Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded _) -> true
  | _ -> false

let sdk_error_runtime_fallback_class err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some internal -> Some (Keeper_internal_error.kind_of_masc_internal_error internal)
  | None when sdk_error_is_hard_quota err -> Some "hard_quota"
  | None when sdk_error_is_max_turns_exceeded err -> Some "max_turns"
  | None -> None
