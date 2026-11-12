module Exact = Agent_core.Exact_output
module Http = Agent_core.Llm_provider.Http_client

type input_refusal =
  | Request_body
  | Invalid_request
  | Context_overflow
  | Input_capacity

type t =
  | Transient
  | Auth_refused
  | Configuration_refused
  | Input_refused of input_refusal
  | Output_unusable
  | Output_limit

let is_transient = function
  | Transient -> true
  | Auth_refused | Configuration_refused | Input_refused _ | Output_unusable | Output_limit -> false

(* The refusals that name the size come first, in the order
   [Keeper_librarian_input_refusal.rank] gives them; [Invalid_request] names
   no cause and comes last. *)
let ending_precedence = [ Context_overflow; Input_capacity; Request_body; Invalid_request ]

let ending_input_refusal failures =
  List.find_opt (fun kind -> List.mem (Input_refused kind) failures) ending_precedence

(* A quota or billing refusal that states when the account may be called
   again is transient: the slot waits for that time, and a slot held for it
   ends as this call did (RFC-exact-lane-waits-for-a-stated-reset R5).
   Without a stated time the operator has to change the account. *)
let account_refusal retry_after =
  match Keeper_runtime_failure_route.usable_retry_after retry_after with
  | Some _ -> Transient
  | None -> Configuration_refused

let refusal ~retry_after_s = function
  | Exact.Rate_limited | Exact.Overloaded | Exact.Server_error | Exact.Network_error | Exact.Timeout
  | Exact.Refusal_body_not_received -> Transient
  | Exact.Auth_failed | Exact.Authorization_refused -> Auth_refused
  | Exact.Payment_required -> account_refusal retry_after_s
  | Exact.Not_found -> Configuration_refused
  | Exact.Request_body_refused -> Input_refused Request_body
  | Exact.Invalid_request -> Input_refused Invalid_request
  | Exact.Context_overflow -> Input_refused Context_overflow
  | Exact.Input_capacity -> Input_refused Input_capacity

(* The provider failures without their own answer here are transient exactly
   when AGENT_CORE's retry policy says so; otherwise they keep the class their
   variant names. A failure with no named cause then reads as
   [Configuration_refused] (see the mli). *)
let completion (error : Http.http_error) =
  let unless_retryable failure =
    if Agent_core.Llm_provider.Error.is_retryable (Agent_core.Llm_provider.Error.of_http_error error)
    then Transient
    else failure
  in
  match error with
  | Http.ProviderFailure { kind = Http.Hard_quota { retry_after }; _ } -> account_refusal retry_after
  | Http.ProviderFailure
      { kind = Http.Capacity_exhausted _ | Http.Provider_interrupted | Http.Provider_reported_error _; _ } ->
    Transient
  | Http.HttpError _ | Http.NetworkError _ | Http.TimeoutError _ | Http.AcceptRejected _ | Http.ProviderTerminal _
  | Http.ProviderFailure
      { kind =
          ( Http.Capability_mismatch _ | Http.Cli_policy_invalid _ | Http.Cli_startup_failed _
          | Http.Unknown_provider_failure _ )
      ; _ } -> unless_retryable Configuration_refused
  | Http.ProviderFailure
      { kind =
          ( Http.Provider_parse_error _ | Http.Provider_wire_error _ | Http.Response_body_too_large _
          | Http.Empty_completion _  )
      ; _ } -> unless_retryable Output_unusable
  | Http.ProviderFailure { kind = Http.Context_overflow _; _ } -> unless_retryable (Input_refused Context_overflow)

let execution = function
  | Exact.Provider_response_refused { refusal = provider_refusal; retry_after_s; _ } ->
    refusal ~retry_after_s provider_refusal
  | Exact.Completion_failed { error; _ } -> completion error
  | Exact.Response_body_deadline_exceeded -> Transient
  | Exact.Output_limit_reached -> Output_limit
  | Exact.Incomplete_output | Exact.Missing_output | Exact.Ambiguous_output _
  | Exact.Unexpected_output_content | Exact.Invalid_json_output -> Output_unusable

