module Exact = Agent_core.Exact_output
module Http_client = Llm_provider.Http_client

type http =
  | Held
  | Rejected_before_dispatch of Exact.candidate_rejection_disposition
  | Execution_failed of Exact.execution_error_cause
  | Answer_rejected of Librarian_answer.rejection

type cli =
  | Cli_failed of Keeper_lane_cli_oneshot.failure
  | Cli_answer_rejected of Librarian_answer.rejection
  | Cli_seats_full
  | Cli_unservable

type unanswered =
  | Not_visited
  | Http of http
  | Cli of cli

type t =
  | Answer_accepted
  | Unanswered of unanswered

(* One function per type of the slot-outcome table, each defined before the
   functions that call it. An arm that calls another of them is a
   "> file type" row of the table. *)

let token_capacity (rejection : Exact.token_capacity_rejection) : Librarian_slot_outcome.unanswered =
  match rejection with
  | Capacity_input_rejected _ -> Refused (Sized Input_too_large)
  | Capacity_evidence_not_yet_valid _ | Capacity_evidence_expired _
  | Capacity_boundary_unknown _ -> Silent Unavailable

let input_capacity (disposition : Exact.input_capacity_disposition) : Librarian_slot_outcome.unanswered =
  match disposition with
  | Context_window_exceeded _ -> Refused (Sized Input_too_large)
  | Token_capacity_rejected rejection -> token_capacity rejection
  | Token_measurement_required _ -> Silent Unavailable

let rejected (disposition : Exact.candidate_rejection_disposition) : Librarian_slot_outcome.unanswered =
  match disposition with
  | Input_capacity disposition -> input_capacity disposition
  | Seats_full -> Silent Not_called
  | Runtime_slot_unavailable | Runtime_contract_rejected | Input_contract_rejected
  | Output_requirement_rejected | Request_preparation_failed -> Silent Unavailable

let provider_refusal (refusal : Exact.provider_refusal) : Librarian_slot_outcome.unanswered =
  match refusal with
  | Request_body_refused | Context_overflow -> Refused (Sized Input_too_large)
  | Invalid_request -> Refused Unsized
  | Rate_limited | Overloaded | Server_error -> Silent Busy
  | Auth_failed | Authorization_refused | Payment_required | Unclassified_status | Not_found
  | Input_capacity -> Silent Unavailable
  | Refusal_body_not_received | Network_error | Connect_failed | Timeout -> Silent Lost

let incomplete_stop (stop : Exact.incomplete_stop) : Librarian_slot_outcome.unanswered =
  match stop with
  | Refusal | Content_filter -> Refused Unsized
  | End_turn | Tool_use | Stop_sequence | Repetition_truncation | Pause_turn | Compaction
  | Unmatched_tool_calls | Unknown_stop _ -> Silent (Unusable Empty_or_partial)

let stop_reason (stop : Llm_provider.Types.stop_reason) : Librarian_slot_outcome.unanswered =
  match stop with
  | MaxTokens -> Refused (Sized Output_over_reserve)
  | ContextWindowExceeded -> Refused (Sized Window_reached)
  | Refusal | ContentFilter -> Refused Unsized
  | EndTurn | StopToolUse | StopSequence | RepetitionTruncation | PauseTurn | Compaction
  | UnmatchedToolCalls | Unknown _ -> Silent (Unusable Empty_or_partial)

let provider_terminal (kind : Http_client.provider_terminal_kind) : Librarian_slot_outcome.unanswered =
  match kind with
  | Session_conflict -> Silent Unavailable
  | Other _ -> Silent Lost

let provider_failure (kind : Http_client.provider_failure_kind) : Librarian_slot_outcome.unanswered =
  match kind with
  | Context_overflow _ -> Refused (Sized Input_too_large)
  | Empty_completion { stop_reason = stop } -> stop_reason stop
  | Capacity_exhausted _ | Hard_quota _ -> Silent Busy
  | Capability_mismatch _ | Cli_policy_invalid _ | Cli_startup_failed _ -> Silent Unavailable
  | Provider_parse_error _ | Provider_wire_error _ -> Silent (Unusable Not_json)
  | Response_body_too_large _ -> Silent (Unusable Empty_or_partial)
  | Provider_reported_error _ | Provider_interrupted | Unknown_provider_failure _ -> Silent Lost

let http_error (error : Http_client.http_error) : Librarian_slot_outcome.unanswered =
  match error with
  | ProviderTerminal { kind; _ } -> provider_terminal kind
  | ProviderFailure { kind; _ } -> provider_failure kind
  | AcceptRejected _ -> Silent Unavailable
  | HttpError _ | NetworkError _ | Connect_failed _ | TimeoutError _ -> Silent Lost

let execution (cause : Exact.execution_error_cause) : Librarian_slot_outcome.unanswered =
  match cause with
  | Completion_failed { error; _ } -> http_error error
  | Provider_response_refused { refusal; _ } -> provider_refusal refusal
  | Provider_context_overflow _ -> Refused (Sized Input_too_large)
  | Output_limit_reached -> Refused (Sized Output_over_reserve)
  | Window_reached _ -> Refused (Sized Window_reached)
  | Incomplete_output { stop } -> incomplete_stop stop
  | Missing_output -> Silent (Unusable Empty_or_partial)
  (* Several texts, or a block that is not text: the output is not one JSON
     value. No field of an answer was read, so no schema violation can name
     one. *)
  | Ambiguous_output _ | Unexpected_output_content | Invalid_json_output ->
    Silent (Unusable Not_json)
  | Response_body_deadline_exceeded -> Silent Lost

