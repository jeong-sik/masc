module Exact_output = Agent_core.Exact_output
module Http_client = Llm_provider.Http_client

module Input_refusal = Keeper_librarian_input_refusal

type t =
  { historical_range_size : bool
  ; named_input_capacity : bool
  ; invalid_output : bool
  ; size_independent_execution_failure : bool
  ; measured_cli_capacity : Keeper_lane_cli_oneshot.input_capacity option
  ; provider_input_refusals : Input_refusal.t list
  }

let empty =
  { historical_range_size = false
  ; named_input_capacity = false
  ; invalid_output = false
  ; size_independent_execution_failure = false
  ; measured_cli_capacity = None
  ; provider_input_refusals = []
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
  ; provider_input_refusals =
      Input_refusal.union left.provider_input_refusals right.provider_input_refusals
  }
;;

let execution ~historical_range_size ~named_input_capacity =
  { empty with historical_range_size; named_input_capacity
  ; size_independent_execution_failure = not historical_range_size }
;;

let size_independent = execution ~historical_range_size:false ~named_input_capacity:false
let historical_size = execution ~historical_range_size:true ~named_input_capacity:false
let input_size = execution ~historical_range_size:true ~named_input_capacity:true
let provider_input_size refusal = { input_size with provider_input_refusals = [refusal] }

type provider_cause = Exact_output.provider_refusal =
  | Request_body_refused | Refusal_body_not_received | Rate_limited | Overloaded
  | Server_error | Auth_failed | Authorization_refused | Payment_required
  | Invalid_request | Not_found | Context_overflow | Input_capacity | Network_error | Timeout
[@@deriving yojson]

type stop =
  | End_turn | Stop_tool_use | Max_tokens | Stop_sequence | Refusal | Content_filter
  | Repetition_truncation | Pause_turn | Compaction | Context_window_exceeded
  | Unmatched_tool_calls | Unknown_stop of string
[@@deriving yojson]

type network =
  | Connection_refused | Dns_failure | Tls_error | Network_timeout
  | Local_resource_exhaustion | Connection_reset | End_of_file | Unknown_network
[@@deriving yojson]

type completion =
  | Http_failure | Network_failure of network | Deadline of Http_client.timeout_phase
  | Accept_rejected | Provider_terminal | Capacity_exhausted | Hard_quota
  | Capability_mismatch | Cli_policy_invalid | Cli_startup_failed | Provider_parse_error
  | Provider_wire_error | Provider_reported_error | Provider_interrupted
  | Response_body_too_large | Empty_completion of stop | Context_overflow_failure
  | Repeating_generation | Unknown_provider_failure
[@@deriving yojson]

type api_observation =
  | Provider_refused of { http_status : int; refusal : provider_cause }
  | Completion_failed of { sent : bool; cause : completion }
  | Output_limit | Incomplete | Missing | Ambiguous of int | Unexpected | Invalid_json
  | Body_deadline
[@@deriving yojson]

let stop = function
  | Agent_core.Types.EndTurn -> End_turn | StopToolUse -> Stop_tool_use | MaxTokens -> Max_tokens
  | StopSequence -> Stop_sequence | Refusal -> Refusal | ContentFilter -> Content_filter
  | RepetitionTruncation -> Repetition_truncation | PauseTurn -> Pause_turn | Compaction -> Compaction
  | ContextWindowExceeded -> Context_window_exceeded | UnmatchedToolCalls -> Unmatched_tool_calls
  | Unknown detail -> Unknown_stop detail

