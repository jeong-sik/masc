(** Provider-attempt provenance and health helpers for keeper turn driver. *)

let provider_attempt_status_of_result = function
  | Ok _ -> "provider_returned"
  | Error (Agent_sdk.Error.Api (Llm_provider.Retry.Timeout { message }))
    when Keeper_oas_timeout_message.is_structural message ->
    "timeout"
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionTimeout _)) ->
    "timeout"
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionIdleTimeout _)) ->
    "timeout"
  | Error (Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)) -> "timeout"
  | Error (Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)) -> "timeout"
  | Error _ -> "error"

let provider_attempt_exception_kind_of_result = function
  | Error (Agent_sdk.Error.Api (Llm_provider.Retry.Timeout { message }))
    when Keeper_oas_timeout_message.is_structural message ->
    Some "oas_agent_execution_timeout"
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionTimeout _)) ->
    Some "oas_agent_execution_timeout"
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionIdleTimeout _)) ->
    Some "oas_agent_idle_timeout"
  | Error (Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)) ->
    Some "outer_oas_timeout"
  | Error (Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)) ->
    Some "outer_oas_timeout"
  | Ok _ | Error _ -> None

let provider_attempt_status_and_error_of_exception = function
  | Eio.Time.Timeout -> "timeout", "Eio.Time.Timeout"
  | Eio.Cancel.Cancelled inner ->
    ( "cancelled"
    , Printf.sprintf
        "Eio.Cancel.Cancelled(%s)"
        (Printexc.to_string inner) )
  | exn -> "exception", Printexc.to_string exn

type provider_attempt_provenance =
  { model_source : string
  ; resolved_model_source : string
  ; capability_source : string
  ; fallback_authority : string
  ; provider_source_runtime : string option
  }

let base_provider_attempt_provenance =
  { model_source = "named_runtime"
  ; resolved_model_source = "runtime_catalog_binding"
  ; capability_source = "provider_config_from_runtime_catalog"
  ; fallback_authority = "declared_runtime"
  ; provider_source_runtime = None
  }

