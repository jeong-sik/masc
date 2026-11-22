module Exact = Agent_core.Exact_output
module Http_client = Llm_provider.Http_client
module Outcome = Exact_lane_slot_outcome

type 'rejection http =
  | Held
  | Rejected_before_dispatch of Exact.candidate_rejection_disposition
  | Execution_failed of Exact.execution_error_cause
  | Answer_rejected of 'rejection

type 'rejection cli =
  | Cli_failed of Keeper_lane_cli_oneshot.failure
  | Cli_answer_rejected of 'rejection
  | Cli_seats_full
  | Cli_unservable

type 'rejection unanswered =
  | Not_visited
  | Http of 'rejection http
  | Cli of 'rejection cli

type 'rejection t =
  | Answer_accepted
  | Unanswered of 'rejection unanswered

type 'rejection bodies =
  { empty_or_partial : 'rejection
  ; not_json : 'rejection
  }

(* One function per type of the slot-outcome table, each defined before the
   functions that call it. An arm that calls another of them is a
   "> file type" row of the table. A function takes [bodies] when it, or one
   it calls, finds a body the lane cannot use. *)

let token_capacity (rejection : Exact.token_capacity_rejection) : 'rejection Outcome.unanswered =
  match rejection with
  | Capacity_input_rejected _ -> Refused (Sized Input_too_large)
  | Capacity_evidence_not_yet_valid _ | Capacity_evidence_expired _
  | Capacity_boundary_unknown _ -> Silent Unavailable

let input_capacity (disposition : Exact.input_capacity_disposition) : 'rejection Outcome.unanswered =
  match disposition with
  | Context_window_exceeded _ -> Refused (Sized Input_too_large)
  | Token_capacity_rejected rejection -> token_capacity rejection
  | Token_measurement_required _ -> Silent Unavailable

let rejected (disposition : Exact.candidate_rejection_disposition) : 'rejection Outcome.unanswered =
  match disposition with
  | Input_capacity disposition -> input_capacity disposition
  | Seats_full -> Silent Not_called
  | Runtime_slot_unavailable | Runtime_contract_rejected | Input_contract_rejected
  | Output_requirement_rejected | Request_preparation_failed -> Silent Unavailable

(* [Timeout] carries no phase, so it cannot say that a deadline on the
   request's own work passed, and no status makes it: [Retry.classify_error]
   never gives [Retry.Timeout], and HTTP 408 is [Unclassified_status]. *)
let provider_refusal (refusal : Exact.provider_refusal) : 'rejection Outcome.unanswered =
  match refusal with
  | Request_body_refused | Context_overflow -> Refused (Sized Input_too_large)
  | Invalid_request -> Refused Unsized
  | Rate_limited | Overloaded | Server_error -> Silent Busy
  | Auth_failed | Authorization_refused | Payment_required | Unclassified_status | Not_found
  | Input_capacity -> Silent Unavailable
  | Refusal_body_not_received | Network_error | Connect_failed | Timeout -> Silent Lost

