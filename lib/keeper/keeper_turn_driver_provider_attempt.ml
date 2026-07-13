(** Provider-attempt provenance and health helpers for keeper turn driver. *)

let provider_attempt_status_of_result = function
  | Ok _ -> "provider_returned"
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionTimeout _)) ->
    "timeout"
  | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionIdleTimeout _)) ->
    "timeout"
  | Error (Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)) -> "timeout"
  | Error (Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)) -> "timeout"
  | Error _ -> "error"

let provider_attempt_exception_kind_of_result = function
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

let sdk_error_is_hard_quota (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Provider (Llm_provider.Error.HardQuota _) -> true
  | Agent_sdk.Error.Api api_err -> Llm_provider.Retry.is_hard_quota api_err
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> false

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
  | Agent_sdk.Error.Api (Llm_provider.Retry.AuthorizationError _)
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
      | Llm_provider.Retry.AuthorizationError _
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
      | Llm_provider.Error.AuthorizationError _
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

let runtime_candidate_label = "runtime"