let completion (error : Http_client.http_error) = match error with
  | HttpError _ -> Http_failure
  | NetworkError {kind;_} -> Network_failure (match kind with
      | Connection_refused -> Connection_refused | Dns_failure -> Dns_failure | Tls_error -> Tls_error
      | Timeout -> Network_timeout | Local_resource_exhaustion -> Local_resource_exhaustion
      | Connection_reset -> Connection_reset | End_of_file -> End_of_file | Unknown -> Unknown_network)
  | TimeoutError {phase;_} -> Deadline phase
  | AcceptRejected _ -> Accept_rejected | ProviderTerminal _ -> Provider_terminal
  | ProviderFailure {kind;_} -> match kind with
      | Capacity_exhausted _ -> Capacity_exhausted | Hard_quota _ -> Hard_quota
      | Capability_mismatch _ -> Capability_mismatch | Cli_policy_invalid _ -> Cli_policy_invalid
      | Cli_startup_failed _ -> Cli_startup_failed | Provider_parse_error _ -> Provider_parse_error
      | Provider_wire_error _ -> Provider_wire_error | Provider_reported_error _ -> Provider_reported_error
      | Provider_interrupted -> Provider_interrupted | Response_body_too_large _ -> Response_body_too_large
      | Empty_completion {stop_reason} -> Empty_completion (stop stop_reason)
      | Context_overflow _ -> Context_overflow_failure | Repeating_generation _ -> Repeating_generation
      | Unknown_provider_failure _ -> Unknown_provider_failure

let api_observation (cause : Exact_output.execution_error_cause) = match cause with
  | Provider_response_refused {http_status;refusal;_} -> Provider_refused {http_status;refusal}
  | Completion_failed {dispatch;error} ->
    Completion_failed {sent=(match dispatch with No_generation_dispatch -> false | Generation_dispatch_started -> true);
      cause=completion error}
  | Output_limit_reached -> Output_limit | Incomplete_output -> Incomplete | Missing_output -> Missing
  | Ambiguous_output count -> Ambiguous count | Unexpected_output_content -> Unexpected
  | Invalid_json_output -> Invalid_json | Response_body_deadline_exceeded -> Body_deadline

let of_completion = function
  | Deadline (First_token | Wall_clock | Http_operation | Non_streaming_body | Stream_body)
  | Response_body_too_large | Empty_completion Max_tokens -> historical_size
  | Context_overflow_failure | Empty_completion Context_window_exceeded -> provider_input_size Context_overflow
  | Deadline (Stream_idle _ | Cli_stdout_idle | Provider_step | Queue | Capacity_backpressure | Unknown_timeout)
  | Http_failure | Network_failure _ | Accept_rejected | Provider_terminal | Capacity_exhausted | Hard_quota
  | Capability_mismatch | Cli_policy_invalid | Cli_startup_failed | Provider_parse_error
  | Provider_wire_error | Provider_reported_error | Provider_interrupted | Repeating_generation
  | Unknown_provider_failure
  | Empty_completion (End_turn | Stop_tool_use | Stop_sequence | Refusal | Content_filter
      | Repetition_truncation | Pause_turn | Compaction | Unmatched_tool_calls | Unknown_stop _) -> size_independent

let of_api_observation = function
  | Provider_refused {refusal;_} -> (match refusal with
      | Context_overflow -> provider_input_size Context_overflow
      | Input_capacity -> provider_input_size Input_capacity
      | Request_body_refused -> provider_input_size Request_body_refused
      | Timeout | Invalid_request | Refusal_body_not_received -> historical_size
      | Rate_limited | Overloaded | Server_error | Network_error
      | Auth_failed | Authorization_refused | Payment_required | Not_found -> size_independent)
  | Completion_failed {sent=false;_} -> size_independent
  | Completion_failed {sent=true;cause} -> of_completion cause
  | Output_limit | Incomplete | Missing | Ambiguous _ | Unexpected | Body_deadline -> historical_size
  | Invalid_json -> invalid_output

let of_cause cause = of_api_observation (api_observation cause)
let api_observation_of_yojson json =
  let open Result.Syntax in
  let* value = api_observation_of_yojson json in
  let* original = Lane_addon_action.canonical json in
  let* encoded = Lane_addon_action.canonical (api_observation_to_yojson value) in
  let valid = match value with
    | Provider_refused {http_status;_} -> http_status>=100 && http_status<=599
    | Ambiguous count -> count>1
    | Completion_failed _ | Output_limit | Incomplete | Missing | Unexpected | Invalid_json | Body_deadline -> true in
  if original = encoded && valid then Ok value else Error "invalid or noncanonical API failure observation"

