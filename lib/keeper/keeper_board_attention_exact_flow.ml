module Exact_output = Agent_core.Exact_output

let ( let* ) = Result.bind
let lane_id = "board_attention_exact"

type setup_error =
  | Network_unavailable
  | Candidate_not_pending
  | Prompt_contract_unavailable of string
  | Registry_unavailable
  | Lane_unavailable
  | Lane_preference_unavailable of string
  | Lane_resolved_without_slots
  | Candidate_invalid of
      { position : int
      ; slot_id : string
      }
  | Flow_snapshot_failed
  | Flow_start_failed

type attempt_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type candidate_visit =
  { flow_id : string
  ; ordinal : int
  ; slot_id : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; target_identity_fingerprint : string
  }

type advance_source =
  | Executed_failure of attempt_provenance
  | Predispatch_rejection of candidate_visit

type 'callback_error execution_error =
  | Flow_already_started of attempt_provenance list
  | Before_dispatch_persistence_failed of
      { cause : 'callback_error
      ; current : attempt_provenance
      ; evidence : attempt_provenance list
      }
  | Before_advance_persistence_failed of
      { cause : 'callback_error
      ; failed : advance_source
      ; next : candidate_visit
      ; evidence : attempt_provenance list
      }
  | Providers_exhausted of
      { attempts : attempt_provenance list
      ; detail : string
      }
  | Cli_slots_exhausted of
      { prior_error : 'callback_error execution_error option
      ; failures : Keeper_lane_cli_oneshot.failure list
      }
  | Flow_bookkeeping_failed of
      { attempts : attempt_provenance list
      ; detail : string
      }
  | Provenance_mismatch of string
  | Domain_output_invalid of string

type prepared_transport =
  | Http_flow of Exact_output.flow_attempt
  | Cli_only of
      { first_slot : string
      ; other_slots : string list
      }
      (** [prepare] refuses a lane with neither transport, so a CLI-only lane
          has a slot. Carrying it here is what makes that unwritable: the
          walk cannot be asked to report "no slots declared" on a path whose
          value proves one. *)

type prepared =
  { candidate : Keeper_board_attention_candidate.candidate
  ; net : Eio_context.eio_net
  ; transport : prepared_transport
  ; base_path : string
  ; cli_slots : string list
        (** Carried from the same lane resolution the catalog slots came from,
            so the tail cannot drift from the flow it follows. *)
  ; prompt : string
  ; request : Yojson.Safe.t
        (** Built from the same material [prompt] was rendered from, so the run
            record cannot say something the judge did not read. *)
  ; requirement : Exact_output.output_requirement
  }

let message role text =
  Agent_core.Types.make_message ~role [ Agent_core.Types.Text text ]
;;

let judge_prompt candidate material =
  let request =
    Keeper_board_attention_candidate.singleton_judgment_request candidate material
  in
  Prompt_registry.render_prompt_template
    Prompt_names.judge_board
    [ "judgment_request_json", Yojson.Safe.to_string request ]
;;

let flow_candidates selected_slots =
  let rec loop position acc = function
    | [] -> Ok (List.rev acc)
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match
         Exact_output.make_flow_candidate
           ~id:slot.slot_id
           ~admitted_target:slot.admitted_target
       with
       | Ok candidate -> loop (position + 1) (candidate :: acc) rest
       | Error Exact_output.Blank_flow_candidate_id ->
         Error (Candidate_invalid { position; slot_id = slot.slot_id }))
  in
  loop 0 [] selected_slots
;;

