module Exact_output = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry
module Request = Keeper_assembler_request
module Proposal = Keeper_plan_proposal
module Store = Keeper_plan_proposal_store

type setup_error =
  | Prompt_projection_failed of Request.error
  | Prompt_render_failed of string
  | Registry_unavailable of Registry.publication_error
  | Lane_unavailable of Registry.lane_resolution_error
  | Lane_preference_unavailable of string
  | Invalid_candidate of
      { position : int
      ; slot_id : string
      }
  | Lane_resolved_without_candidates
  | Flow_snapshot_failed of
      { candidate_id : string
      ; first_position : int
      ; duplicate_position : int
      }
  | Flow_start_failed of string

type semantic_rejection =
  | Output_invalid of Request.output_error
  | Cannot_assemble
  | Proposal_invalid of Proposal.error

type exact_execution_failure =
  | Attempt_already_started of { evidence : string }
  | Attempt_start_failed of
      { slot_id : string
      ; detail : string
      ; evidence : string
      }
  | Measurement_start_failed of
      { slot_id : string
      ; detail : string
      ; evidence : string
      }
  | Before_measurement_dispatch_callback_failed of { evidence : string }
  | Measurement_terminal_callback_failed of { evidence : string }
  | Before_dispatch_callback_failed of
      { slot_id : string
      ; call_id : string
      ; evidence : string
      }
  | Before_advance_callback_failed of
      { next_slot_id : string
      ; evidence : string
      }
  | Candidates_exhausted of
      { slot_id : string
      ; detail : string
      ; evidence : string
      }
  | Candidate_execution_failed of
      { slot_id : string
      ; call_id : string
      ; cause : Exact_output.execution_error_cause
      ; raw_response_sha256 : string option
      ; evidence : string
      }

type execution_error =
  | Exact_execution_failed of
      { failure : exact_execution_failure
      ; prior_semantic_rejections : semantic_rejection list
      }
  | Semantic_candidates_exhausted of semantic_rejection list
  | Proposal_store_failed of Store.error

type prepared =
  { config : Workspace.config
  ; keeper_name : string
  ; request : Request.t
  ; attempt : Exact_output.flow_attempt
  }

type success =
  { proposal : Proposal.t
  ; store_result : Store.save_result
  ; run_id : string
  ; selected_slot : string
  }

let lane_id = "assembler_exact"
let ( let* ) = Result.bind

let message text =
  Agent_core.Types.make_message
    ~role:Agent_core.Types.User
    [ Agent_core.Types.Text text ]
;;

let flow_candidates selected_slots =
  let rec loop position candidates = function
    | [] -> Ok (List.rev candidates)
    | (slot : Registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate
           ~id:slot.slot_id
           ~admitted_target:slot.admitted_target
       with
       | Ok candidate -> loop (position + 1) (candidate :: candidates) rest
       | Error Exact_output.Blank_flow_candidate_id ->
         Error (Invalid_candidate { position; slot_id = slot.slot_id }))
  in
  loop 0 [] selected_slots
;;

let prepare ~config ~keeper_name request =
  let* variables =
    Request.prompt_variables request
    |> Result.map_error (fun error -> Prompt_projection_failed error)
  in
  let* prompt =
    Prompt_registry.render_prompt_template Prompt_names.assembler variables
    |> Result.map_error (fun detail -> Prompt_render_failed detail)
  in
  let* registry =
    Registry.current ()
    |> Result.map_error (fun error -> Registry_unavailable error)
  in
  let* resolved =
    Registry.resolve_lane registry ~lane_id
    |> Result.map_error (fun error -> Lane_unavailable error)
  in
  let* resolved =
    Keeper_exact_lane_preference.apply
      ~base_path:config.Workspace.base_path
      ~keeper_name
      ~lane_id
      resolved
    |> Result.map_error (fun detail -> Lane_preference_unavailable detail)
  in
  let* candidates = flow_candidates resolved.selected_slots in
  match candidates with
  | [] -> Error Lane_resolved_without_candidates
  | first :: rest ->
    let requirement =
      Exact_output.make_output_requirement
        ~schema:Request.output_schema
        ~minimum_guarantee:Exact_output.Json_syntax
    in
    let* snapshot =
      Exact_output.snapshot_flow
        ~first
        ~rest
        ~messages:[ message prompt ]
        requirement
      |> Result.map_error (function
        | Exact_output.Duplicate_flow_candidate_id
            { candidate_id; first_position; duplicate_position } ->
          Flow_snapshot_failed
            { candidate_id; first_position; duplicate_position })
    in
    let* attempt =
      Exact_output.start_flow snapshot
      |> Result.map_error (function
        | Exact_output.Flow_id_generation_failed detail -> Flow_start_failed detail)
    in
    Ok { config; keeper_name; request; attempt }