let provider_attempt_provenance_fields p =
  let base =
    [ ("model_source", `String p.model_source)
    ; ("resolved_model_source", `String p.resolved_model_source)
    ; ("capability_source", `String p.capability_source)
    ; ("fallback_authority", `String p.fallback_authority)
    ]
  in
  match p.provider_source_runtime with
  | None -> base
  | Some source_runtime ->
      ("provider_source_runtime", `String source_runtime) :: base

type provider_attempt_started_record =
  { started_provenance : provider_attempt_provenance
  ; started_is_last : bool
  ; started_per_provider_timeout_s : float option
  ; started_attempt_timeout_source : string
  ; started_attempt_watchdog_source : string
  }

type provider_attempt_finished_record =
  { finished_provenance : provider_attempt_provenance
  ; finished_status : string
  ; finished_latency_ms : float
  ; finished_checkpoint_after_present : bool
  ; finished_error : Yojson.Safe.t
  ; finished_exception_kind : string option
  }

let provider_attempt_started_decision record =
  `Assoc
    (provider_attempt_provenance_fields record.started_provenance
     @ [
         ("is_last", `Bool record.started_is_last);
         ( "per_provider_timeout_s",
           match record.started_per_provider_timeout_s with
           | None -> `Null
           | Some timeout -> `Float timeout );
         ( "attempt_timeout_s",
           match record.started_per_provider_timeout_s with
           | None -> `Null
           | Some timeout -> `Float timeout );
         ("attempt_timeout_source", `String record.started_attempt_timeout_source);
         ("attempt_watchdog_source", `String record.started_attempt_watchdog_source);
       ])
;;

let provider_attempt_finished_decision record =
  let decision_fields =
    [
      ("latency_ms", `Float record.finished_latency_ms);
      ("checkpoint_after_present", `Bool record.finished_checkpoint_after_present);
      ("error", record.finished_error);
    ]
  in
  let decision_fields =
    provider_attempt_provenance_fields record.finished_provenance @ decision_fields
  in
  let decision_fields =
    match record.finished_exception_kind with
    | None -> decision_fields
    | Some kind -> ("exception_kind", `String kind) :: decision_fields
  in
  `Assoc decision_fields
;;

let client_capacity_full_decision ~capacity_key =
  `Assoc
    [ "blocker", `String "client_capacity_full"
    ; "capacity_key", `String capacity_key
    ; "provider_attempt_started", `Bool false
    ]
;;

let success_selected_model_raw candidate =
  Some (Runtime_candidate.model_health_key candidate)

let health_error_kind label =
  Keeper_binding_health.error_kind_of_string label

let scoped_provider_key ~keeper_name provider_key =
  let keeper_name = String.trim keeper_name in
  if String.equal keeper_name "" then provider_key
  else keeper_name ^ "@" ^ provider_key

let scoped_health_keys ~keeper_name candidate =
  Runtime_candidate.health_keys candidate
  |> List.map (scoped_provider_key ~keeper_name)

let credential_pool_health_keys ~keeper_name candidate =
  Runtime_candidate.health_keys candidate
  |> List.concat_map (fun provider_key ->
    let scoped_key = scoped_provider_key ~keeper_name provider_key in
    if String.equal scoped_key provider_key
    then [ provider_key ]
    else [ scoped_key; provider_key ])
  |> List.sort_uniq String.compare

type provider_cooldown_block =
  { blocked_provider_keys : string list
  ; cooldown_remaining_sec : int
  }

let cooldown_remaining_sec_of_info info =
  match info.Keeper_binding_health.cooldown_expires_at with
  | None -> 0
  | Some expires_at ->
    int_of_float (Float.max 0.0 (Float.ceil (expires_at -. Time_compat.now ())))

let provider_cooldown_block ~keeper_name candidate =
  let provider_keys = Runtime_candidate.health_keys candidate in
  let blocking_info_for_key provider_key =
    let scoped_key = scoped_provider_key ~keeper_name provider_key in
    let keys =
      if String.equal scoped_key provider_key
      then [ provider_key ]
      else [ scoped_key; provider_key ]
    in
    keys
    |> List.filter_map (fun provider_key ->
      Keeper_binding_health.provider_info
        Keeper_binding_health.global
        ~provider_key
      |> Option.map (fun info -> (provider_key, info)))
    |> List.find_opt (fun (_, info) -> info.Keeper_binding_health.in_cooldown)
  in
  match provider_keys with
  | [] -> None
  | _ ->
    let provider_infos =
      provider_keys
      |> List.filter_map blocking_info_for_key
    in
    if List.length provider_infos <> List.length provider_keys
    then None
    else
      let cooldown_remaining_sec =
        provider_infos
        |> List.map (fun (_, info) -> cooldown_remaining_sec_of_info info)
        |> function
        | [] -> 0
        | first :: rest -> List.fold_left min first rest
      in
      let blocked_provider_keys = List.map fst provider_infos in
      Some { blocked_provider_keys; cooldown_remaining_sec }

let provider_cooldown_block_decision block =
  `Assoc
    [ "blocker", `String "provider_cooldown"
    ; "provider_attempt_started", `Bool false
    ; ( "blocked_provider_keys"
      , `List (List.map (fun key -> `String key) block.blocked_provider_keys) )
    ; "cooldown_remaining_sec", `Int block.cooldown_remaining_sec
    ; "retry_after_source", `String "provider_health_cooldown"
    ]

let provider_cooldown_block_error ~runtime_id block =
  let retry_after =
    if block.cooldown_remaining_sec > 0
    then
      Keeper_internal_error.Synthetic_default
        (float_of_int block.cooldown_remaining_sec)
    else Keeper_internal_error.No_retry_hint
  in
  Keeper_internal_error.sdk_error_of_masc_internal_error
    (Keeper_internal_error.Capacity_backpressure
       { runtime_id
       ; source = Keeper_internal_error.Provider_capacity
       ; detail = "provider health cooldown active before dispatch"
       ; retry_after
       })

let record_candidate_health_success ~keeper_name candidate ~latency_ms =
  scoped_health_keys ~keeper_name candidate
  |> List.iter (fun provider_key ->
    Keeper_binding_health.record_success
      Keeper_binding_health.global
      ~provider_key
      ~latency_ms
      ())

let record_candidate_health_rejected ~keeper_name candidate ~reason =
  let error_kind = health_error_kind "accept_rejected" in
  scoped_health_keys ~keeper_name candidate
  |> List.iter (fun provider_key ->
    Keeper_binding_health.record_rejected
      Keeper_binding_health.global
      ~provider_key
      ~error_kind
      ~error_reason:reason
      ())

(* Hard-quota SDK error classifiers, re-homed from the deleted runtime attempt
   FSM (RFC-0206).  Generic provider-error classification, not runtime-specific. *)
let api_error_message_for_quota_scan (api_err : Llm_provider.Retry.api_error)
    : string option =
  match api_err with
  | Llm_provider.Retry.RateLimited { message; _ } -> Some message
  | Llm_provider.Retry.PaymentRequired { message } -> Some message
  | Llm_provider.Retry.NetworkError { message; _ } -> Some message
  | Llm_provider.Retry.Overloaded { message } -> Some message
  | Llm_provider.Retry.ServerError { message; _ } -> Some message
  | Llm_provider.Retry.InvalidRequest { message; _ } -> Some message
  | Llm_provider.Retry.AuthError _
  | Llm_provider.Retry.NotFound _
  | Llm_provider.Retry.ContextOverflow _
  | Llm_provider.Retry.Timeout _ -> None

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
  "session usage limit";
  "add extra usage";
  "resets apr ";
  "reached your specified api usage limits";
  "you will regain access on";
]

let message_looks_like_cli_wrapped_hard_quota (message : string) : bool =
  let contains needle = String_util.contains_substring_ci message needle in
  List.exists contains cli_wrapped_hard_quota_indicators
  ||
  (contains "exited with code 1"
   && contains "\"api_error_status\":429"
   && contains "you've hit your limit")

let sdk_error_is_hard_quota (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Provider (Llm_provider.Error.HardQuota _) -> true
  | Agent_sdk.Error.Api api_err ->
    Llm_provider.Retry.is_hard_quota api_err
    ||
    (match api_error_message_for_quota_scan api_err with
     | Some message -> message_looks_like_cli_wrapped_hard_quota message
     | None -> false)
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> false

let capacity_backpressure_indicators = [
  "client capacity";
  "capacity exhausted";
  "local_resource_exhaustion";
  "slot full";
]

let message_looks_like_capacity_backpressure (message : string) : bool =
  let contains needle = String_util.contains_substring_ci message needle in
  List.exists contains capacity_backpressure_indicators

let message_looks_like_terminal_provider_runtime_failure message =
  let contains needle = String_util.contains_substring_ci message needle in
  (contains "provider cli rejected" && contains "exit 1")
  || (contains "provider cli startup crash" && contains "unicodedecodeerror")
  || contains "unicodedecodeerror"
  || (contains "jsonrpcmessage"
      && (contains "validationerror" || contains "invalid json"))
  || (contains "error parsing sse message"
      && (contains "jsonrpc" || contains "jsonrpcmessage"))

let network_error_kind_is_terminal
    (kind : Llm_provider.Http_client.network_error_kind) : bool =
  match kind with
  | Llm_provider.Http_client.Connection_refused -> true
  | Llm_provider.Http_client.Dns_failure -> true
  | Llm_provider.Http_client.Tls_error
  | Llm_provider.Http_client.Timeout
  | Llm_provider.Http_client.Local_resource_exhaustion
  | Llm_provider.Http_client.End_of_file
  | Llm_provider.Http_client.Unknown -> false

let sdk_error_is_terminal_provider_runtime_failure
    (err : Agent_sdk.Error.sdk_error) : bool =
  let direct_typed_network =
    match err with
    | Agent_sdk.Error.Api (Llm_provider.Retry.NotFound _)
    | Agent_sdk.Error.Provider (Llm_provider.Error.NotFound _) ->
        true
    | Agent_sdk.Error.Api (Llm_provider.Retry.NetworkError { kind; _ }) ->
        network_error_kind_is_terminal kind
    | _ -> false
  in
  let direct_api_message =
    match err with
    | Agent_sdk.Error.Api
        (Llm_provider.Retry.NetworkError { message; _ }
        | Llm_provider.Retry.Overloaded { message }
        | Llm_provider.Retry.ServerError { message; _ }
        | Llm_provider.Retry.InvalidRequest { message; _ }
        | Llm_provider.Retry.RateLimited { message; _ }
        | Llm_provider.Retry.PaymentRequired { message }
        | Llm_provider.Retry.AuthError { message }
        | Llm_provider.Retry.NotFound { message }
        | Llm_provider.Retry.ContextOverflow { message; _ }
        | Llm_provider.Retry.Timeout { message }) ->
        message_looks_like_terminal_provider_runtime_failure message
    | _ -> false
  in
  direct_typed_network
  || direct_api_message
  || message_looks_like_terminal_provider_runtime_failure
       (Agent_sdk.Error.to_string err)

(* RFC-0206: runtime rotation is gone, but "max turns exceeded" still surfaces
   as a structured masc_internal_error envelope on a single dispatch. *)
let sdk_error_is_max_turns_exceeded (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some
      (Keeper_internal_error.Runtime_exhausted
         { reason = Keeper_internal_error.Max_turns_exceeded; _ }) -> true
  | Some _ | None -> false

let sdk_error_soft_rate_limited (err : Agent_sdk.Error.sdk_error)
  : float option option =
  match err with
  | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited { retry_after; _ } as api_err)
    when not (Llm_provider.Retry.is_hard_quota api_err) ->
    Some retry_after
  | Agent_sdk.Error.Provider (Llm_provider.Error.RateLimit { retry_after; _ }) ->
    Some retry_after
  | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.Overloaded _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.AuthError _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.PaymentRequired _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.NotFound _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.ContextOverflow _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.NetworkError _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> None

let fallback_class_hard_quota = "hard_quota"
let fallback_class_max_turns = "max_turns"

let sdk_error_runtime_fallback_class (err : Agent_sdk.Error.sdk_error) :
    string option =
  if sdk_error_is_hard_quota err then Some fallback_class_hard_quota
  else if sdk_error_is_max_turns_exceeded err then Some fallback_class_max_turns
  else None

let sdk_error_is_server_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError { status; _ })
    when status >= 500 -> true
  | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError { code; _ })
    when code >= 500 -> true
  | Agent_sdk.Error.Provider (Llm_provider.Error.ProviderUnavailable _) -> true
  | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError _)
  | Agent_sdk.Error.Provider (Llm_provider.Error.ServerError _)
  | Agent_sdk.Error.Api
      ( Llm_provider.Retry.RateLimited _
      | Llm_provider.Retry.Overloaded _
      | Llm_provider.Retry.AuthError _
      | Llm_provider.Retry.PaymentRequired _
      | Llm_provider.Retry.InvalidRequest _
      | Llm_provider.Retry.NotFound _
      | Llm_provider.Retry.ContextOverflow _
      | Llm_provider.Retry.NetworkError _
      | Llm_provider.Retry.Timeout _ )
  | Agent_sdk.Error.Provider
      ( Llm_provider.Error.NetworkError _
      | Llm_provider.Error.Timeout _
      | Llm_provider.Error.RateLimit _
      | Llm_provider.Error.AuthError _
      | Llm_provider.Error.MissingApiKey _
      | Llm_provider.Error.InvalidRequest _
      | Llm_provider.Error.NotFound _
      | Llm_provider.Error.CapacityExhausted _
      | Llm_provider.Error.HardQuota _
      | Llm_provider.Error.ProviderTerminal _
      | Llm_provider.Error.ParseError _
      | Llm_provider.Error.InvalidConfig _
      | Llm_provider.Error.UnknownVariant _ )
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> false