let prepare ~base_path ~keeper_name ~net candidate =
  match
    ( Keeper_board_attention_candidate.status_view
        candidate.Keeper_board_attention_candidate.status
    , net )
  with
  | ( Keeper_board_attention_candidate.Suspended_quarantine _
    | Keeper_board_attention_candidate.Direct_resumable
        (Keeper_board_attention_candidate.Resumable_judged _
        | Keeper_board_attention_candidate.Resumable_consumed _)
    | Keeper_board_attention_candidate.Requeued_resumable
        { resumable =
            (Keeper_board_attention_candidate.Resumable_judged _
            | Keeper_board_attention_candidate.Resumable_consumed _)
        ; _
        } ), _ ->
    Error Candidate_not_pending
  | ( Keeper_board_attention_candidate.Direct_resumable
        (Keeper_board_attention_candidate.Resumable_pending _)
    | Keeper_board_attention_candidate.Requeued_resumable
        { resumable = Keeper_board_attention_candidate.Resumable_pending _; _ }
    ), None ->
    Error Network_unavailable
  | ( Keeper_board_attention_candidate.Direct_resumable
        (Keeper_board_attention_candidate.Resumable_pending pending)
    | Keeper_board_attention_candidate.Requeued_resumable
        { resumable = Keeper_board_attention_candidate.Resumable_pending pending; _ }
    ), Some net ->
    let material = pending.Keeper_board_attention_candidate.material in
    let request =
      Keeper_board_attention_candidate.judgment_request candidate material
    in
    let* prompt =
      judge_prompt candidate material
      |> Result.map_error (fun detail -> Prompt_contract_unavailable detail)
    in
    let messages = [ message Agent_core.Types.User prompt ] in
    let* registry =
      Runtime_exact_output_registry.current ()
      |> Result.map_error (fun _ -> Registry_unavailable)
    in
    let* resolved =
      Runtime_exact_output_registry.resolve_lane registry ~lane_id
      |> Result.map_error (fun _ -> Lane_unavailable)
    in
    let* resolved =
      (Keeper_exact_lane_preference.apply
         ~base_path
         ~keeper_name
         ~lane_id
         resolved)
      |> Result.map_error (fun detail -> Lane_preference_unavailable detail)
    in
    let* candidates = flow_candidates resolved.selected_slots in
    let requirement =
      Exact_output.make_output_requirement
        ~schema:Keeper_structured_output_schema.board_attention_judgment_batch_output_schema
        ~minimum_guarantee:Exact_output.Json_syntax
    in
    let* transport =
      match candidates, resolved.cli_slots with
      | [], [] -> Error Lane_resolved_without_slots
      | [], first_slot :: other_slots -> Ok (Cli_only { first_slot; other_slots })
      | first :: rest, _ ->
        let* snapshot =
          Exact_output.snapshot_flow ~first ~rest ~messages requirement
          |> Result.map_error (fun _ -> Flow_snapshot_failed)
        in
        Exact_output.start_flow snapshot
        |> Result.map (fun attempt -> Http_flow attempt)
        |> Result.map_error (fun _ -> Flow_start_failed)
    in
    Ok { candidate; net; transport; base_path; cli_slots = resolved.cli_slots;
         prompt; request; requirement }

;;

let string_of_call_id call_id = Exact_output.call_id_to_string call_id

