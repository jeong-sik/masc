module Model = Browser_stagehand_model
module Exact = Agent_core.Exact_output
module Http = Llm_provider.Http_client

let cause label fields = `Assoc (("cause", `String label) :: fields)
let simple label = cause label []

(* These kind renderers can include provider-owned strings; retain only their
   constructors here. The ordinary diagnostic message remains private. *)
let provider_failure = function
  | Http.Capacity_exhausted _ -> "capacity_exhausted"
  | Hard_quota _ -> "hard_quota"
  | Capability_mismatch _ -> "capability_mismatch"
  | Cli_policy_invalid _ -> "cli_policy_invalid"
  | Cli_startup_failed _ -> "cli_startup_failed"
  | Provider_parse_error _ -> "provider_parse_error"
  | Provider_wire_error _ -> "provider_wire_error"
  | Provider_reported_error _ -> "provider_reported_error"
  | Provider_interrupted -> "provider_interrupted"
  | Response_body_too_large _ -> "response_body_too_large"
  | Empty_completion _ -> "empty_completion"
  | Context_overflow _ -> "context_overflow"
  | Repeating_generation _ -> "repeating_generation"
  | Unknown_provider_failure _ -> "unknown_provider_failure"

let transport = function
  | Http.HttpError { code; _ } -> cause "http_error" ["http_status", `Int code]
  | NetworkError { kind; _ } ->
    cause "network_error" ["kind", `String (Http.network_error_kind_to_string kind)]
  | TimeoutError { phase; _ } ->
    cause "timeout" ["phase", `String (Http.timeout_phase_to_label phase)]
  | AcceptRejected _ -> simple "accept_rejected"
  | ProviderTerminal { kind; _ } ->
    cause "provider_terminal"
      ["kind", `String (match kind with Http.Session_conflict -> "session_conflict" | Other _ -> "other")]
  | ProviderFailure { kind; _ } -> cause "provider_failure" ["kind", `String (provider_failure kind)]

let execution = function
  | Exact.Completion_failed { error; dispatch } ->
    cause "completion_failed"
      [ "transport", transport error
      ; "dispatch_started", `Bool (match dispatch with
          Exact.No_generation_dispatch -> false | Generation_dispatch_started -> true) ]
  | Response_body_deadline_exceeded -> simple "response_body_deadline_exceeded"
  | Provider_response_refused { http_status; refusal; retry_after_s = _ } ->
    cause "provider_response_refused"
      ["http_status", `Int http_status; "refusal", `String (Exact.provider_refusal_to_string refusal)]
  | Incomplete_output -> simple "incomplete_output"
  | Missing_output -> simple "missing_output"
  | Ambiguous_output count -> cause "ambiguous_output" ["count", `Int count]
  | Unexpected_output_content -> simple "unexpected_output_content"
  | Invalid_json_output -> simple "invalid_json_output"

let measurement = function
  | Exact.Measurement_not_required -> "not_required"
  | Measurement_succeeded -> "succeeded"
  | Measurement_unsupported -> "unsupported"
  | Measurement_local_invalid -> "local_invalid"
  | Measurement_transport_failed -> "transport_failed"
  | Measurement_invalid_response -> "invalid_response"
  | Measurement_fence_rejected -> "fence_rejected"
  | Measurement_cancelled -> "cancelled"

let visit (visit : Exact.flow_candidate_visit) detail =
  `Assoc ["visit_ordinal", `Int (Exact.flow_visit_ordinal_to_int visit.ordinal); "detail", detail]

let rejection rejected =
  visit (Exact.candidate_rejection_visit rejected)
    (cause "candidate_rejected"
       [ "disposition", `String (Exact.candidate_rejection_disposition_to_string
           (Exact.candidate_rejection_disposition rejected))
       ; "measurement", `String (measurement (Exact.candidate_rejection_measurement_outcome rejected)) ])

let advance (advance : Exact.flow_advance_receipt) =
  match advance.failed with
  | Exact.Flow_advance_candidate_rejected rejected -> rejection rejected
  | Flow_advance_execution_failed { candidate; cause; raw_response_sha256 = _ } ->
    visit candidate.visit (execution cause)

let flow (failure : Model.no_callback_error Exact.flow_execution_error) =
  let terminal, evidence = match failure with
    | Exact.Flow_attempt_already_started evidence -> simple "flow_attempt_already_started", evidence
    | Flow_attempt_start_failed { candidate; evidence; cause = _ } ->
      visit candidate (simple "flow_attempt_start_failed"), evidence
    | Flow_measurement_start_failed { candidate; evidence; cause = _ } ->
      visit candidate (simple "flow_measurement_start_failed"), evidence
    | Flow_candidates_exhausted { rejection = rejected; evidence } -> rejection rejected, evidence
    | Flow_exact_execution_failed { candidate; cause; evidence } ->
      visit candidate.visit (execution cause.cause), evidence
    | Flow_before_measurement_dispatch_callback_failed _ -> .
    | Flow_measurement_terminal_callback_failed _ -> .
    | Flow_before_dispatch_callback_failed _ -> .
    | Flow_before_advance_callback_failed _ -> .
  in
  `Assoc
    [ "terminal", terminal
    ; "terminal_kind", `String (match Exact.flow_execution_terminal_kind failure with
        | Exact.Advanceable_candidates_exhausted -> "advanceable_candidates_exhausted"
        | Non_advanceable_terminal -> "non_advanceable_terminal")
    ; "prior_advances", `List (List.map advance evidence.advances) ]

let cli = function
  | Model.Cli_tail_undeclared -> simple "undeclared"
  | Cli_tail_unfit Model.Assistant_turn_in_conversation -> simple "assistant_turn_unfit"
  | Cli_tail_exhausted failures ->
    cause "exhausted" ["failures", `List (List.map (function
      | Keeper_lane_cli_oneshot.Unknown_runtime _ -> simple "unknown_runtime"
      | Not_an_official_client _ -> simple "not_an_official_client"
      | Execution_failed _ -> simple "execution_failed"
      | Invalid_json_output _ -> simple "invalid_json_output"
      | Invalid_domain_output _ -> simple "invalid_domain_output") failures)]

let refusal_json = function
  | Model.Params_malformed _ -> simple "params_malformed"
  | Generation_not_served _ -> simple "generation_not_served"
  | Content_not_served _ -> simple "content_not_served"
  | Lane_unavailable _ -> simple "lane_unavailable"
  | Lane_refused _ -> simple "lane_refused"
  | Flow_not_started _ -> simple "flow_not_started"
  | Generation_failed { http_failure; rejected_http_outputs; cli_tail } ->
    cause "generation_failed"
      [ "http", (match http_failure with None -> `Null | Some failure -> flow failure)
      ; "rejected_shapes", `List (List.map (fun (rejected : Model.rejected_http_output) ->
          match rejected.issue with
          | Model.Missing_required_key _ -> simple "missing_required_key"
          | Incompatible_required_shape _ -> simple "incompatible_required_shape") rejected_http_outputs)
      ; "cli", cli cli_tail ]
