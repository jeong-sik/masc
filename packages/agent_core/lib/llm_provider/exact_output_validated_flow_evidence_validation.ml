open Exact_output_validated_flow_evidence_types
module Json = Exact_output_validated_flow_evidence_canonical_json
module Check = Exact_output_validated_flow_evidence_validation_primitives

let ( let* ) = Result.bind

let normalize ~(declared_candidates : candidate list) ~(steps : step list) =
  let declared_candidates = Array.of_list declared_candidates in
  let steps = Array.of_list steps in
  let declared_count = Array.length declared_candidates in
  let step_count = Array.length steps in
  let* () = if declared_count = 0 then Error Empty_declared_candidates else Ok () in
  let* () = if step_count = 0 then Error Empty_steps else Ok () in
  let* () =
    if step_count > declared_count
    then Error More_steps_than_declared_candidates
    else Ok ()
  in
  let candidate_ids = Hashtbl.create declared_count in
  let rec validate_declared position =
    if position = declared_count
    then Ok ()
    else (
      let candidate = declared_candidates.(position) in
      let* () = Check.check_candidate candidate in
      match Hashtbl.find_opt candidate_ids candidate.candidate_id with
      | Some first_position ->
        Error
          (Duplicate_candidate_id
             { candidate_id = candidate.candidate_id
             ; first_position
             ; duplicate_position = position + 1
             })
      | None ->
        Hashtbl.add candidate_ids candidate.candidate_id (position + 1);
        validate_declared (position + 1))
  in
  let* () = validate_declared 0 in
  let call_ids = Hashtbl.create step_count in
  let measurement_ids = Hashtbl.create step_count in
  let rec validate_steps index normalized_rev =
    if index = step_count
    then Ok (List.rev normalized_rev)
    else (
      let step = steps.(index) in
      let ordinal = index + 1 in
      let is_final = index = step_count - 1 in
      let* () =
        if step.ordinal = ordinal
        then Ok ()
        else
          Error
            (Non_contiguous_step_ordinal { expected = ordinal; actual = step.ordinal })
      in
      let candidate = declared_candidates.(index) in
      let* normalized_admission =
        match step.admission with
        | Rejected rejected ->
          let* rejection =
            Json.projector ~ordinal ~location:"admission.rejection" rejected.rejection
          in
          let* () =
            if Check.rejected_measurement_state_is_valid rejected.measurement
            then Ok ()
            else Error (Invalid_measurement_state { ordinal })
          in
          Ok (Normalized_rejected { rejection; measurement = rejected.measurement })
        | Admitted admitted ->
          let* () =
            Check.check_sha256 ~ordinal "admission.plan_sha256" admitted.plan_sha256
          in
          let* () =
            Check.check_sha256
              ~ordinal
              "admission.request_body_sha256"
              admitted.request_body_sha256
          in
          let* () = Check.check_provenance ~ordinal candidate admitted.provenance in
          let* () =
            if Check.admitted_measurement_state_is_valid admitted.measurement
            then Ok ()
            else Error (Invalid_measurement_state { ordinal })
          in
          Ok (Normalized_admitted admitted)
      in
      let* normalized_outcome =
        match step.outcome with
        | Advance advance -> Ok (Normalized_advance advance)
        | Semantic_rejected { projector = value; output_sha256 } ->
          let* projector =
            Json.projector ~ordinal ~location:"outcome.semantic_rejected" value
          in
          let* () = Check.check_sha256 ~ordinal "outcome.output_sha256" output_sha256 in
          Ok (Normalized_semantic_rejected { projector; output_sha256 })
        | Accepted { projector = value; output_sha256 } ->
          let* projector = Json.projector ~ordinal ~location:"outcome.accepted" value in
          let* () = Check.check_sha256 ~ordinal "outcome.output_sha256" output_sha256 in
          Ok (Normalized_accepted { projector; output_sha256 })
      in
      let* () =
        match normalized_outcome with
        | Normalized_advance advance ->
          if advance.next_ordinal = ordinal + 1 && not is_final
          then Ok ()
          else
            Error (Non_adjacent_advance { ordinal; next_ordinal = advance.next_ordinal })
        | Normalized_accepted _ when not is_final ->
          Error (Nonfinal_step_accepted { ordinal })
        | Normalized_accepted _ -> Ok ()
        | Normalized_semantic_rejected _ when is_final ->
          Error (Final_step_not_accepted { ordinal })
        | Normalized_semantic_rejected _ -> Ok ()
      in
      let ( admission_measurement
          , request_body_sha256
          , receipt_required
          , receipt_state_is_valid )
        =
        match normalized_admission with
        | Normalized_admitted admitted ->
          ( admitted.measurement
          , Some admitted.request_body_sha256
          , admitted.measurement.outcome <> Measurement_not_required
          , Check.measurement_state_is_valid )
        | Normalized_rejected rejected ->
          ( rejected.measurement
          , None
          , false
          , Check.rejected_measurement_receipt_state_is_valid )
      in
      let* () =
        match admission_measurement.outcome, step.measurement with
        | Measurement_not_required, None -> Ok ()
        | Measurement_not_required, Some _ ->
          Error (Invalid_measurement_state { ordinal })
        | _, None ->
          if not receipt_required
          then Ok ()
          else Error (Measurement_binding_mismatch { ordinal })
        | _, Some measurement ->
          if
            admission_measurement.dispatch <> measurement.dispatch
            || admission_measurement.outcome <> measurement.outcome
          then Error (Measurement_binding_mismatch { ordinal })
          else
            Check.check_measurement
              ~ordinal
              ~candidate
              ~request_body_sha256
              ~measurement_ids
              ~state_is_valid:receipt_state_is_valid
              measurement
      in
      let* () =
        match normalized_admission, step.attempt, normalized_outcome with
        | Normalized_rejected _, Some _, _ ->
          Error (Rejected_admission_has_attempt { ordinal })
        | ( Normalized_rejected _
          , None
          , Normalized_advance { failure = Candidate_rejected; _ } ) -> Ok ()
        | Normalized_rejected _, None, _ ->
          Error (Rejected_admission_did_not_advance { ordinal })
        | Normalized_admitted _, None, _ ->
          Error (Admitted_candidate_missing_attempt { ordinal })
        | ( Normalized_admitted admitted
          , Some attempt
          , Normalized_advance { failure = Candidate_rejected; _ } ) ->
          let _ = admitted, attempt in
          Error (Advance_failure_mismatch { ordinal })
        | Normalized_admitted admitted, Some attempt, outcome ->
          Check.check_attempt ~ordinal ~candidate ~admitted ~call_ids ~outcome attempt
      in
      let normalized =
        { ordinal
        ; admission = normalized_admission
        ; measurement = step.measurement
        ; attempt = step.attempt
        ; outcome = normalized_outcome
        }
      in
      validate_steps (index + 1) (normalized :: normalized_rev))
  in
  let* normalized_steps = validate_steps 0 [] in
  let normalized_steps = Array.of_list normalized_steps in
  let* accepted_sha256 =
    match normalized_steps.(step_count - 1).outcome with
    | Normalized_accepted { projector; _ } -> Ok projector.digest
    | Normalized_advance _ | Normalized_semantic_rejected _ ->
      Error (Final_step_not_accepted { ordinal = step_count })
  in
  Ok (declared_candidates, normalized_steps, accepted_sha256)
;;