let incomplete_stop (bodies : 'rejection bodies) (stop : Exact.incomplete_stop)
  : 'rejection Outcome.unanswered
  =
  match stop with
  | Refusal | Content_filter -> Refused Unsized
  | End_turn | Tool_use | Stop_sequence | Repetition_truncation | Pause_turn | Compaction
  | Unmatched_tool_calls | Unknown_stop _ -> Silent (Unusable bodies.empty_or_partial)

let stop_reason (bodies : 'rejection bodies) (stop : Llm_provider.Types.stop_reason)
  : 'rejection Outcome.unanswered
  =
  match stop with
  | MaxTokens -> Refused (Sized Output_over_reserve)
  | ContextWindowExceeded -> Refused (Sized Window_reached)
  | Refusal | ContentFilter -> Refused Unsized
  | EndTurn | StopToolUse | StopSequence | RepetitionTruncation | PauseTurn | Compaction
  | UnmatchedToolCalls | Unknown _ -> Silent (Unusable bodies.empty_or_partial)

let provider_terminal (kind : Http_client.provider_terminal_kind) : 'rejection Outcome.unanswered =
  match kind with
  | Session_conflict -> Silent Unavailable
  | Other _ -> Silent Lost

let provider_failure (bodies : 'rejection bodies) (kind : Http_client.provider_failure_kind)
  : 'rejection Outcome.unanswered
  =
  match kind with
  | Context_overflow _ -> Refused (Sized Input_too_large)
  | Empty_completion { stop_reason = stop } -> stop_reason bodies stop
  | Capacity_exhausted _ | Hard_quota _ -> Silent Busy
  | Capability_mismatch _ | Cli_policy_invalid _ | Cli_startup_failed _ -> Silent Unavailable
  | Provider_parse_error _ | Provider_wire_error _ -> Silent (Unusable bodies.not_json)
  | Response_body_too_large _ -> Silent (Unusable bodies.empty_or_partial)
  | Provider_reported_error _ | Provider_interrupted | Unknown_provider_failure _ -> Silent Lost

(* A deadline on the request's own work that passed after the request was
   sent is [Overdue]. The walk receipt reads the same five phases of a sent
   request as evidence of the request's size
   ([Keeper_exact_walk_failure.of_api_observation] and [of_completion]). The
   same deadline before the request was sent, a deadline on waiting or on an
   idle stream, and one whose phase is unknown are [Lost]. *)
let timeout_phase (dispatch : Exact.generation_dispatch_fact) (phase : Http_client.timeout_phase)
  : 'rejection Outcome.unanswered
  =
  match phase, dispatch with
  | ( (First_token | Wall_clock | Http_operation | Non_streaming_body | Stream_body)
    , Generation_dispatch_started ) -> Silent Overdue
  | ( (First_token | Wall_clock | Http_operation | Non_streaming_body | Stream_body)
    , No_generation_dispatch ) -> Silent Lost
  | ( ( Queue | Capacity_backpressure | Stream_idle _ | Provider_step | Cli_stdout_idle
      | Unknown_timeout )
    , (No_generation_dispatch | Generation_dispatch_started) ) -> Silent Lost

let http_error
  (bodies : 'rejection bodies)
  (dispatch : Exact.generation_dispatch_fact)
  (error : Http_client.http_error)
  : 'rejection Outcome.unanswered
  =
  match error with
  | ProviderTerminal { kind; _ } -> provider_terminal kind
  | ProviderFailure { kind; _ } -> provider_failure bodies kind
  | TimeoutError { phase; _ } -> timeout_phase dispatch phase
  | AcceptRejected _ -> Silent Unavailable
  | HttpError _ | NetworkError _ | Connect_failed _ -> Silent Lost

let execution (bodies : 'rejection bodies) (cause : Exact.execution_error_cause)
  : 'rejection Outcome.unanswered
  =
  match cause with
  | Completion_failed { error; dispatch } -> http_error bodies dispatch error
  | Provider_response_refused { refusal; _ } -> provider_refusal refusal
  | Provider_context_overflow _ -> Refused (Sized Input_too_large)
  | Output_limit_reached -> Refused (Sized Output_over_reserve)
  | Window_reached _ -> Refused (Sized Window_reached)
  | Incomplete_output { stop } -> incomplete_stop bodies stop
  | Missing_output -> Silent (Unusable bodies.empty_or_partial)
  (* Several texts, or a block that is not text: the output is not one JSON
     value. No field of an answer was read, so no schema violation can name
     one. *)
  | Ambiguous_output _ | Unexpected_output_content | Invalid_json_output ->
    Silent (Unusable bodies.not_json)
  (* The body deadline of a request that was sent. *)
  | Response_body_deadline_exceeded -> Silent Overdue

let codex_info (info : Runtime_codex_app_server.Codex_error_info.t) : 'rejection Outcome.unanswered =
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
   nothing was generated: no tool ran, and for Claude no response came.

   A client's [Timeout] is its idle window: the stream said nothing for that
   long. It is [Lost], as the idle phases of {!timeout_phase} are. *)

let codex (error : Runtime_codex_app_server.error) : 'rejection Outcome.unanswered =
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

let claude (error : Runtime_claude_code.error) : 'rejection Outcome.unanswered =
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

let antigravity (error : Runtime_antigravity.error) : 'rejection Outcome.unanswered =
  match error with
  | Context_window_exceeded { tool_effect_attempted; response_emitted; _ } ->
    (match tool_effect_attempted, response_emitted with
     | false, false -> Refused (Sized Input_too_large)
     | true, false | false, true | true, true -> Refused (Sized Window_reached))
  | Spawn_capacity_busy _ -> Silent Not_called
  | Invalid_config _ | Spawn_refused _ | Child_fd_ceiling_exceeded _ -> Silent Unavailable
  | Protocol_error _ | State_callback_failed _ | Turn_failed _ | Result_not_completed _
  | Actions_denied _ | Process_exited _ | Unhandled_exception _ | Timeout _ -> Silent Lost

let acp (error : Runtime_acp_client.error) : 'rejection Outcome.unanswered =
  match error with
  | Invalid_config _ | Spawn_refused _ -> Silent Unavailable
  | Protocol_error _ | Rpc_error _ | Timeout _ | Process_exited _ | Client_closed ->
    Silent Lost

let client (bodies : 'rejection bodies) (failure : Fusion_official_client.failure)
  : 'rejection Outcome.unanswered
  =
  match failure with
  | Codex_failure error -> codex error
  | Claude_failure error | Claude_admission_failure error -> claude error
  | Antigravity_failure error -> antigravity error
  | Acp_failure error -> acp error
  | Missing_reply -> Silent (Unusable bodies.empty_or_partial)
  | Setup_failure _ -> Silent Unavailable

let cli_failure (bodies : 'rejection bodies) (failure : Keeper_lane_cli_oneshot.failure)
  : 'rejection Outcome.unanswered
  =
  match failure with
  | Execution_failed { cause; _ } -> client bodies cause
  | Held _ -> Silent Not_called
  | Unknown_runtime _ | Not_an_official_client _ -> Silent Unavailable
  | Invalid_json_output _ -> Silent (Unusable bodies.not_json)
  (* Only [walk] makes it, with the consumer's rejection folded into its
     detail; the text is not read. *)
  | Invalid_domain_output _ -> Silent Lost

let classify_unanswered (bodies : 'rejection bodies) (visit : 'rejection unanswered)
  : 'rejection Outcome.unanswered
  =
  match visit with
  | Not_visited | Http Held -> Silent Not_called
  | Http (Rejected_before_dispatch disposition) -> rejected disposition
  | Http (Execution_failed cause) -> execution bodies cause
  | Cli (Cli_failed failure) -> cli_failure bodies failure
  | Cli Cli_seats_full -> Silent Not_called
  | Cli Cli_unservable -> Silent Unavailable
  | Http (Answer_rejected rejection) | Cli (Cli_answer_rejected rejection) ->
    Silent (Unusable rejection)

let classify (bodies : 'rejection bodies) (visit : 'rejection t) : 'rejection Outcome.t =
  match visit with
  | Answer_accepted -> Slot_answered
  | Unanswered visit -> Unanswered (classify_unanswered bodies visit)

(* --- What a walk left at a slot it passed --- *)

type 'rejection slot_visit =
  | Http_visit of (string * 'rejection http)
  | Cli_visit of (string * 'rejection cli)

let candidate_id (visit : Exact.flow_candidate_visit) = visit.identity.candidate_id

let rejected_before_dispatch rejection : string * 'rejection http =
  ( (Exact.candidate_rejection_identity rejection).candidate_id
  , Rejected_before_dispatch (Exact.candidate_rejection_disposition rejection) )

let answer_rejected (receipt : 'rejection Exact.semantic_rejection_receipt)
  : string * 'rejection http
  =
  ( candidate_id (Exact.flow_success_candidate receipt.transport_success).visit
  , Answer_rejected receipt.rejection )

(* The slot a flow ended on when it ran out of slots. Every other end is
   masc's own failure, the cases {!Exact.flow_execution_terminal_kind} calls
   [Non_advanceable_terminal]: it says nothing about the request, so it is no
   visit and is given back as it is. *)
let last_visit
  : 'record_error Exact.flow_execution_error
  -> (string * 'rejection http, 'record_error Exact.flow_execution_error) result
  = function
  | Flow_candidates_exhausted { rejection; evidence = _ } ->
    Ok (rejected_before_dispatch rejection)
  | Flow_exact_execution_failed { candidate; cause; evidence = _ } ->
    Ok (candidate_id candidate.visit, Execution_failed cause.cause)
  | ( Flow_attempt_already_started _ | Flow_attempt_start_failed _
    | Flow_measurement_start_failed _ | Flow_before_measurement_dispatch_callback_failed _
    | Flow_measurement_terminal_callback_failed _ | Flow_before_dispatch_callback_failed _
    | Flow_before_advance_callback_failed _ ) as stopped -> Error stopped

(* Each HTTP slot is a flow of one candidate, so its failure names that
   slot. *)
let of_passed
  : ( Exact_lane_slots.t
      , ('rejection, 'record_error) Exact_lane_slots.failure )
      Exact_lane_walk.passed
  -> ('rejection slot_visit, 'record_error Exact.flow_execution_error) result
  = function
  | Exact_lane_walk.Held { slot = Exact_lane_slots.Http_slot http; until = (_ : float) } ->
    Ok (Http_visit (http.slot_id, Held))
  | Exact_lane_walk.Held { slot = Exact_lane_slots.Cli_slot { runtime_id; runtime = _ }; until } ->
    Ok (Cli_visit (runtime_id, Cli_failed (Keeper_lane_cli_oneshot.Held { runtime_id; until })))
  | Exact_lane_walk.Seats_full (Exact_lane_slots.Http_slot http) ->
    Ok (Http_visit (http.slot_id, Rejected_before_dispatch Exact.Seats_full))
  | Exact_lane_walk.Seats_full (Exact_lane_slots.Cli_slot { runtime_id; runtime = _ }) ->
    Ok (Cli_visit (runtime_id, Cli_seats_full))
  | Exact_lane_walk.Failed
      { slot = _
      ; failure = Exact_lane_slots.Http_unfit { slot_id; reason = (_ : string) }
      } ->
    (* The slot's own declaration could not become a flow candidate, so no
       request left for it. That is a contract refusal of that one slot, not a
       rejection any provider made. *)
    Ok (Http_visit (slot_id, Rejected_before_dispatch Exact.Runtime_contract_rejected))
  | Exact_lane_walk.Failed
      { slot = _
      ; failure =
          Exact_lane_slots.Http_failed
            { slot_id = _
            ; error =
                Exact.Flow_semantic_candidates_exhausted
                  { rejections = { first; rest = _ }; evidence = _ }
            }
      } -> Ok (Http_visit (answer_rejected first))
  | Exact_lane_walk.Failed
      { slot = _
      ; failure =
          Exact_lane_slots.Http_failed
            { slot_id = _; error = Exact.Flow_execution_terminal { cause; prior_rejections = _ } }
      } -> Result.map (fun last -> Http_visit last) (last_visit cause)
  | Exact_lane_walk.Failed { slot = _; failure = Exact_lane_slots.Cli_failed { runtime_id; failure } }
    -> Ok (Cli_visit (runtime_id, Cli_failed failure))
  | Exact_lane_walk.Failed
      { slot = _; failure = Exact_lane_slots.Cli_rejected { runtime_id; rejection } } ->
    Ok (Cli_visit (runtime_id, Cli_answer_rejected rejection))
  | Exact_lane_walk.Failed
      { slot = _
      ; failure =
          ( Exact_lane_slots.Cli_unfit { runtime_id }
          | Exact_lane_slots.Cli_seats_unpublished { runtime_id; provider_id = _ } )
      } -> Ok (Cli_visit (runtime_id, Cli_unservable))