let api_generation_dispatched = function
  | Completion_failed {sent;_} -> sent
  | Provider_refused _ | Output_limit | Incomplete | Missing | Ambiguous _ | Unexpected
  | Invalid_json | Body_deadline -> true

let dispatched_valid_output_failure = function
  | Completion_failed {sent=false;_} | Invalid_json -> false
  | Completion_failed {sent=true;_} | Provider_refused _ | Body_deadline
  | Output_limit | Incomplete | Missing | Ambiguous _ | Unexpected -> true

type local_rejection = Runtime_unavailable | Runtime_contract | Input_contract
  | Output_requirement | Local_input_capacity | Preparation_failed
[@@deriving yojson]

let local_rejection (disposition : Exact_output.candidate_rejection_disposition) = match disposition with
  | Input_capacity _ -> Local_input_capacity
  | Runtime_slot_unavailable -> Runtime_unavailable | Runtime_contract_rejected -> Runtime_contract
  | Input_contract_rejected -> Input_contract | Output_requirement_rejected -> Output_requirement
  | Request_preparation_failed -> Preparation_failed

let of_local_rejection = function
  | Local_input_capacity -> input_capacity_refusal
  | Runtime_unavailable | Runtime_contract | Input_contract | Output_requirement | Preparation_failed -> empty

let of_disposition disposition = of_local_rejection (local_rejection disposition)
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

type native_family = Codex | Claude | Claude_admission | Antigravity | Muse | Host
[@@deriving yojson]
type measured_capacity = { actual_chars : int; max_chars : int } [@@deriving yojson]
type cli_cause =
  | Unknown_runtime | Not_official | Invalid_json_answer | Invalid_domain_answer
  | Codex_context_refused of { message : string; tool_effect_attempted : bool }
  | Claude_context_refused of
      { message : string; tool_effect_attempted : bool; response_emitted : bool }
  | Codex_measured_input_refused of measured_capacity
  | Native_failed of native_family
[@@deriving yojson]
type cli_observation = { runtime_id : string; cause : cli_cause } [@@deriving yojson]

let native_cause (cause : Fusion_official_client.failure) =
  match cause with
  | Codex_failure
      (Runtime_codex_app_server.Context_window_exceeded { message; tool_effect_attempted }) ->
    Codex_context_refused {message;tool_effect_attempted}
  | Claude_failure
      (Runtime_claude_code.Context_window_exceeded
         { message; tool_effect_attempted; response_emitted }) ->
    Claude_context_refused {message;tool_effect_attempted;response_emitted}
  | Missing_reply | Setup_failure _ -> Native_failed Host
  | Codex_failure
      ( Runtime_codex_app_server.Invalid_config _
      | Runtime_codex_app_server.Spawn_failed _
      | Runtime_codex_app_server.Reasoning_effort_admission_failed _
      | Runtime_codex_app_server.Turn_input_write_failed _
      | Runtime_codex_app_server.Protocol_error _
      | Runtime_codex_app_server.Rpc_error _
      | Runtime_codex_app_server.Subscription_required _
      | Runtime_codex_app_server.Unsupported_server_request _
      | Runtime_codex_app_server.Turn_failed _
      | Runtime_codex_app_server.Stopped_by_host _
      | Runtime_codex_app_server.Turn_interrupted
      | Runtime_codex_app_server.Runtime_shutting_down
      | Runtime_codex_app_server.Process_exited _
      | Runtime_codex_app_server.Timeout _ ) -> Native_failed Codex
  | Claude_failure
      ( Runtime_claude_code.Invalid_config _
      | Runtime_claude_code.Spawn_failed _
      | Runtime_claude_code.Protocol_error _
      | Runtime_claude_code.Subscription_required _
      | Runtime_claude_code.Unsupported_control_request _
      | Runtime_claude_code.Turn_transport_interrupted _
      | Runtime_claude_code.Turn_failed _
      | Runtime_claude_code.Turn_failed_with_observation _
      | Runtime_claude_code.Stopped_by_host _
      | Runtime_claude_code.Quota_blocked _
      | Runtime_claude_code.Process_exited _
      | Runtime_claude_code.Unhandled_exception _
      | Runtime_claude_code.Timeout _ ) -> Native_failed Claude
  | Claude_admission_failure _ -> Native_failed Claude_admission
  | Antigravity_failure _ -> Native_failed Antigravity
  | Muse_failure _ -> Native_failed Muse