;;

let execution_to_string = function
  | Proposal.Inline -> "inline"
  | Proposal.Async -> "async"
;;

let observation_input prepared =
  `Assoc
    [ "objective", `String (Request.objective prepared.request)
    ; "execution", `String (execution_to_string (Request.execution prepared.request))
    ; ( "capability_surface_sha256"
      , `String (Request.capability_surface_sha256 prepared.request) )
    ; ( "ordinary_tool_references"
      , `List
          (List.map
             Keeper_capability_surface.ordinary_tool_reference_to_yojson
             (Request.ordinary_tool_references prepared.request)) )
    ]
;;

let semantic_rejection_to_yojson = function
  | Output_invalid error ->
    `Assoc
      [ "kind", `String "output_invalid"
      ; "error", Request.output_error_to_yojson error
      ]
  | Cannot_assemble -> `Assoc [ "kind", `String "cannot_assemble" ]
  | Proposal_invalid error ->
    `Assoc
      [ "kind", `String "proposal_invalid"
      ; "error", Proposal.error_to_yojson error
      ]
;;

let flow_execution_failure = function
  | Exact_output.Flow_attempt_already_started evidence ->
    Attempt_already_started
      { evidence = Keeper_exact_flow_detail.flow_evidence_detail evidence }
  | Flow_attempt_start_failed
      { candidate; cause = Exact_output.Call_id_generation_failed detail; evidence } ->
    Attempt_start_failed
      { slot_id = candidate.identity.candidate_id
      ; detail
      ; evidence = Keeper_exact_flow_detail.flow_evidence_detail evidence
      }
  | Flow_measurement_start_failed { candidate; cause; evidence } ->
    let detail =
      match cause with
      | Exact_output.Measurement_operation_id_generation_failed detail -> detail
      | Exact_output.Measurement_clock_required_for_timeout ->
        "measurement_clock_required_for_timeout"
    in
    Measurement_start_failed
      { slot_id = candidate.identity.candidate_id
      ; detail
      ; evidence = Keeper_exact_flow_detail.flow_evidence_detail evidence
      }
  | Flow_before_measurement_dispatch_callback_failed { evidence; _ } ->
    Before_measurement_dispatch_callback_failed
      { evidence = Keeper_exact_flow_detail.flow_evidence_detail evidence }
  | Flow_measurement_terminal_callback_failed { evidence; _ } ->
    Measurement_terminal_callback_failed
      { evidence = Keeper_exact_flow_detail.flow_evidence_detail evidence }
  | Flow_before_dispatch_callback_failed { candidate; evidence; _ } ->
    Before_dispatch_callback_failed
      { slot_id = candidate.visit.identity.candidate_id
      ; call_id = Exact_output.receipt_call_id candidate.receipt |> Exact_output.call_id_to_string
      ; evidence = Keeper_exact_flow_detail.flow_evidence_detail evidence
      }
  | Flow_before_advance_callback_failed { next; evidence; _ } ->
    Before_advance_callback_failed
      { next_slot_id = next.identity.candidate_id
      ; evidence = Keeper_exact_flow_detail.flow_evidence_detail evidence
      }
  | Flow_candidates_exhausted { rejection; evidence } ->
    Candidates_exhausted
      { slot_id = (Exact_output.candidate_rejection_identity rejection).candidate_id
      ; detail = Keeper_exact_flow_detail.candidate_rejection_detail rejection
      ; evidence = Keeper_exact_flow_detail.flow_evidence_detail evidence
      }
  | Flow_exact_execution_failed { candidate; cause; evidence } ->
    Candidate_execution_failed
      { slot_id = candidate.visit.identity.candidate_id
      ; call_id = Exact_output.call_id_to_string cause.call_id
      ; cause = cause.cause
      ; raw_response_sha256 = Option.map (fun raw -> raw.Exact_output.body_sha256) cause.raw_response
      ; evidence = Keeper_exact_flow_detail.flow_evidence_detail evidence
      }
;;

let store_result_to_string = function
  | Store.Stored -> "stored"
  | Store.Already_present -> "already_present"
;;

let execution_cause_to_yojson = function
  | Exact_output.Attempt_already_started ->
    `Assoc [ "kind", `String "attempt_already_started" ]
  | Clock_required_for_timeout ->
    `Assoc [ "kind", `String "clock_required_for_timeout" ]
  | Frozen_request_mismatch ->
    `Assoc [ "kind", `String "frozen_request_mismatch" ]
  | Completion_failed -> `Assoc [ "kind", `String "completion_failed" ]
  | Provider_response_refused { http_status; refusal } ->
    `Assoc
      [ "kind", `String "provider_response_refused"
      ; "http_status", `Int http_status
      ; "refusal", `String (Exact_output.provider_refusal_to_string refusal)
      ]
  | Incomplete_output -> `Assoc [ "kind", `String "incomplete_output" ]
  | Missing_output -> `Assoc [ "kind", `String "missing_output" ]
  | Ambiguous_output count ->
    `Assoc [ "kind", `String "ambiguous_output"; "count", `Int count ]
  | Unexpected_output_content ->
    `Assoc [ "kind", `String "unexpected_output_content" ]
  | Invalid_json_output -> `Assoc [ "kind", `String "invalid_json_output" ]
  | Internal_non_json_output ->
    `Assoc [ "kind", `String "internal_non_json_output" ]
;;

let exact_execution_failure_to_yojson = function
  | Attempt_already_started { evidence } ->
    `Assoc
      [ "kind", `String "attempt_already_started"; "evidence", `String evidence ]
  | Attempt_start_failed { slot_id; detail; evidence } ->
    `Assoc
      [ "kind", `String "attempt_start_failed"
      ; "slot_id", `String slot_id
      ; "detail", `String detail
      ; "evidence", `String evidence
      ]
  | Measurement_start_failed { slot_id; detail; evidence } ->
    `Assoc
      [ "kind", `String "measurement_start_failed"
      ; "slot_id", `String slot_id
      ; "detail", `String detail
      ; "evidence", `String evidence
      ]
  | Before_measurement_dispatch_callback_failed { evidence } ->
    `Assoc
      [ "kind", `String "before_measurement_dispatch_callback_failed"
      ; "evidence", `String evidence
      ]
  | Measurement_terminal_callback_failed { evidence } ->
    `Assoc
      [ "kind", `String "measurement_terminal_callback_failed"
      ; "evidence", `String evidence
      ]
  | Before_dispatch_callback_failed { slot_id; call_id; evidence } ->
    `Assoc
      [ "kind", `String "before_dispatch_callback_failed"
      ; "slot_id", `String slot_id
      ; "call_id", `String call_id
      ; "evidence", `String evidence
      ]
  | Before_advance_callback_failed { next_slot_id; evidence } ->
    `Assoc
      [ "kind", `String "before_advance_callback_failed"
      ; "next_slot_id", `String next_slot_id
      ; "evidence", `String evidence
      ]
  | Candidates_exhausted { slot_id; detail; evidence } ->
    `Assoc
      [ "kind", `String "candidates_exhausted"
      ; "slot_id", `String slot_id
      ; "detail", `String detail
      ; "evidence", `String evidence
      ]
  | Candidate_execution_failed
      { slot_id; call_id; cause; raw_response_sha256; evidence } ->
    `Assoc
      [ "kind", `String "candidate_execution_failed"
      ; "slot_id", `String slot_id
      ; "call_id", `String call_id
      ; "cause", execution_cause_to_yojson cause
      ; ( "raw_response_sha256"
        , match raw_response_sha256 with
          | None -> `Null
          | Some sha256 -> `String sha256 )
      ; "evidence", `String evidence
      ]
;;

let execute ~net ?clock ?(observation_registry = Exact_lane_run_registry.global ()) prepared =
  let run_id = Random_id.prefixed ~prefix:"exact-assembler-" ~bytes:16 in
  let started_at = Time_compat.now () in
  Exact_lane_run_registry.register_running
    observation_registry
    ~run_id
    ~lane:Exact_lane_run_registry.Assembler
    ~actor:prepared.keeper_name
    ~started_at
    ~input:(Exact_lane_run_registry.Exact_input (observation_input prepared));
  let selected_slot = ref None in
  let complete outcome output =
    match
      Exact_lane_run_registry.mark_completed
        observation_registry
        ~run_id
        ~outcome
        ~elapsed_s:(Time_compat.now () -. started_at)
        ~selected_slot:!selected_slot
        ~output
    with
    | Ok () -> ()
    | Error error ->
      Log.Keeper.error
        ~keeper_name:prepared.keeper_name
        "assembler exact-run observation completion failed run_id=%s: %s"
        run_id
        (Exact_lane_run_registry.completion_error_to_string error)
  in
  let before_dispatch (receipt : Exact_output.flow_attempt_receipt) =
    selected_slot := Some receipt.visit.identity.candidate_id;
    Ok ()
  in
  let validate flow_success =
    let output = Exact_output.flow_success_output flow_success in
    match Request.output_of_yojson ~request:prepared.request output.output with
    | Error error -> Exact_output.Reject_and_advance (Output_invalid error)
    | Ok Request.Cannot_assemble ->
      Exact_output.Reject_and_advance Cannot_assemble
    | Ok (Request.Plan { plan_json; plan = _ }) ->
      (match
         Proposal.create
           ~descriptors:(Request.descriptors prepared.request)
           ~objective:(Request.objective prepared.request)
           ~execution:(Request.execution prepared.request)
           ~capability_surface_sha256:
             (Request.capability_surface_sha256 prepared.request)
           ~ordinary_tool_references:
             (Request.ordinary_tool_references prepared.request)
           ~plan_json
       with
       | Ok proposal -> Exact_output.Accept proposal
       | Error error ->
         Exact_output.Reject_and_advance (Proposal_invalid error))
  in
  let execution =
    try
      `Flow
        (Exact_output.execute_flow_once
           ~net
           ?clock
           ~before_measurement_dispatch:(fun _ -> Ok ())
           ~on_measurement_terminal:(fun _ -> Ok ())
           ~before_dispatch
           ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
           ~validate
           prepared.attempt)
    with
    | Eio.Cancel.Cancelled _ as cancellation ->
      let backtrace = Printexc.get_raw_backtrace () in
      complete Exact_lane_run_registry.Cancelled `Null;
      Printexc.raise_with_backtrace cancellation backtrace
    | exn ->
      complete
        (Exact_lane_run_registry.Failed
           { code = "assembler_raised"; detail = Printexc.to_string exn })
        `Null;
      raise exn
  in
  match execution with
  | `Flow (Ok flow_success) ->
    let proposal = flow_success.accepted in
    let selected_slot =
      flow_success.transport_success
      |> Exact_output.flow_success_candidate
      |> fun candidate -> candidate.visit.identity.candidate_id
    in
    let store =
      try `Result (Store.save prepared.config proposal) with
      | Eio.Cancel.Cancelled _ as cancellation ->
        let backtrace = Printexc.get_raw_backtrace () in
        complete Exact_lane_run_registry.Cancelled `Null;
        Printexc.raise_with_backtrace cancellation backtrace
      | exn ->
        complete
          (Exact_lane_run_registry.Failed
             { code = "proposal_store_raised"; detail = Printexc.to_string exn })
          `Null;
        raise exn
    in
    (match store with
     | `Result (Error error) ->
       complete
         (Exact_lane_run_registry.Failed
            { code = "proposal_store_failed"
            ; detail = Store.error_to_yojson error |> Yojson.Safe.to_string
            })
         (`Assoc [ "error", Store.error_to_yojson error ]);
       Error (Proposal_store_failed error)
     | `Result (Ok store_result) ->
       let proposal_id = Proposal.id proposal |> Proposal.Proposal_id.to_string in
       let semantic_rejections =
         List.map
           (fun rejection -> semantic_rejection_to_yojson rejection.Exact_output.rejection)
           flow_success.prior_rejections
       in
       complete
         Exact_lane_run_registry.Succeeded
         (`Assoc
            [ "proposal_id", `String proposal_id
            ; "proposal_digest", `String (Proposal.digest proposal)
            ; "store_result", `String (store_result_to_string store_result)
            ; "semantic_rejections", `List semantic_rejections
            ]);
       Ok { proposal; store_result; run_id; selected_slot })
  | `Flow
      (Error
        (Exact_output.Flow_execution_terminal { cause; prior_rejections })) ->
    let failure = flow_execution_failure cause in
    let failure_json = exact_execution_failure_to_yojson failure in
    let prior_semantic_rejections =
      List.map
        (fun rejection -> rejection.Exact_output.rejection)
        prior_rejections
    in
    let prior_semantic_rejections_json =
      List.map semantic_rejection_to_yojson prior_semantic_rejections
    in
    let detail = Yojson.Safe.to_string failure_json in
    complete
      (Exact_lane_run_registry.Failed
         { code = "exact_execution_failed"; detail })
      (`Assoc
         [ "failure", failure_json
         ; "prior_semantic_rejections", `List prior_semantic_rejections_json
         ]);
    Error (Exact_execution_failed { failure; prior_semantic_rejections })
  | `Flow
      (Error
        (Exact_output.Flow_semantic_candidates_exhausted
          { rejections; evidence = _ })) ->
    let rejections =
      rejections.first.rejection
      :: List.map
           (fun rejection -> rejection.Exact_output.rejection)
           rejections.rest
    in
    complete
      (Exact_lane_run_registry.Failed
         { code = "semantic_candidates_exhausted"
         ; detail = "every frozen Assembler candidate was semantically rejected"
         })
      (`Assoc
         [ ( "semantic_rejections"
           , `List (List.map semantic_rejection_to_yojson rejections) )
         ]);
    Error (Semantic_candidates_exhausted rejections)
;;

let setup_error_to_yojson = function
  | Prompt_projection_failed error ->
    `Assoc
      [ "kind", `String "prompt_projection_failed"
      ; "error", Request.error_to_yojson error
      ]
  | Prompt_render_failed detail ->
    `Assoc
      [ "kind", `String "prompt_render_failed"; "detail", `String detail ]
  | Registry_unavailable error ->
    `Assoc
      [ "kind", `String "registry_unavailable"
      ; "detail", `String (Registry.publication_error_to_string error)
      ]
  | Lane_unavailable error ->
    `Assoc
      [ "kind", `String "lane_unavailable"
      ; "detail", `String (Registry.lane_resolution_error_to_string error)
      ]
  | Lane_preference_unavailable detail ->
    `Assoc
      [ "kind", `String "lane_preference_unavailable"
      ; "detail", `String detail
      ]
  | Invalid_candidate { position; slot_id } ->
    `Assoc
      [ "kind", `String "invalid_candidate"
      ; "position", `Int position
      ; "slot_id", `String slot_id
      ]
  | Lane_resolved_without_candidates ->
    `Assoc [ "kind", `String "lane_resolved_without_candidates" ]
  | Flow_snapshot_failed { candidate_id; first_position; duplicate_position } ->
    `Assoc
      [ "kind", `String "flow_snapshot_failed"
      ; "candidate_id", `String candidate_id
      ; "first_position", `Int first_position
      ; "duplicate_position", `Int duplicate_position
      ]
  | Flow_start_failed detail ->
    `Assoc
      [ "kind", `String "flow_start_failed"; "detail", `String detail ]
;;

let execution_error_to_yojson = function
  | Exact_execution_failed { failure; prior_semantic_rejections } ->
    `Assoc
      [ "kind", `String "exact_execution_failed"
      ; "failure", exact_execution_failure_to_yojson failure
      ; ( "prior_semantic_rejections"
        , `List
            (List.map
               semantic_rejection_to_yojson
               prior_semantic_rejections) )
      ]
  | Semantic_candidates_exhausted rejections ->
    `Assoc
      [ "kind", `String "semantic_candidates_exhausted"
      ; ( "rejections"
        , `List (List.map semantic_rejection_to_yojson rejections) )
      ]
  | Proposal_store_failed error ->
    `Assoc
      [ "kind", `String "proposal_store_failed"
      ; "error", Store.error_to_yojson error
      ]
;;