let record_candidate_health_error ~keeper_name candidate sdk_err =
  let error_reason = Agent_sdk.Error.to_string sdk_err in
  let health_keys = Runtime_candidate.health_keys candidate in
  if sdk_error_is_hard_quota sdk_err
  then (
    let error_kind = health_error_kind "hard_quota" in
    credential_pool_health_keys ~keeper_name candidate
    |> List.iter (fun provider_key ->
      Keeper_binding_health.record_hard_quota
        Keeper_binding_health.global
        ~provider_key
        ~error_kind
        ~error_reason
        ()))
  else if sdk_error_is_terminal_provider_runtime_failure sdk_err
  then (
    let error_kind = health_error_kind "terminal_provider_runtime_failure" in
    health_keys
    |> List.iter (fun provider_key ->
      let provider_key = scoped_provider_key ~keeper_name provider_key in
      Keeper_binding_health.record_terminal_failure
        Keeper_binding_health.global
        ~provider_key
        ~error_kind
        ~error_reason
        ()))
  else if sdk_error_is_server_error sdk_err
  then (
    let error_kind = health_error_kind "server_error" in
    health_keys
    |> List.iter (fun provider_key ->
      let provider_key = scoped_provider_key ~keeper_name provider_key in
      Keeper_binding_health.record_server_error
        Keeper_binding_health.global
        ~provider_key
        ~error_kind
        ~error_reason
        ()))
  else
    match sdk_error_soft_rate_limited sdk_err with
    | Some retry_after_s ->
      let error_kind = health_error_kind "soft_rate_limited" in
      credential_pool_health_keys ~keeper_name candidate
      |> List.iter (fun provider_key ->
        Keeper_binding_health.record_soft_rate_limited
          Keeper_binding_health.global
          ~provider_key
          ?retry_after_s
          ~error_kind
          ~error_reason
          ())
    | None ->
      let error_kind = health_error_kind "provider_error" in
      health_keys
      |> List.iter (fun provider_key ->
        let provider_key = scoped_provider_key ~keeper_name provider_key in
        Keeper_binding_health.record_failure
          Keeper_binding_health.global
          ~provider_key
          ~error_kind
          ~error_reason
          ())

let runtime_candidate_label = "runtime"
