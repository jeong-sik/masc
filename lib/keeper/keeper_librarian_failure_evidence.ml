module Exact_output = Agent_core.Exact_output
module Http_client = Llm_provider.Http_client

type t =
  { historical_range_size : bool
  ; named_input_capacity : bool
  ; invalid_output : bool
  ; size_independent_execution_failure : bool
  ; measured_cli_capacity : Keeper_lane_cli_oneshot.input_capacity option
  }

let empty =
  { historical_range_size = false
  ; named_input_capacity = false
  ; invalid_output = false
  ; size_independent_execution_failure = false
  ; measured_cli_capacity = None
  }
;;

let invalid_output = { empty with invalid_output = true }
let input_capacity_refusal =
  { empty with historical_range_size = true; named_input_capacity = true }
;;
let with_invalid_output evidence = { evidence with invalid_output = true }
let without_measured_cli_capacity evidence = { evidence with measured_cli_capacity = None }
let shows_range_size evidence = not evidence.invalid_output && evidence.historical_range_size
let refuses_input_capacity evidence = not evidence.invalid_output && evidence.named_input_capacity

let larger_capacity previous observed =
  match previous, observed with
  | None, observed -> observed
  | Some _, None -> previous
  | Some (held : Keeper_lane_cli_oneshot.input_capacity), Some next ->
    if next.capacity.max_chars > held.capacity.max_chars then observed else previous
;;

let combine left right =
  { historical_range_size = left.historical_range_size || right.historical_range_size
  ; named_input_capacity = left.named_input_capacity || right.named_input_capacity
  ; invalid_output = left.invalid_output || right.invalid_output
  ; size_independent_execution_failure =
      left.size_independent_execution_failure || right.size_independent_execution_failure
  ; measured_cli_capacity = larger_capacity left.measured_cli_capacity right.measured_cli_capacity
  }
;;

let execution ~historical_range_size ~named_input_capacity =
  { empty with historical_range_size; named_input_capacity
  ; size_independent_execution_failure = not historical_range_size }
;;

let size_independent = execution ~historical_range_size:false ~named_input_capacity:false
let historical_size = execution ~historical_range_size:true ~named_input_capacity:false
let input_size = execution ~historical_range_size:true ~named_input_capacity:true

(* Only a sent request's handling deadline counts for the historical range
   policy. Admission requires a named input refusal, never a timeout alone. *)
let sent_error (error : Http_client.http_error) =
  match error with
  | HttpError _ -> size_independent
  | NetworkError
      { kind =
          ( Connection_refused | Dns_failure | Tls_error | Timeout
          | Local_resource_exhaustion | Connection_reset | End_of_file | Unknown )
      ; _ } -> size_independent
  | TimeoutError { phase; _ } ->
    (match phase with
     | First_token | Wall_clock | Http_operation | Non_streaming_body | Stream_body ->
       historical_size
     | Stream_idle _ | Cli_stdout_idle | Provider_step | Queue | Capacity_backpressure
     | Unknown_timeout -> size_independent)
  | AcceptRejected _ | ProviderTerminal _ -> size_independent
  | ProviderFailure { kind; _ } ->
    (match kind with
     | Context_overflow _ -> input_size
     | Response_body_too_large _ -> historical_size
     | Empty_completion { stop_reason } ->
       (match stop_reason with
        | ContextWindowExceeded -> input_size
        | MaxTokens -> historical_size
        | EndTurn | StopToolUse | StopSequence | Refusal | ContentFilter
        | RepetitionTruncation | PauseTurn | Compaction | UnmatchedToolCalls
        | Unknown _ -> size_independent)
     | Capacity_exhausted _ | Hard_quota _ | Capability_mismatch _
     | Cli_policy_invalid _ | Cli_startup_failed _ | Provider_parse_error _
     | Provider_wire_error _ | Provider_reported_error _ | Provider_interrupted
     | Repeating_generation _ | Unknown_provider_failure _ -> size_independent)
;;

let of_cause (cause : Exact_output.execution_error_cause) =
  match cause with
  | Provider_response_refused { refusal; _ } ->
    (match refusal with
     | Context_overflow | Input_capacity | Request_body_refused -> input_size
     | Timeout | Invalid_request | Refusal_body_not_received -> historical_size
     | Rate_limited | Overloaded | Server_error | Network_error
     | Auth_failed | Authorization_refused | Payment_required | Not_found -> size_independent)
  | Output_limit_reached | Incomplete_output | Missing_output | Ambiguous_output _
  | Unexpected_output_content | Response_body_deadline_exceeded -> historical_size
  | Invalid_json_output -> invalid_output
  | Completion_failed { dispatch = No_generation_dispatch; _ } -> size_independent
  | Completion_failed { dispatch = Generation_dispatch_started; error } -> sent_error error
;;