let attempt_provenance
      (attempt : Exact_output.flow_attempt_receipt)
  =
  { slot_id = attempt.visit.identity.candidate_id
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

let attempt_snapshot_provenance
      (attempt : Exact_output.flow_attempt_snapshot)
  =
  { slot_id = attempt.visit.identity.candidate_id
  ; call_id =
      attempt.receipt
      |> Exact_output.generation_receipt_snapshot_call_id
      |> string_of_call_id
  ; plan_fingerprint =
      Exact_output.generation_receipt_snapshot_plan_fingerprint attempt.receipt
  ; request_body_sha256 =
      Exact_output.generation_receipt_snapshot_request_body_sha256 attempt.receipt
  }
;;

let candidate_visit (visit : Exact_output.flow_candidate_visit) =
  let identity = visit.identity in
  { flow_id = Exact_output.flow_id_to_string visit.flow_id
  ; ordinal = Exact_output.flow_visit_ordinal_to_int visit.ordinal
  ; slot_id = identity.candidate_id
  ; catalog_generation_fingerprint =
      Exact_output.catalog_generation_fingerprint identity.catalog_generation
  ; catalog_evidence_sha256 =
      Exact_output.catalog_evidence_sha256 identity.catalog_evidence
  ; target_identity_fingerprint =
      Exact_output.target_identity_fingerprint identity.target_identity
  }
;;

let advance_source_of_failure = function
  | Exact_output.Flow_candidate_execution_failed { candidate; cause = _ } ->
    Executed_failure (attempt_provenance candidate)
  | Exact_output.Flow_candidate_rejected rejection ->
    Predispatch_rejection
      (rejection |> Exact_output.candidate_rejection_visit |> candidate_visit)
;;

let evidence_provenance (evidence : Exact_output.flow_evidence) =
  List.map attempt_snapshot_provenance evidence.attempts
;;

let terminal_of_flow_error = function
  | Exact_output.Flow_attempt_already_started evidence ->
    Flow_already_started (evidence_provenance evidence)
  | Exact_output.Flow_before_dispatch_callback_failed
      { cause; evidence; candidate } ->
    Before_dispatch_persistence_failed
      { cause
      ; current = attempt_provenance candidate
      ; evidence = evidence_provenance evidence
      }
  | Exact_output.Flow_before_advance_callback_failed
      { cause; evidence; failed; next } ->
    Before_advance_persistence_failed
      { cause
      ; failed = advance_source_of_failure failed
      ; next = candidate_visit next
      ; evidence = evidence_provenance evidence
      }
  | ( Exact_output.Flow_attempt_start_failed { evidence; _ }
    | Exact_output.Flow_measurement_start_failed { evidence; _ }
    | Exact_output.Flow_before_measurement_dispatch_callback_failed { evidence; _ }
    | Exact_output.Flow_measurement_terminal_callback_failed { evidence; _ } ) as cause ->
    Flow_bookkeeping_failed
      { attempts = evidence_provenance evidence
      ; detail = Keeper_exact_flow_detail.flow_execution_error_detail cause
      }
  | ( Exact_output.Flow_candidates_exhausted { evidence; _ }
    | Exact_output.Flow_exact_execution_failed { evidence; _ } ) as cause ->
    Providers_exhausted
      { attempts = evidence_provenance evidence
      ; detail = Keeper_exact_flow_detail.flow_execution_error_detail cause
      }
;;

let admitted_candidate candidate_id admissions =
  List.find_map
    (function
      | Exact_output.Candidate_admitted admitted
        when String.equal admitted.visit.identity.candidate_id candidate_id ->
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

(* The batch decoder and the singleton identity check are the same question on
   both transports: did this answer judge exactly this candidate. Only the
   provenance recorded alongside differs, so the two callers share this. *)
let verdict_of_batch_output candidate output =
  let* items = Keeper_board_attention_judgment.batch_of_yojson output in
  match items with
  | [ item ]
    when String.equal
           item.candidate_id
           candidate.Keeper_board_attention_candidate.candidate_id ->
    Ok item.verdict
  | [ item ] ->
    Error (Printf.sprintf
      "singleton verdict identity mismatch expected=%S actual=%S"
      candidate.Keeper_board_attention_candidate.candidate_id item.candidate_id)
  | items ->
    Error (Printf.sprintf "singleton verdict count must be exactly one, got %d"
      (List.length items))
;;

let judgment_of_success candidate (flow_success : Exact_output.flow_success) =
  let selected = Exact_output.flow_success_candidate flow_success in
  let success = Exact_output.flow_success_output flow_success in
  let current = attempt_provenance selected in
  let slot_id = current.slot_id in
  let* admitted =
    match
      admitted_candidate
        slot_id
        (Exact_output.flow_success_evidence flow_success).admissions
    with
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
  let* verdict = verdict_of_batch_output candidate success.output
    |> Result.map_error (fun detail -> Domain_output_invalid detail) in
  Ok
    { Keeper_board_attention_candidate.verdict
    ; slot_id
    ; source =
        Keeper_board_attention_candidate.Exact_attempt
          { call_id
          ; plan_fingerprint = selected_plan_fingerprint
          ; request_body_sha256 = selected_request_body_sha256
          }
    ; judged_at = Time_compat.now ()
    }
;;

(* RFC cli-runtimes-as-lane-slots: after every catalog slot is exhausted the
   lane walks its declared official clients as one-shots. This lane is
   boot-mandatory and its catalog slots share two quota pools, so without a
   tail an exhausted pool stops Board attention outright.

   The walk runs inside [execute_current], which also closes the lane's run
   record, after semantic exhaustion or a typed advanceable final failure.
   The record therefore names the slot that answered (RFC §3:
   [selected_slot] is the runtime id). The judgment says [Cli_lane_slot], so
   the durable record never claims an AGENT_CORE attempt that was not
   allocated. *)
type cli_tail_error =
  | Tail_no_slots
  | Tail_failures of Keeper_lane_cli_oneshot.failure list

(* For the log line only. The durable error keeps the failures as they are. *)
let cli_tail_error_to_string = function
  | Tail_no_slots -> "lane declares no cli slots"
  | Tail_failures failures ->
    String.concat
      "; "
      (List.map Keeper_lane_cli_oneshot.failure_to_string failures)

;;

let walk_cli_slots ?runner ~base_path ~cli_slots prepared =
  (match
       Keeper_lane_cli_oneshot.walk
         ?runner
         ~base_dir:base_path
         ~cli_slots
         ~system_prompt:""
         ~requirement:prepared.requirement
         ~prompt:prepared.prompt
         ~validate:(verdict_of_batch_output prepared.candidate)
         ~on_failure:(fun failure ->
           Log.Keeper.warn ~keeper_name:prepared.candidate.keeper_name
             "board attention cli lane-slot failed: %s"
             (Keeper_lane_cli_oneshot.failure_to_string failure))
         ()
     with
     | Error failures -> Error failures
     | Ok (slot_id, verdict) ->
       Ok
         ( slot_id
         , { Keeper_board_attention_candidate.verdict
           ; slot_id
           ; source = Keeper_board_attention_candidate.Cli_lane_slot
           ; judged_at = Time_compat.now ()
           } ))
;;

(* The tail an HTTP lane walks after its slots are exhausted. This lane may
   declare none, which is not a failure of anything walked. *)
let run_cli_tail ?runner ~base_path prepared =
  match prepared.cli_slots with
  | [] -> Error Tail_no_slots
  | cli_slots ->
    (match walk_cli_slots ?runner ~base_path ~cli_slots prepared with
     | Error failures -> Error (Tail_failures failures)
     | Ok answered -> Ok answered)
;;

type terminal_outcome =
  | Judgment_completed
  | Flow_replayed
  | Before_dispatch_persistence_failure
  | Before_advance_persistence_failure
  | Exact_execution_failure
  | Flow_bookkeeping_failure
  | Execution_provenance_mismatch
  | Invalid_domain_output

let terminal_outcome_to_string = function
  | Judgment_completed -> "judgment_completed"
  | Flow_replayed -> "flow_replayed"
  | Before_dispatch_persistence_failure -> "before_dispatch_persistence_failure"
  | Before_advance_persistence_failure -> "before_advance_persistence_failure"
  | Exact_execution_failure -> "exact_execution_failure"
  | Flow_bookkeeping_failure -> "flow_bookkeeping_failure"
  | Execution_provenance_mismatch -> "execution_provenance_mismatch"
  | Invalid_domain_output -> "invalid_domain_output"
;;

let terminal_outcome = function
  | Ok _ -> Judgment_completed
  | Error (Flow_already_started _) -> Flow_replayed
  | Error (Before_dispatch_persistence_failed _) ->
    Before_dispatch_persistence_failure
  | Error (Before_advance_persistence_failed _) ->
    Before_advance_persistence_failure
  | Error (Providers_exhausted _) | Error (Cli_slots_exhausted _) ->
    Exact_execution_failure
  | Error (Flow_bookkeeping_failed _) -> Flow_bookkeeping_failure
  | Error (Provenance_mismatch _) -> Execution_provenance_mismatch
  | Error (Domain_output_invalid _) -> Invalid_domain_output
;;

(* What TypeSafe AI Jev answered for a candidate before any catalog slot ran.
   Only [Jev_relevant] settles the candidate: a not-relevant verdict drops the
   post for this keeper, so the LLM lane judges it again, and so does every arm
   where Jev gave no answer. The terminal log line carries this value, so what
   Jev said and what the lane then decided are read from one entry. *)
type jev_first =
  | Jev_off
      (** No [TYPESAFEAI_API_KEY], or [MASC_TYPESAFEAI_ENABLED=false]. *)
  | Jev_cli_only
      (** Jev is on, but the lane declares no HTTP slot. Jev is asked only in
          front of the HTTP lane. *)
  | Jev_not_pending
      (** Jev is on, but the candidate is not [Pending], so there is no
          material to send. *)
  | Jev_relevant of
      { provenance : Keeper_board_attention_candidate.system_one_provenance
      ; verdict : Keeper_board_attention_judgment.t
      ; judged_at : float
      }
  | Jev_not_relevant of
      { provenance : Keeper_board_attention_candidate.system_one_provenance
      ; rationale : string
      }
  | Jev_failed of { reason : string }

let ask_jev ~clock prepared =
  if not (Typesafeai_config.is_enabled ())
  then Jev_off
  else (
    match Typesafeai_config.api_key () with
    | None -> Jev_off
    | Some api_key ->
      (match prepared.transport with
       | Cli_only _ -> Jev_cli_only
       | Http_flow _ ->
         (match prepared.candidate.status with
          | Keeper_board_attention_candidate.Judged _
          | Keeper_board_attention_candidate.Consumed _
          | Keeper_board_attention_candidate.Quarantine _ -> Jev_not_pending
          | Keeper_board_attention_candidate.Pending { material; _ } ->
            (* A direct-style Eio request on this keeper's board-attention
               worker fiber: the wait suspends that fiber alone, as the
               [Exact_output] request does, so it delays this candidate's
               judgment and nothing else on the domain. *)
            (match
               Typesafeai_board_attention.judge_candidate
                 ~clock
                 ~api_key
                 ~candidate:prepared.candidate
                 ~material
                 ()
             with
             | Error reason -> Jev_failed { reason }
             | Ok { Typesafeai_board_attention.verdict; provenance } ->
               (match verdict.Keeper_board_attention_judgment.decision with
                | Keeper_board_attention_judgment.Relevant ->
                  (* The lane's clock, never the wall: both entries into this
                     flow hold one, so a judgment's time comes from the same
                     source the rest of the turn is measured against. *)
                  Jev_relevant
                    { provenance; verdict; judged_at = Eio.Time.now clock }
                | Keeper_board_attention_judgment.Not_relevant ->
                  Jev_not_relevant
                    { provenance
                    ; rationale = verdict.Keeper_board_attention_judgment.rationale
                    })))))
;;

let jev_answer_label = function
  | Jev_off -> "off"
  | Jev_cli_only -> "cli_only"
  | Jev_not_pending -> "not_pending"
  | Jev_relevant _ ->
    Keeper_board_attention_judgment.decision_to_string
      Keeper_board_attention_judgment.Relevant
  | Jev_not_relevant _ ->
    Keeper_board_attention_judgment.decision_to_string
      Keeper_board_attention_judgment.Not_relevant
  | Jev_failed _ -> "failed"
;;

(* [rejudged] appears only after a not-relevant answer. It is the decision the
   LLM lane then returned, or [null] when this flow returned no judgment; the
   worker may still ask a CLI slot after that, which this entry does not see. *)
let jev_first_to_yojson jev_first result =
  let answer = "answer", `String (jev_answer_label jev_first) in
  let with_provenance provenance fields =
    `Assoc
      (fields
       @ [ ( "provenance"
           , Keeper_board_attention_candidate.system_one_provenance_to_yojson
               provenance ) ])
  in
  match jev_first with
  | Jev_off | Jev_cli_only | Jev_not_pending -> `Assoc [ answer ]
  | Jev_relevant { provenance; _ } ->
    with_provenance provenance [ answer ]
  | Jev_failed { reason } -> `Assoc [ answer; "reason", `String reason ]
  | Jev_not_relevant { provenance; rationale } ->
    let rejudged =
      match result with
      | Ok (judgment : Keeper_board_attention_candidate.judgment) ->
        `String
          (Keeper_board_attention_judgment.decision_to_string
             judgment.Keeper_board_attention_candidate.verdict.Keeper_board_attention_judgment.decision)
      | Error _ -> `Null
    in
    with_provenance
      provenance
      [ answer
      ; "rationale", `String rationale
      ; "rejudged", rejudged
      ]
;;

let observe_terminal prepared ~jev_first result =
  let outcome = result |> terminal_outcome |> terminal_outcome_to_string in
  Log.Keeper.emit
    Log.Info
    ~keeper_name:prepared.candidate.keeper_name
    ~details:
      (`Assoc
          [ "candidate_id", `String prepared.candidate.candidate_id
          ; "outcome", `String outcome
          ; "jev", jev_first_to_yojson jev_first result
          ])
    (Printf.sprintf
       "board_attention exact_flow.execute terminal candidate_id=%s outcome=%s jev=%s"
       prepared.candidate.candidate_id
       outcome
       (jev_answer_label jev_first))
;;

let execute_current ?cli_runner ~clock ~before_dispatch ~before_advance prepared =
  let registry = Exact_lane_run_registry.global () in
  let run_id = Random_id.prefixed ~prefix:"exact-board-attention-" ~bytes:16 in
  let started_at = Time_compat.now () in
  Exact_lane_run_registry.register_running
    registry
    ~run_id
    ~lane:Exact_lane_run_registry.Board_attention
    ~actor:prepared.candidate.keeper_name
    ~started_at
    ~input:(Exact_lane_run_registry.Exact_input prepared.request);
  let bound = ref None in
  let cli_selected_slot = ref None in
  let complete outcome output =
    (* A CLI answer after the HTTP slots failed leaves [bound] on the last
       failed HTTP slot; the slot that answered is the CLI one. *)
    let selected_slot =
      match !cli_selected_slot, !bound with
      | Some slot_id, _ -> Some slot_id
      | None, Some (provenance : attempt_provenance) -> Some provenance.slot_id
      | None, None -> None
    in
    match
      Exact_lane_run_registry.mark_completed
        registry
        ~run_id
        ~outcome
        ~elapsed_s:(Time_compat.now () -. started_at)
        ~selected_slot
        ~output
    with
    | Ok () -> ()
    | Error error ->
      Log.Keeper.error
        ~keeper_name:prepared.candidate.keeper_name
        "board-attention exact-run observation completion failed run_id=%s: %s"
        run_id
        (Exact_lane_run_registry.completion_error_to_string error)
  in
  let agent_core_before_dispatch receipt =
    let current = attempt_provenance receipt in
    let* () =
      match !bound with
      | None -> Ok ()
      | Some failed ->
        before_advance
          ~failed:(Executed_failure failed)
          ~next:(candidate_visit receipt.visit)
    in
    let* () = before_dispatch current in
    bound := Some current;
    Ok ()
  in
  let agent_core_before_advance ~failed ~next =
    let* () =
      before_advance
        ~failed:(advance_source_of_failure failed)
        ~next:(candidate_visit next)
    in
    bound := None;
    Ok ()
  in
  let validate flow_success =
    match judgment_of_success prepared.candidate flow_success with
    | Ok judgment -> Exact_output.Accept judgment
    | Error rejection -> Exact_output.Reject_and_advance rejection
  in
  let run_cli_after_http prior_error =
    match
      run_cli_tail
        ?runner:cli_runner
        ~base_path:prepared.base_path
        prepared
    with
    | Ok (slot_id, judgment) ->
      Log.Keeper.info
        "board_attention_cli_tail_judged keeper=%s slot=%s"
        prepared.candidate.keeper_name
        slot_id;
      cli_selected_slot := Some slot_id;
      Ok judgment
    | Error Tail_no_slots -> Error prior_error
    | Error (Tail_failures failures as error) ->
      Log.Keeper.warn
        "board_attention_cli_tail_failed keeper=%s reason=%s"
        prepared.candidate.keeper_name
        (cli_tail_error_to_string error);
      Error (Cli_slots_exhausted { prior_error = Some prior_error; failures })
  in
  let jev_first, result =
    try
      let jev_first = ask_jev ~clock prepared in
      let result =
        match prepared.transport with
        | Cli_only { first_slot; other_slots } ->
          (match
             walk_cli_slots
               ?runner:cli_runner
               ~base_path:prepared.base_path
               ~cli_slots:(first_slot :: other_slots)
               prepared
           with
           | Ok (slot_id, judgment) -> cli_selected_slot := Some slot_id; Ok judgment
           | Error failures ->
             Error (Cli_slots_exhausted { prior_error = None; failures }))
        | Http_flow attempt ->
          (match jev_first with
           | Jev_relevant { provenance; verdict; judged_at } ->
             Ok
               { Keeper_board_attention_candidate.verdict
               ; slot_id = provenance.answering_model_id
               ; source =
                   Keeper_board_attention_candidate.Vendor_system_one provenance
               ; judged_at
               }
           | Jev_off | Jev_cli_only | Jev_not_pending | Jev_not_relevant _ | Jev_failed _ ->
             (match
                Exact_output.execute_flow_once
                  ~net:prepared.net
                  ~clock
                  ~before_measurement_dispatch:(fun _ -> Ok ())
                  ~on_measurement_terminal:(fun _ -> Ok ())
                  ~before_dispatch:agent_core_before_dispatch
                  ~before_advance:agent_core_before_advance
                  ~validate
                  attempt
              with
              | Ok success -> Ok success.accepted
              | Error (Exact_output.Flow_execution_terminal { cause; _ }) ->
                let terminal = terminal_of_flow_error cause in
                (match Exact_output.flow_execution_terminal_kind cause with
                 | Exact_output.Advanceable_candidates_exhausted ->
                   run_cli_after_http terminal
                 | Exact_output.Non_advanceable_terminal -> Error terminal)
              | Error
                  (Exact_output.Flow_semantic_candidates_exhausted { rejections; _ }) ->
                let rejection =
                  List.fold_left
                    (fun _ rejection -> rejection)
                    rejections.first
                    rejections.rest
                in
                run_cli_after_http rejection.rejection))
      in
      jev_first, result
    with
    | Eio.Cancel.Cancelled _ as exn ->
      complete Exact_lane_run_registry.Cancelled `Null;
      raise exn
    | exn ->
      complete
        (Exact_lane_run_registry.Failed
           { code = "board_attention_raised"; detail = Printexc.to_string exn })
        `Null;
      raise exn
  in
  (match result with
   | Ok judgment ->
     complete
       Exact_lane_run_registry.Succeeded
       (Keeper_board_attention_candidate.judgment_to_yojson judgment)
   | Error error ->
     let code = result |> terminal_outcome |> terminal_outcome_to_string in
     let detail =
       match error with
       | Providers_exhausted { detail; _ }
       | Flow_bookkeeping_failed { detail; _ } ->
         detail
       (* The one place the CLI failures become a sentence: the durable
          record needs a string, and until here they are the walker's own
          type, countable by kind. *)
       | Cli_slots_exhausted { prior_error; failures } ->
         let tail =
           String.concat
             "; "
             (List.map Keeper_lane_cli_oneshot.failure_to_string failures)
         in
         (match prior_error with
          | Some (Providers_exhausted { detail; _ }) -> detail ^ "; cli tail: " ^ tail
          | Some _ | None -> "cli tail: " ^ tail)
       | Flow_already_started _
       | Before_dispatch_persistence_failed _
       | Before_advance_persistence_failed _
       | Provenance_mismatch _
       | Domain_output_invalid _ -> code
     in
     complete
       (Exact_lane_run_registry.Failed { code; detail })
       (`Assoc [ "terminal_outcome", `String code ]));
  observe_terminal prepared ~jev_first result;
  result
;;

let execute ?cli_runner ~clock ~before_dispatch ~before_advance prepared =
  execute_current ?cli_runner ~clock ~before_dispatch ~before_advance prepared
;;
