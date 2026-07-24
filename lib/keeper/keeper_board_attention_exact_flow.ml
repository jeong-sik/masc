module Exact_output = Agent_sdk.Exact_output

let ( let* ) = Result.bind
let lane_id = "board_attention_exact"

type setup_error =
  | Network_unavailable
  | Candidate_not_pending
  | Prompt_contract_unavailable of string
  | Registry_unavailable
  | Lane_unavailable
  | Lane_resolved_without_slots
  | Candidate_invalid of
      { position : int
      ; slot_id : string
      }
  | Flow_admission_failed
  | Flow_start_failed

type attempt_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type 'callback_error execution_error =
  | Flow_already_started of attempt_provenance list
  | Before_dispatch_persistence_failed of
      { cause : 'callback_error
      ; current : attempt_provenance
      ; evidence : attempt_provenance list
      }
  | Before_advance_persistence_failed of
      { cause : 'callback_error
      ; failed : attempt_provenance
      ; next : attempt_provenance
      ; evidence : attempt_provenance list
      }
  | Exact_execution_failed of attempt_provenance list
  | Provenance_mismatch of string
  | Domain_output_invalid of string

type prepared =
  { candidate : Keeper_board_attention_candidate.candidate
  ; net : Eio_context.eio_net
  ; attempt : Exact_output.flow_attempt
  }

let message role text =
  Agent_sdk.Types.make_message ~role [ Agent_sdk.Types.Text text ]
;;

let messages candidate =
  let* request =
    Keeper_board_attention_candidate.singleton_judgment_request candidate
  in
  let* prompt =
    Prompt_registry.render_prompt_template
      Keeper_prompt_names.board_attention_judgment_batch
      [ "batch_request_json", Yojson.Safe.to_string request ]
  in
  Ok [ message Agent_sdk.Types.User prompt ]
;;

let flow_candidates selected_slots =
  let rec loop position acc = function
    | [] -> Ok (List.rev acc)
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate ~id:slot.slot_id ~target:slot.target
       with
       | Ok candidate -> loop (position + 1) (candidate :: acc) rest
       | Error Exact_output.Blank_flow_candidate_id ->
         Error (Candidate_invalid { position; slot_id = slot.slot_id }))
  in
  loop 0 [] selected_slots
;;

let prepare ~net candidate =
  match candidate.Keeper_board_attention_candidate.status, net with
  | (Keeper_board_attention_candidate.Judged _
    | Keeper_board_attention_candidate.Consumed _), _ ->
    Error Candidate_not_pending
  | Keeper_board_attention_candidate.Pending _, None -> Error Network_unavailable
  | Keeper_board_attention_candidate.Pending _, Some net ->
    let* messages =
      messages candidate
      |> Result.map_error (fun detail -> Prompt_contract_unavailable detail)
    in
    let* registry =
      Runtime_exact_output_registry.current ()
      |> Result.map_error (fun _ -> Registry_unavailable)
    in
    let* resolved =
      Runtime_exact_output_registry.resolve_lane registry ~lane_id
      |> Result.map_error (fun _ -> Lane_unavailable)
    in
    let* candidates = flow_candidates resolved.selected_slots in
    (match candidates with
     | [] -> Error Lane_resolved_without_slots
     | first :: rest ->
       let requirement =
         Exact_output.make_output_requirement
           ~schema:
             Keeper_structured_output_schema
             .board_attention_judgment_batch_output_schema
           ~minimum_guarantee:Exact_output.Json_syntax
       in
       let* ready_flow =
         Exact_output.admit_flow ~first ~rest ~messages requirement
         |> Result.map_error (fun _ -> Flow_admission_failed)
       in
       let* attempt =
         Exact_output.start_flow ready_flow
         |> Result.map_error (fun _ -> Flow_start_failed)
       in
       Ok { candidate; net; attempt })
;;

let string_of_call_id call_id = Exact_output.call_id_to_string call_id

let attempt_provenance
      (attempt : Exact_output.flow_attempt_receipt)
  =
  { slot_id = attempt.identity.candidate_id
  ; call_id =
      attempt.receipt
      |> Exact_output.receipt_call_id
      |> string_of_call_id
  ; plan_fingerprint =
      Exact_output.receipt_plan_fingerprint attempt.receipt
  ; request_body_sha256 =
      Exact_output.receipt_request_body_sha256 attempt.receipt
  }
;;

let evidence_provenance (evidence : Exact_output.flow_evidence) =
  List.map attempt_provenance evidence.attempts
;;

let admitted_candidate candidate_id admissions =
  List.find_map
    (function
      | Exact_output.Candidate_admitted admitted
        when String.equal admitted.identity.candidate_id candidate_id ->
        Some admitted
      | Exact_output.Candidate_admitted _ | Exact_output.Candidate_rejected _ ->
        None)
    admissions