let candidate rejection =
  match Exact.candidate_rejection_disposition rejection with
  | Exact.Request_preparation_failed -> Transient
  | Exact.Runtime_slot_unavailable | Exact.Runtime_contract_rejected | Exact.Output_requirement_rejected ->
    Configuration_refused
  | Exact.Input_contract_rejected -> Input_refused Invalid_request
  | Exact.Input_capacity (Exact.Context_window_exceeded _
      | Exact.Token_capacity_rejected (Exact.Capacity_input_rejected _)) -> Input_refused Input_capacity
  | Exact.Input_capacity (Exact.Token_measurement_required _
      | Exact.Token_capacity_rejected (Exact.Capacity_evidence_not_yet_valid _
          | Exact.Capacity_evidence_expired _ | Exact.Capacity_boundary_unknown _)) -> Transient

let codex_error = function
  | Runtime_codex_app_server.Invalid_config _
  | Runtime_codex_app_server.Subscription_required _
  | Runtime_codex_app_server.Unsupported_server_request _ -> Configuration_refused
  | Runtime_codex_app_server.Context_window_exceeded _ -> Input_refused Context_overflow
  | Runtime_codex_app_server.Rpc_error {code=Some (-32700 | -32600 | -32601 | -32602);_} -> Configuration_refused
  | Runtime_codex_app_server.Rpc_error _ as error ->
    (match Runtime_codex_app_server.input_capacity_refusal error with
     | Some _ -> Input_refused Input_capacity | None -> Transient)
  | Runtime_codex_app_server.Turn_failed {codex_error_info=Some info;_} ->
    (match info with
     | Runtime_codex_app_server.Codex_error_info.Cyber_policy
     | Runtime_codex_app_server.Codex_error_info.Misalignment_policy_violation
     | Runtime_codex_app_server.Codex_error_info.Bad_request -> Input_refused Invalid_request
     | Runtime_codex_app_server.Codex_error_info.Unauthorized -> Auth_refused
     | Runtime_codex_app_server.Codex_error_info.Session_budget_exceeded
     | Runtime_codex_app_server.Codex_error_info.Usage_limit_exceeded
     | Runtime_codex_app_server.Codex_error_info.Rate_limit_exceeded
     | Runtime_codex_app_server.Codex_error_info.Server_overloaded
     | Runtime_codex_app_server.Codex_error_info.Internal_server_error
     | Runtime_codex_app_server.Codex_error_info.Thread_rollback_failed
     | Runtime_codex_app_server.Codex_error_info.Sandbox_error
     | Runtime_codex_app_server.Codex_error_info.Other
     | Runtime_codex_app_server.Codex_error_info.Http_connection_failed _
     | Runtime_codex_app_server.Codex_error_info.Response_stream_connection_failed _
     | Runtime_codex_app_server.Codex_error_info.Response_stream_disconnected _
     | Runtime_codex_app_server.Codex_error_info.Response_too_many_failed_attempts _
     | Runtime_codex_app_server.Codex_error_info.Active_turn_not_steerable _
     | Runtime_codex_app_server.Codex_error_info.Unrecognized _ -> Transient)
  (* Admission also wraps transient model/list transport failures. *)
  | Runtime_codex_app_server.Reasoning_effort_admission_failed _
  | Runtime_codex_app_server.Account_read_failed _
  | Runtime_codex_app_server.Turn_failed {codex_error_info=None;_}
  | Runtime_codex_app_server.Spawn_failed _
  | Runtime_codex_app_server.Turn_input_write_failed _
  | Runtime_codex_app_server.Protocol_error _
  | Runtime_codex_app_server.Stopped_by_host _
  | Runtime_codex_app_server.Turn_interrupted
  | Runtime_codex_app_server.Runtime_shutting_down
  | Runtime_codex_app_server.Process_exited _
  | Runtime_codex_app_server.Timeout _ -> Transient

let claude_error = function
  | Runtime_claude_code.Invalid_config _
  | Runtime_claude_code.Subscription_required _
  | Runtime_claude_code.Unsupported_control_request _ -> Configuration_refused
  | Runtime_claude_code.Context_window_exceeded _ -> Input_refused Context_overflow
  | Runtime_claude_code.Spawn_failed _
  | Runtime_claude_code.Protocol_error _
  | Runtime_claude_code.Turn_transport_interrupted _
  | Runtime_claude_code.Turn_failed _
  | Runtime_claude_code.Turn_failed_with_observation _
  | Runtime_claude_code.Stopped_by_host _
  | Runtime_claude_code.Quota_blocked _
  | Runtime_claude_code.Process_exited _
  | Runtime_claude_code.Unhandled_exception _
  | Runtime_claude_code.Timeout _ -> Transient

