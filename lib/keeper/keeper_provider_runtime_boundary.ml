(** Provider/runtime failure boundary for SDK errors crossing from OAS into
    keeper policy. *)

type timeout_source =
  | Oas_api
  | Oas_provider
  | Masc_internal

type provider_timeout =
  { phase : Keeper_failure_policy.timeout_phase option
  ; source : timeout_source
  }

type t =
  | Provider_timeout of provider_timeout
  | Not_provider_runtime_failure

let timeout_phase_of_label label =
  Keeper_failure_policy.timeout_phase_of_label label
;;

let timeout_phase_of_oas_phase phase =
  Llm_provider.Http_client.timeout_phase_to_label phase
  |> timeout_phase_of_label
;;

let timeout_phase_of_masc_internal_phase phase =
  let phase = String.trim phase in
  if String.equal phase "" then None else timeout_phase_of_label phase
;;

let provider_timeout ~source ~phase =
  Provider_timeout { source; phase }
;;

let classify_masc_internal_error = function
  | Some (Keeper_internal_error.Provider_timeout { phase; _ }) ->
    provider_timeout
      ~source:Masc_internal
      ~phase:(timeout_phase_of_masc_internal_phase phase)
  | Some
      ( Keeper_internal_error.Runtime_exhausted _
      | Keeper_internal_error.Capacity_backpressure _
      | Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Accept_rejected _
      | Keeper_internal_error.Admission_queue_timeout _
      | Keeper_internal_error.Admission_queue_rejected _
      | Keeper_internal_error.Turn_timeout _
      | Keeper_internal_error.Max_tokens_ceiling_violation _
      | Keeper_internal_error.Ambiguous_post_commit _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _ )
  | None ->
    Not_provider_runtime_failure
;;

let classify_provider_error = function
  | Llm_provider.Error.Timeout { timeout_phase; _ } ->
    provider_timeout
      ~source:Oas_provider
      ~phase:(Option.bind timeout_phase timeout_phase_of_oas_phase)
  | Llm_provider.Error.NetworkError { timeout_phase = Some phase; _ } ->
    provider_timeout
      ~source:Oas_provider
      ~phase:(timeout_phase_of_oas_phase phase)
  | Llm_provider.Error.MissingApiKey _
  | Llm_provider.Error.InvalidConfig _
  | Llm_provider.Error.ParseError _
  | Llm_provider.Error.UnknownVariant _
  | Llm_provider.Error.ProviderUnavailable _
  | Llm_provider.Error.RateLimit _
  | Llm_provider.Error.HardQuota _
  | Llm_provider.Error.CapacityExhausted _
  | Llm_provider.Error.AuthError _
  | Llm_provider.Error.ServerError _
  | Llm_provider.Error.NetworkError _
  | Llm_provider.Error.InvalidRequest _
  | Llm_provider.Error.NotFound _
  | Llm_provider.Error.ProviderTerminal _ ->
    Not_provider_runtime_failure
;;

let classify_sdk_error (err : Agent_sdk.Error.sdk_error) : t =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some _ as internal_error -> classify_masc_internal_error internal_error
  | None ->
    (match err with
     | Agent_sdk.Error.Api (Timeout _) ->
       provider_timeout ~source:Oas_api ~phase:None
     | Agent_sdk.Error.Provider provider_error ->
       classify_provider_error provider_error
     | Agent_sdk.Error.Api (NetworkError _ | Overloaded _ | ServerError _
       | RateLimited _ | AuthError _ | InvalidRequest _ | NotFound _
       | ContextOverflow _)
     | Agent_sdk.Error.Agent _
     | Agent_sdk.Error.Mcp _
     | Agent_sdk.Error.Config _
     | Agent_sdk.Error.Serialization _
     | Agent_sdk.Error.Io _
     | Agent_sdk.Error.Orchestration _
     | Agent_sdk.Error.Internal _ ->
       Not_provider_runtime_failure)
;;

let is_provider_timeout = function
  | Provider_timeout _ -> true
  | Not_provider_runtime_failure -> false
;;

let is_provider_timeout_error err =
  classify_sdk_error err |> is_provider_timeout
;;

let provider_timeout_failure ~strikes ~liveness (timeout : provider_timeout) =
  Keeper_failure_policy.Provider_timeout
    { phase = timeout.phase; strikes; liveness }
;;

let provider_timeout_policy_decision ~strikes ~liveness err =
  match classify_sdk_error err with
  | Provider_timeout timeout ->
    Some
      (Keeper_failure_policy.decide
         (provider_timeout_failure ~strikes:(Some strikes) ~liveness timeout))
  | Not_provider_runtime_failure -> None
;;
