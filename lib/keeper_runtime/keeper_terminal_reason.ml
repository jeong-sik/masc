(* Why a Keeper turn ended, held as the typed value the producer had. The
   receipt writes [to_wire] and reads [failure_class]; no reader turns the
   spelling back into a value. See the [.mli]. *)

type t =
  | Completed
  | Checkpoint
  | Input_required
  | Supervisor_stop
  | External_cancel
  | Phase_not_executable of Keeper_state_machine.phase
  | Registry_phase_missing
  | Failed of Agent_core.Error.t

let wire_provider_error_timeout = "provider_error_timeout"
let wire_provider_error_timeout_prefix = wire_provider_error_timeout ^ ":"
let wire_provider_error_network_prefix = "provider_error_network:"

let wire_provider_error_network_timeout =
  wire_provider_error_network_prefix
  ^ Llm_provider.Http_client.network_error_kind_to_string Llm_provider.Http_client.Timeout
;;

let wire_provider_error_network_timeout_prefix = wire_provider_error_network_timeout ^ ":"
let wire_provider_error_connect_failed_prefix = "provider_error_connect_failed:"

(* A provider connect failure carries no deadline phase, so its timeout code is
   one exact string: the prefix and the kind's own label. *)
let wire_provider_error_connect_failed_timeout =
  wire_provider_error_connect_failed_prefix
  ^ Llm_provider.Http_client.network_error_kind_to_string Llm_provider.Http_client.Timeout
;;

(* An [Internal] or [Internal_carried] error, read once. The spelling and the
   failure class both follow this one chain, so they cannot read the same
   error two ways. *)
type internal_cause =
  | Carried_agent of Agent_core.Error.agent_error
  | Task_skill of Keeper_task_skill_resolution_error.t
  | Session_refused of Keeper_official_client_session_refusal.t
  | Account_refused of Keeper_account_refusal.t
  | Provider_refused of Keeper_provider_refusal.t
  | Masc of Keeper_internal_error.masc_internal_error
  | Opaque_internal

let internal_cause err =
  match Keeper_internal_error.agent_error_of_carried_terminal_effect_failure err with
  | Some agent_error -> Carried_agent agent_error
  | None ->
    (* A turn whose Task Skill pins could not be resolved ends with that
       reason, not as an internal error (#31131). *)
    (match Keeper_task_skill_resolution_error.of_core_error err with
     | Some error -> Task_skill error
     | None ->
       (* An official-client session refusal ends with its own code, not as an
          internal or configuration error (#38402). *)
       (match Keeper_official_client_session_refusal.of_core_error err with
        | Some refusal -> Session_refused refusal
        | None ->
          (match Keeper_account_refusal.of_core_error err with
           | Some refusal -> Account_refused refusal
           | None ->
             (match Keeper_provider_refusal.of_core_error err with
              | Some refusal -> Provider_refused refusal
              | None ->
                (match Keeper_internal_error.classify_masc_internal_error err with
                 | Some error -> Masc error
                 | None -> Opaque_internal)))))
;;

(* ------------------------------------------------------------------ *)
(* Spelling                                                            *)
(* ------------------------------------------------------------------ *)

(* One code per [Agent_core.Error.Api] variant. Collapsing them to one
   "api_error" put keepers stuck on a rate limit, an overload, a server fault
   and an auth refusal behind the same dashboard chip. *)
let api_error_code (err : Agent_core.Error.api_error) =
  match err with
  | Agent_core.Retry.RateLimited _ -> "api_error_rate_limited"
  | Agent_core.Retry.Overloaded _ -> "api_error_overloaded"
  | Agent_core.Retry.ServerError { status; _ } -> Printf.sprintf "api_error_server:%d" status
  | Agent_core.Retry.AuthError _ -> "api_error_auth"
  | Agent_core.Retry.AuthorizationError _ -> "api_error_authorization"
  | Agent_core.Retry.PaymentRequired _ -> "api_error_payment_required"
  | Agent_core.Retry.InvalidRequest _ -> "api_error_invalid_request"
  | Agent_core.Retry.NotFound _ -> "api_error_not_found"
  | Agent_core.Retry.ContextOverflow _ -> "api_error_context_overflow"
  | Agent_core.Retry.InputCapacity { reason; _ } ->
    (match reason with
     | Agent_core.Retry.Serving_constraint_rejected _ ->
       "api_error_input_capacity:serving_constraint_rejected"
     | Agent_core.Retry.Token_measurement_unavailable _ ->
       "api_error_input_capacity:measurement_unavailable")
  | Agent_core.Retry.NetworkError _ -> "api_error_network"
  | Agent_core.Retry.Connect_failed _ -> "api_error_connect_failed"
  | Agent_core.Retry.Timeout _ -> "api_error_timeout"
;;

let terminal_effect_disposition_to_wire effect_disposition =
  match Agent_core.Error.terminal_effect_disposition effect_disposition with
  | Agent_core.Tool_contract.Proven_pre_effect -> "proven_pre_effect"
  | Agent_core.Tool_contract.Proven_post_effect -> "proven_post_effect"
  | Agent_core.Tool_contract.Effect_outcome_unknown -> "effect_outcome_unknown"
;;

let agent_error_code = function
  | Agent_core.Error.UnrecognizedStopReason { reason } ->
    Printf.sprintf "agent_error_unrecognized_stop_reason:%s" reason
  | Agent_core.Error.ToolRoundLimitExceeded { rounds; limit } ->
    Printf.sprintf "agent_error_tool_round_limit_exceeded:rounds=%d,limit=%d" rounds limit
  | Agent_core.Error.HookExecutionFailed { hook_name; stage; _ } ->
    Printf.sprintf "agent_error_hook_execution_failed:hook=%s,stage=%s" hook_name stage
  | Agent_core.Error.TerminalToolEffectFailed
      { tool_use_id; effect_disposition; detail = _ } ->
    Printf.sprintf
      "%s:tool_use_id=%s,effect_disposition=%s"
      Keeper_internal_error.terminal_effect_failed_kind
      tool_use_id
      (terminal_effect_disposition_to_wire effect_disposition)
  | Agent_core.Error.TerminalToolDurabilityFailed
      { invocation; effect_disposition; detail = _ } ->
    Printf.sprintf
      "agent_error_terminal_tool_durability_failed:tool_use_id=%s,effect_disposition=%s"
      (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
      (terminal_effect_disposition_to_wire effect_disposition)
  | Agent_core.Error.InputRequired { request_id; question = _; _ } ->
    Printf.sprintf "agent_error_input_required:request_id=%s" request_id
;;

let provider_timeout_suffix = function
  | None -> ""
  | Some phase -> ":" ^ Llm_provider.Http_client.timeout_phase_to_label phase
;;

let provider_error_code = function
  | Llm_provider.Error.InvalidConfig { field; _ } ->
    "provider_error_invalid_config:" ^ field
  | Llm_provider.Error.ParseError _ -> "provider_error_parse"
  | Llm_provider.Error.ProviderWireError { format; kind; _ } ->
    Printf.sprintf
      "provider_error_wire:%s:%s"
      (Llm_provider.Http_client.provider_wire_format_to_string format)
      (Llm_provider.Http_client.provider_wire_error_kind_to_string kind)
  | Llm_provider.Error.ProviderReportedError { error_type = Some error_type; _ } ->
    Printf.sprintf "provider_error_reported:%s" error_type
  | Llm_provider.Error.ProviderReportedError { error_type = None; _ } ->
    "provider_error_reported"
  | Llm_provider.Error.UnknownVariant { type_name; _ } ->
    Printf.sprintf "provider_error_unknown_variant:%s" type_name
  | Llm_provider.Error.ProviderUnavailable _ -> "provider_error_unavailable"
  | Llm_provider.Error.EmptyCompletion _ -> "provider_error_empty_completion"
  | Llm_provider.Error.RateLimit _ -> "provider_error_rate_limited"
  | Llm_provider.Error.HardQuota _ -> "provider_error_hard_quota"
  | Llm_provider.Error.CapacityExhausted { scope; _ } ->
    Printf.sprintf
      "provider_error_provider_capacity:%s"
      (Llm_provider.Error.capacity_scope_to_string scope)
  | Llm_provider.Error.AuthError _ -> "provider_error_auth"
  | Llm_provider.Error.AuthorizationError _ -> "provider_error_authorization"
  | Llm_provider.Error.ServerError { code; _ } -> Printf.sprintf "provider_error_server:%d" code
  | Llm_provider.Error.NetworkError { kind; timeout_phase; _ } ->
    wire_provider_error_network_prefix
    ^ Llm_provider.Http_client.network_error_kind_to_string kind
    ^ provider_timeout_suffix timeout_phase
  | Llm_provider.Error.Connect_failed { kind; _ } ->
    wire_provider_error_connect_failed_prefix
    ^ Llm_provider.Http_client.network_error_kind_to_string kind
  | Llm_provider.Error.Timeout { timeout_phase; _ } ->
    wire_provider_error_timeout ^ provider_timeout_suffix timeout_phase
  | Llm_provider.Error.InvalidRequest _ -> "provider_error_invalid_request"
  | Llm_provider.Error.NotFound _ -> "provider_error_not_found"
  | Llm_provider.Error.ProviderTerminal { kind; _ } ->
    Printf.sprintf
      "provider_error_terminal:%s"
      (Llm_provider.Error.provider_terminal_reason kind)
;;

let code_of_core_error = function
  | Agent_core.Error.Agent err -> agent_error_code err
  | Agent_core.Error.Api err -> api_error_code err
  | Agent_core.Error.Provider err -> provider_error_code err
  | Agent_core.Error.Mcp _ -> "mcp_error"
  | Agent_core.Error.Config _ -> "config_error"
  | Agent_core.Error.Serialization _ -> "serialization_error"
  | Agent_core.Error.Io _ -> "io_error"
  | Agent_core.Error.Orchestration _ -> "orchestration_error"
  | Agent_core.Error.Media _ -> "media_error"
  | (Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried _) as err ->
    (match internal_cause err with
     | Carried_agent agent_error -> agent_error_code agent_error
     | Task_skill error -> Keeper_task_skill_resolution_error.code error
     | Session_refused refusal -> Keeper_official_client_session_refusal.code refusal
     | Account_refused refusal ->
       "account_refused:" ^ Keeper_account_refusal.to_wire refusal
     | Provider_refused (Keeper_provider_refusal.Key_refused _) ->
       "provider_error_key_refused"
     | Provider_refused (Keeper_provider_refusal.Spawn_refused _) ->
       "provider_error_spawn_refused"
     | Provider_refused (Keeper_provider_refusal.Account_busy _) ->
       "provider_error_account_busy"
     | Masc error -> Keeper_internal_error.kind_of_masc_internal_error error
     | Opaque_internal -> "internal_error")
;;

let to_wire = function
  | Completed -> "success"
  | Checkpoint -> "checkpoint"
  | Input_required -> "input_required"
  | Supervisor_stop -> "supervisor_stop"
  | External_cancel -> "external_cancel"
  | Phase_not_executable phase ->
    "non_executable_phase:" ^ Keeper_state_machine.phase_to_string phase
  | Registry_phase_missing -> "registry_phase_missing"
  | Failed err -> code_of_core_error err
;;

(* ------------------------------------------------------------------ *)
(* Failure class                                                       *)
(* ------------------------------------------------------------------ *)

type provider_retry =
  | Transient
  | Persistent

type failure_class =
  | Runtime_exhausted
  | Config_invalid
  | Authorization_refused
  | Provider_runtime_failure of provider_retry
  | Transcript_corruption
  | Official_client_recovery_required
  | Official_client_session_refused of Keeper_official_client_session_refusal.t
  | Provider_attempt_effect_fenced
  | Tool_correction_lost
  | Accept_rejected
  | Terminal_effect_failed
  | Internal_error
  | No_failure_policy

let failure_class_of_agent_error = function
  | Agent_core.Error.TerminalToolEffectFailed _ -> Terminal_effect_failed
  | Agent_core.Error.UnrecognizedStopReason _
  | Agent_core.Error.ToolRoundLimitExceeded _
  | Agent_core.Error.HookExecutionFailed _
  | Agent_core.Error.TerminalToolDurabilityFailed _
  | Agent_core.Error.InputRequired _ -> No_failure_policy
;;

(* A timeout, a dropped connection and a connection that did not open are
   the transient ones; the keeper's next turn usually gets through. *)
let failure_class_of_api_error (err : Agent_core.Error.api_error) =
  match err with
  | Agent_core.Retry.AuthError _ | Agent_core.Retry.AuthorizationError _ ->
    Authorization_refused
  | Agent_core.Retry.NetworkError _
  | Agent_core.Retry.Connect_failed _
  | Agent_core.Retry.Timeout _ -> Provider_runtime_failure Transient
  | Agent_core.Retry.RateLimited _
  | Agent_core.Retry.Overloaded _
  | Agent_core.Retry.ServerError _
  | Agent_core.Retry.PaymentRequired _
  | Agent_core.Retry.InvalidRequest _
  | Agent_core.Retry.NotFound _
  | Agent_core.Retry.ContextOverflow _
  | Agent_core.Retry.InputCapacity _ -> Provider_runtime_failure Persistent
;;

let retry_of_network_kind = function
  | Llm_provider.Http_client.Timeout -> Transient
  | Llm_provider.Http_client.Connection_refused
  | Llm_provider.Http_client.Dns_failure
  | Llm_provider.Http_client.Unreachable
  | Llm_provider.Http_client.Tls_error
  | Llm_provider.Http_client.Local_resource_exhaustion
  | Llm_provider.Http_client.Connection_reset
  | Llm_provider.Http_client.End_of_file
  | Llm_provider.Http_client.Unknown -> Persistent
;;

let failure_class_of_provider_error = function
  | Llm_provider.Error.InvalidConfig _ -> Config_invalid
  | Llm_provider.Error.AuthError _ | Llm_provider.Error.AuthorizationError _ ->
    Authorization_refused
  | Llm_provider.Error.Timeout _ -> Provider_runtime_failure Transient
  | Llm_provider.Error.NetworkError { kind; _ } | Llm_provider.Error.Connect_failed { kind; _ }
    -> Provider_runtime_failure (retry_of_network_kind kind)
  | Llm_provider.Error.ParseError _
  | Llm_provider.Error.ProviderWireError _
  | Llm_provider.Error.ProviderReportedError _
  | Llm_provider.Error.UnknownVariant _
  | Llm_provider.Error.ProviderUnavailable _
  | Llm_provider.Error.EmptyCompletion _
  | Llm_provider.Error.RateLimit _
  | Llm_provider.Error.HardQuota _
  | Llm_provider.Error.CapacityExhausted _
  | Llm_provider.Error.ServerError _
  | Llm_provider.Error.InvalidRequest _
  | Llm_provider.Error.NotFound _
  | Llm_provider.Error.ProviderTerminal _ -> Provider_runtime_failure Persistent
;;

(* A host stop is an internal error, and a closed runtime connection is a
   provider runtime failure. The three kinds that answer [No_failure_policy]
   have never been observed — zero rows across 189 receipt files and every
   August log — so no disposition is named for them from the constructor name
   alone. *)
let failure_class_of_masc_internal_error error =
  match Keeper_internal_error.wire_kind_of_masc_internal_error error with
  | Keeper_internal_error.Wire_runtime_exhausted -> Runtime_exhausted
  | Keeper_internal_error.Wire_incomplete_tool_transcript -> Transcript_corruption
  | Keeper_internal_error.Wire_provider_attempt_effect_fenced ->
    Provider_attempt_effect_fenced
  | Keeper_internal_error.Wire_tool_correction_lost -> Tool_correction_lost
  | Keeper_internal_error.Wire_official_client_recovery_required ->
    Official_client_recovery_required
  | Keeper_internal_error.Wire_host_stopped_turn -> Internal_error
  | Keeper_internal_error.Wire_runtime_connection_closed ->
    Provider_runtime_failure Persistent
  | Keeper_internal_error.Wire_accept_rejected -> Accept_rejected
  | Keeper_internal_error.Wire_terminal_effect_failed -> Terminal_effect_failed
  | Keeper_internal_error.Wire_internal_unhandled_exception
  | Keeper_internal_error.Wire_internal_bridge_exception
  | Keeper_internal_error.Wire_internal_contract_rejected -> Internal_error
  | Keeper_internal_error.Wire_resumable_cli_session
  | Keeper_internal_error.Wire_receipt_persistence_failed
  | Keeper_internal_error.Wire_gate_replay_repair_required -> No_failure_policy
;;

let failure_class = function
  | Agent_core.Error.Agent err -> failure_class_of_agent_error err
  | Agent_core.Error.Api err -> failure_class_of_api_error err
  | Agent_core.Error.Provider err -> failure_class_of_provider_error err
  | Agent_core.Error.Config _ -> Config_invalid
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Media _ -> No_failure_policy
  | (Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried _) as err ->
    (match internal_cause err with
     | Carried_agent agent_error -> failure_class_of_agent_error agent_error
     | Task_skill _ -> Config_invalid
     | Session_refused refusal -> Official_client_session_refused refusal
     | Account_refused refusal ->
       (match refusal with
        | Keeper_account_refusal.Account_home_unresolved
        | Keeper_account_refusal.Account_home_invalid
        | Keeper_account_refusal.Key_unusable _
        | Keeper_account_refusal.Runtime_reassigned
        | Keeper_account_refusal.Unknown_keeper
        | Keeper_account_refusal.Authorization_not_bootstrapped
        | Keeper_account_refusal.Accounts_disabled -> Config_invalid
        | Keeper_account_refusal.Access_not_published
        | Keeper_account_refusal.Operator_turn_refused
        | Keeper_account_refusal.Authorization_zone_uncertain
        | Keeper_account_refusal.Channel_not_allowed
        | Keeper_account_refusal.Caller_not_authorized
        | Keeper_account_refusal.Pat_expired
        | Keeper_account_refusal.Pat_scope_not_explicit
        | Keeper_account_refusal.Scope_or_grant_refused
        | Keeper_account_refusal.Owner_inactive
        | Keeper_account_refusal.Provider_account_unavailable
        | Keeper_account_refusal.Host_account_refused -> Authorization_refused)
     | Provider_refused (Keeper_provider_refusal.Key_refused _) -> Authorization_refused
     | Provider_refused (Keeper_provider_refusal.Spawn_refused _) ->
       Provider_runtime_failure Persistent
     | Provider_refused (Keeper_provider_refusal.Account_busy _) ->
       Provider_runtime_failure Transient
     | Masc error -> failure_class_of_masc_internal_error error
     | Opaque_internal -> Internal_error)
;;