;;

let require_equal ~field left right =
  if String.equal left right
  then Ok ()
  else
    Error
      (Provenance_mismatch
         (Printf.sprintf "%s mismatch left=%S right=%S" field left right))
;;

let judgment_of_success candidate (flow_success : Exact_output.flow_success) =
  let selected = flow_success.candidate in
  let success = flow_success.success in
  let current = attempt_provenance selected in
  let slot_id = current.slot_id in
  let* admitted =
    match admitted_candidate slot_id flow_success.evidence.admissions with
    | Some admitted -> Ok admitted
    | None ->
      Error
        (Provenance_mismatch
           ("selected slot has no admitted evidence: " ^ slot_id))
  in
  let call_id = string_of_call_id success.call_id in
  let success_receipt_call_id =
    success.receipt |> Exact_output.receipt_call_id |> string_of_call_id
  in
  let selected_receipt_call_id =
    selected.receipt |> Exact_output.receipt_call_id |> string_of_call_id
  in
  let selected_plan_fingerprint =
    Exact_output.receipt_plan_fingerprint selected.receipt
  in
  let success_plan_fingerprint =
    Exact_output.receipt_plan_fingerprint success.receipt
  in
  let selected_request_body_sha256 =
    Exact_output.receipt_request_body_sha256 selected.receipt
  in
  let success_request_body_sha256 =
    Exact_output.receipt_request_body_sha256 success.receipt
  in
  let* () = require_equal ~field:"success call id" call_id success_receipt_call_id in
  let* () =
    require_equal
      ~field:"selected call id"
      call_id
      selected_receipt_call_id
  in
  let* () =
    require_equal
      ~field:"admitted plan fingerprint"
      admitted.plan_fingerprint
      selected_plan_fingerprint
  in
  let* () =
    require_equal
      ~field:"success plan fingerprint"
      selected_plan_fingerprint
      success_plan_fingerprint
  in
  let* () =
    require_equal
      ~field:"admitted request hash"
      admitted.request_body_sha256
      selected_request_body_sha256
  in
  let* () =
    require_equal
      ~field:"success request hash"
      selected_request_body_sha256
      success_request_body_sha256
  in
  let* items =
    Keeper_board_attention_judgment.batch_of_yojson success.output
    |> Result.map_error (fun detail -> Domain_output_invalid detail)
  in
  match items with
  | [ item ]
    when String.equal
           item.candidate_id
           candidate.Keeper_board_attention_candidate.candidate_id ->
    Ok
      { Keeper_board_attention_candidate.verdict = item.verdict
      ; slot_id
      ; call_id
      ; plan_fingerprint = selected_plan_fingerprint
      ; request_body_sha256 = selected_request_body_sha256
      ; judged_at = Time_compat.now ()
      }
  | [ item ] ->
    Error
      (Domain_output_invalid
         (Printf.sprintf
            "singleton verdict identity mismatch expected=%S actual=%S"
            candidate.candidate_id
            item.candidate_id))
  | items ->
    Error
      (Domain_output_invalid
         (Printf.sprintf
            "singleton verdict count must be exactly one, got %d"
            (List.length items)))
;;

let execute ?clock ~before_dispatch ~before_advance prepared =
  let oas_before_dispatch receipt =
    before_dispatch (attempt_provenance receipt)
  in
  let oas_before_advance ~failed ~failure:_ ~next =
    before_advance
      ~failed:(attempt_provenance failed)
      ~next:(attempt_provenance next)
  in
  match
    Exact_output.execute_flow_once
      ~net:prepared.net
      ?clock
      ~before_dispatch:oas_before_dispatch
      ~before_advance:oas_before_advance
      prepared.attempt
  with
  | Ok success -> judgment_of_success prepared.candidate success
  | Error (Exact_output.Flow_attempt_already_started evidence) ->
    Error (Flow_already_started (evidence_provenance evidence))
  | Error
      (Exact_output.Flow_before_dispatch_callback_failed
         { cause; evidence; candidate }) ->
    Error
      (Before_dispatch_persistence_failed
         { cause
         ; current = attempt_provenance candidate
         ; evidence = evidence_provenance evidence
         })
  | Error
      (Exact_output.Flow_before_advance_callback_failed
         { cause; evidence; failed; failure = _; next }) ->
    Error
      (Before_advance_persistence_failed
         { cause
         ; failed = attempt_provenance failed
         ; next = attempt_provenance next
         ; evidence = evidence_provenance evidence
         })
  | Error
      (Exact_output.Flow_exact_execution_failed
         { evidence; candidate = _; cause = _ }) ->
    Error (Exact_execution_failed (evidence_provenance evidence))
;;