let antigravity_error = function
  | Runtime_antigravity.Invalid_config _ -> Configuration_refused
  | Runtime_antigravity.Result_not_completed _ -> Output_unusable
  (* The same request meets the same permission rules, so a retry ends on
     the same refusal. *)
  | Runtime_antigravity.Actions_denied _ -> Output_unusable
  (* A counted breach is deterministic — the same turn re-kills — so the
     workspace needs operator action, not a retry. A pressure refusal may
     pass with the pressure, so it stays transient. *)
  | Runtime_antigravity.Child_fd_ceiling_exceeded { count = None; _ } -> Transient
  | Runtime_antigravity.Child_fd_ceiling_exceeded { count = Some _; _ } -> Configuration_refused
  | Runtime_antigravity.Spawn_failed _
  | Runtime_antigravity.Protocol_error _
  | Runtime_antigravity.State_callback_failed _
  | Runtime_antigravity.Turn_failed _
  | Runtime_antigravity.Process_exited _
  | Runtime_antigravity.Unhandled_exception _
  | Runtime_antigravity.Timeout _ -> Transient

let muse_error = function
  | Runtime_muse_serve.Invalid_config _
  | Runtime_muse_serve.Capability_not_granted _
  | Runtime_muse_serve.Session_not_durable
  | Runtime_muse_serve.Session_model_mismatch _
  | Runtime_muse_serve.Session_workspace_mismatch _
  | Runtime_muse_serve.Session_approval_mode_mismatch _
  | Runtime_muse_serve.Unsupported_server_request _ -> Configuration_refused
  | Runtime_muse_serve.Auth_required _ -> Auth_refused
  | Runtime_muse_serve.Turn_failed { quota = Some quota; _ } ->
    if float_of_int quota.resets_at_ms /. 1000. > Time_compat.now ()
    then Transient
    else Configuration_refused
  | Runtime_muse_serve.Turn_failed error ->
    if error.Runtime_muse_msp.retryable then Transient else Configuration_refused
  | Runtime_muse_serve.Spawn_failed _
  | Runtime_muse_serve.Turn_input_write_failed _
  | Runtime_muse_serve.Protocol_error _
  | Runtime_muse_serve.Rpc_error _
  | Runtime_muse_serve.Turn_cancelled
  | Runtime_muse_serve.Runtime_shutting_down
  | Runtime_muse_serve.Process_exited _
  | Runtime_muse_serve.Timeout _ -> Transient

let cli_failure = function
  (* Not called before the time its provider stated. The same request may
     pass after it with nothing changed: the class the account's own rest
     refusal has (RFC-exact-lane-waits-for-a-stated-reset R5). *)
  | Keeper_lane_cli_oneshot.Held _ -> Transient
  | Keeper_lane_cli_oneshot.Unknown_runtime _
  | Keeper_lane_cli_oneshot.Not_an_official_client _ -> Configuration_refused
  | Keeper_lane_cli_oneshot.Invalid_json_output _
  | Keeper_lane_cli_oneshot.Invalid_domain_output _ -> Output_unusable
  | Keeper_lane_cli_oneshot.Execution_failed {cause;_} ->
    (match cause with
     | Fusion_official_client.Missing_reply -> Output_unusable
     | Fusion_official_client.Setup_failure _ -> Configuration_refused
     | Fusion_official_client.Codex_failure error -> codex_error error
     | Fusion_official_client.Claude_failure error
     | Fusion_official_client.Claude_admission_failure error -> claude_error error
     | Fusion_official_client.Antigravity_failure error -> antigravity_error error
     | Fusion_official_client.Muse_failure error -> muse_error error
     (* The load check refuses a Vibe runtime in [slots] and [cli_slots]
        (Client_without_output_schema), so a Vibe failure here means that
        check no longer holds. *)
     | Fusion_official_client.Vibe_failure _ -> Configuration_refused)