let of_disposition (disposition : Exact_output.candidate_rejection_disposition) =
  match disposition with
  | Input_capacity _ -> input_capacity_refusal
  | Runtime_slot_unavailable | Runtime_contract_rejected | Input_contract_rejected
  | Output_requirement_rejected | Request_preparation_failed -> empty
;;

let of_rejection rejection =
  of_disposition (Exact_output.candidate_rejection_disposition rejection)
;;

let of_flow error =
  let flow, final =
    match error with
    | Exact_output.Flow_attempt_already_started evidence -> evidence, empty
    | Flow_attempt_start_failed { evidence; _ }
    | Flow_measurement_start_failed { evidence; _ }
    | Flow_before_measurement_dispatch_callback_failed { evidence; _ }
    | Flow_measurement_terminal_callback_failed { evidence; _ }
    | Flow_before_dispatch_callback_failed { evidence; _ }
    | Flow_before_advance_callback_failed { evidence; _ } -> evidence, empty
    | Flow_candidates_exhausted { evidence; rejection } -> evidence, of_rejection rejection
    | Flow_exact_execution_failed { evidence; cause; _ } ->
      evidence, of_cause cause.Exact_output.cause
  in
  let evidence =
    List.fold_left
      (fun accumulated (receipt : Exact_output.flow_advance_receipt) ->
        let observed =
          match receipt.failed with
          | Flow_advance_execution_failed { cause; _ } -> of_cause cause
          | Flow_advance_candidate_rejected rejection -> of_rejection rejection
        in
        combine accumulated observed)
      final
      flow.Exact_output.advances
  in
  flow, evidence
;;

(* A native context refusal can permit admission partitioning without a
   measured character limit. Historical range fitting uses only the measured
   CLI limit, so these two axes must not share one predicate. *)
let native_input_refusal (cause : Fusion_official_client.failure) =
  match cause with
  | Codex_failure
      (Runtime_codex_app_server.Context_window_exceeded { tool_effect_attempted = false; _ })
  | Claude_failure
      (Runtime_claude_code.Context_window_exceeded
         { tool_effect_attempted = false; response_emitted = false; _ }) -> true
  | Missing_reply | Setup_failure _
  | Codex_failure
      ( Runtime_codex_app_server.Invalid_config _
      | Runtime_codex_app_server.Spawn_failed _
      | Runtime_codex_app_server.Reasoning_effort_admission_failed _
      | Runtime_codex_app_server.Turn_input_write_failed _
      | Runtime_codex_app_server.Protocol_error _
      | Runtime_codex_app_server.Rpc_error _
      | Runtime_codex_app_server.Subscription_required _
      | Runtime_codex_app_server.Unsupported_server_request _
      | Runtime_codex_app_server.Context_window_exceeded _
      | Runtime_codex_app_server.Turn_failed _
      | Runtime_codex_app_server.Stopped_by_host _
      | Runtime_codex_app_server.Turn_interrupted
      | Runtime_codex_app_server.Runtime_shutting_down
      | Runtime_codex_app_server.Process_exited _
      | Runtime_codex_app_server.Timeout _ )
  | Claude_failure
      ( Runtime_claude_code.Invalid_config _
      | Runtime_claude_code.Spawn_failed _
      | Runtime_claude_code.Protocol_error _
      | Runtime_claude_code.Subscription_required _
      | Runtime_claude_code.Unsupported_control_request _
      | Runtime_claude_code.Turn_transport_interrupted _
      | Runtime_claude_code.Context_window_exceeded _
      | Runtime_claude_code.Turn_failed _
      | Runtime_claude_code.Turn_failed_with_observation _
      | Runtime_claude_code.Stopped_by_host _
      | Runtime_claude_code.Quota_blocked _
      | Runtime_claude_code.Process_exited _
      | Runtime_claude_code.Unhandled_exception _
      | Runtime_claude_code.Timeout _ )
  | Claude_admission_failure _ | Antigravity_failure _ | Muse_failure _ -> false
;;

let of_cli_failure (failure : Keeper_lane_cli_oneshot.failure) =
  match failure with
  | Invalid_json_output _ | Invalid_domain_output _ -> invalid_output
  | Unknown_runtime _ | Not_an_official_client _ -> empty
  | Execution_failed { cause; _ } ->
    let measured_cli_capacity = Keeper_lane_cli_oneshot.input_capacity failure in
    let historical_range_size = Option.is_some measured_cli_capacity in
    let named_input_capacity = native_input_refusal cause || historical_range_size in
    { historical_range_size
    ; named_input_capacity
    ; invalid_output = false
    ; size_independent_execution_failure = not named_input_capacity
    ; measured_cli_capacity
    }
;;

let after_cli_fallback ~prior failures =
  let tail = List.fold_left
      (fun evidence failure -> combine evidence (of_cli_failure failure))
      empty failures in
  combine (without_measured_cli_capacity prior) tail
;;