;;


let cli_observation (failure : Keeper_lane_cli_oneshot.failure) = match failure with
  | Unknown_runtime {runtime_id} -> {runtime_id;cause=Unknown_runtime}
  | Not_an_official_client {runtime_id} -> {runtime_id;cause=Not_official}
  | Invalid_json_output {runtime_id;_} -> {runtime_id;cause=Invalid_json_answer}
  | Invalid_domain_output {runtime_id;_} -> {runtime_id;cause=Invalid_domain_answer}
  | Execution_failed {runtime_id;cause} ->
    let cause = match Keeper_lane_cli_oneshot.input_capacity failure with
      | Some capacity -> Codex_measured_input_refused
          {actual_chars=capacity.capacity.actual_chars;max_chars=capacity.capacity.max_chars}
      | None -> native_cause cause in
    {runtime_id;cause}

let cli_observation_slot observation = observation.runtime_id
let cli_was_dispatched observation = match observation.cause with
  | Unknown_runtime | Not_official -> false
  | Invalid_json_answer | Invalid_domain_answer | Codex_context_refused _
  | Claude_context_refused _ | Codex_measured_input_refused _
  | Native_failed (Codex | Claude | Claude_admission | Antigravity | Muse | Host) -> true
let of_cli_observation observation = match observation.cause with
  | Invalid_json_answer | Invalid_domain_answer -> invalid_output
  | Unknown_runtime | Not_official -> empty
  | Codex_context_refused {tool_effect_attempted=false;message=_}
  | Claude_context_refused {tool_effect_attempted=false;response_emitted=false;message=_} ->
    {empty with named_input_capacity=true;provider_input_refusals=[Context_overflow]}
  | Codex_measured_input_refused capacity ->
    {empty with historical_range_size=true;named_input_capacity=true;
     measured_cli_capacity=Some {Keeper_lane_cli_oneshot.runtime_id=observation.runtime_id;
       capacity={Runtime_codex_app_server.actual_chars=capacity.actual_chars;max_chars=capacity.max_chars}}}
  | Codex_context_refused {tool_effect_attempted=true;message=_}
  | Claude_context_refused {tool_effect_attempted=true;response_emitted=_;message=_}
  | Claude_context_refused {tool_effect_attempted=false;response_emitted=true;message=_}
  | Native_failed (Codex | Claude | Claude_admission | Antigravity | Muse | Host) ->
    {empty with size_independent_execution_failure=true}

let of_cli_failure failure = of_cli_observation (cli_observation failure)
let cli_observation_of_yojson json =
  let open Result.Syntax in
  let* value = cli_observation_of_yojson json in
  let* original = Lane_addon_action.canonical json in
  let* encoded = Lane_addon_action.canonical (cli_observation_to_yojson value) in
  let valid = match value.cause with
    | Unknown_runtime | Not_official | Invalid_json_answer | Invalid_domain_answer
    | Codex_context_refused _ | Claude_context_refused _
    | Native_failed (Codex | Claude | Claude_admission | Antigravity | Muse | Host) -> true
    | Codex_measured_input_refused limit ->
      limit.max_chars > 0 && limit.actual_chars > limit.max_chars in
  if original=encoded && String.trim value.runtime_id<>"" && valid then Ok value
  else Error "invalid or noncanonical CLI failure observation"

let after_cli_fallback ~prior failures =
  let tail = List.fold_left
      (fun evidence failure -> combine evidence (of_cli_failure failure))
      empty failures in
  combine (without_measured_cli_capacity prior) tail
;;