let codex_info (info : Runtime_codex_app_server.Codex_error_info.t) : Librarian_slot_outcome.unanswered =
  match info with
  | Cyber_policy | Misalignment_policy_violation | Bad_request -> Refused Unsized
  | Usage_limit_exceeded | Rate_limit_exceeded | Server_overloaded | Internal_server_error ->
    Silent Busy
  | Session_budget_exceeded | Unauthorized -> Silent Unavailable
  | Thread_rollback_failed | Sandbox_error | Other | Http_connection_failed _
  | Response_stream_connection_failed _ | Response_stream_disconnected _
  | Response_too_many_failed_attempts _ | Active_turn_not_steerable _ | Unrecognized _ ->
    Silent Lost

(* A client's overflow is a refusal before generation only when it shows that
   nothing was generated: no tool ran, and for Claude no response came. *)

let codex (error : Runtime_codex_app_server.error) : Librarian_slot_outcome.unanswered =
  match error with
  | Context_window_exceeded { tool_effect_attempted = false; _ } -> Refused (Sized Input_too_large)
  | Context_window_exceeded { tool_effect_attempted = true; _ } -> Refused (Sized Window_reached)
  | Turn_failed { codex_error_info = Some info; _ } -> codex_info info
  | Turn_failed { codex_error_info = None; _ } -> Silent Lost
  | Invalid_config _ | Spawn_refused _ | Reasoning_effort_admission_failed _
  | Account_read_failed _ | Subscription_required _ -> Silent Unavailable
  | Turn_input_write_failed _ | Protocol_error _ | Rpc_error _ | Unsupported_server_request _
  | Stopped_by_host _ | Turn_interrupted | Runtime_shutting_down | Process_exited _
  | Timeout _ -> Silent Lost

let claude (error : Runtime_claude_code.error) : Librarian_slot_outcome.unanswered =
  match error with
  | Context_window_exceeded { tool_effect_attempted; response_emitted; _ } ->
    (match tool_effect_attempted, response_emitted with
     | false, false -> Refused (Sized Input_too_large)
     | true, false | false, true | true, true -> Refused (Sized Window_reached))
  | Turn_failed_with_observation { api_error_cause = Some Authentication_failed; _ } ->
    Silent Unavailable
  | Turn_failed_with_observation { api_error_cause = None | Some Other_api_error_cause; _ } ->
    Silent Lost
  | Quota_blocked _ -> Silent Busy
  | Invalid_config _ | Spawn_refused _ | Subscription_required _ -> Silent Unavailable
  | Protocol_error _ | Unsupported_control_request _ | Turn_transport_interrupted _
  | Turn_failed _ | Stopped_by_host _ | Process_exited _ | Unhandled_exception _ | Timeout _ ->
    Silent Lost

let antigravity (error : Runtime_antigravity.error) : Librarian_slot_outcome.unanswered =
  match error with
  | Spawn_capacity_busy _ -> Silent Not_called
  | Invalid_config _ | Spawn_refused _ | Child_fd_ceiling_exceeded _ -> Silent Unavailable
  | Protocol_error _ | State_callback_failed _ | Turn_failed _ | Result_not_completed _
  | Actions_denied _ | Process_exited _ | Unhandled_exception _ | Timeout _ -> Silent Lost

let muse (error : Runtime_muse_serve.error) : Librarian_slot_outcome.unanswered =
  match error with
  | Turn_failed { quota = Some _; _ } -> Silent Busy
  | Turn_failed { quota = None; _ } -> Silent Lost
  | Invalid_config _ | Spawn_refused _ | Capability_not_granted _ | Session_not_durable
  | Session_model_mismatch _ | Session_workspace_mismatch _ | Session_approval_mode_mismatch _
  | Auth_required _ -> Silent Unavailable
  | Turn_input_write_failed _ | Protocol_error _ | Rpc_error _ | Turn_cancelled
  | Unsupported_server_request _ | Runtime_shutting_down | Process_exited _ | Timeout _ ->
    Silent Lost

let client (failure : Fusion_official_client.failure) : Librarian_slot_outcome.unanswered =
  match failure with
  | Codex_failure error -> codex error
  | Claude_failure error | Claude_admission_failure error -> claude error
  | Antigravity_failure error -> antigravity error
  | Muse_failure error -> muse error
  | Missing_reply -> Silent (Unusable Empty_or_partial)
  | Setup_failure _ -> Silent Unavailable
  (* The load check refuses a Vibe runtime as a lane slot, so no walk runs one. *)
  | Vibe_failure _ -> Silent Unavailable

let cli_failure (failure : Keeper_lane_cli_oneshot.failure) : Librarian_slot_outcome.unanswered =
  match failure with
  | Execution_failed { cause; _ } -> client cause
  | Held _ -> Silent Not_called
  | Unknown_runtime _ | Not_an_official_client _ -> Silent Unavailable
  | Invalid_json_output _ -> Silent (Unusable Not_json)
  (* Only [walk] makes it, with the consumer's rejection folded into its
     detail; the text is not read. *)
  | Invalid_domain_output _ -> Silent Lost

let classify_unanswered : unanswered -> Librarian_slot_outcome.unanswered = function
  | Not_visited | Http Held -> Silent Not_called
  | Http (Rejected_before_dispatch disposition) -> rejected disposition
  | Http (Execution_failed cause) -> execution cause
  | Cli (Cli_failed failure) -> cli_failure failure
  | Cli Cli_seats_full -> Silent Not_called
  | Cli Cli_unservable -> Silent Unavailable
  | Http (Answer_rejected rejection) | Cli (Cli_answer_rejected rejection) ->
    Silent (Unusable rejection)

let classify : t -> Librarian_slot_outcome.t = function
  | Answer_accepted -> Slot_answered
  | Unanswered visit -> Unanswered (classify_unanswered visit)
