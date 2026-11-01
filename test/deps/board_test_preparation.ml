type action = Bootstrap | Adopt

let prepare ~base_path ~action =
  let module I = Masc_board_handlers.Board_initialization in
  let inspection = I.inspect ~base_path in
  I.finish_inspection inspection;
  let expected_decision = match action with
    | Bootstrap -> I.Bootstrap_required
    | Adopt -> I.Adoption_required
  in
  if I.decision inspection <> expected_decision then
    Alcotest.failf "explicit Board preparation has a different decision: %s"
      (Yojson.Safe.to_string (I.inspection_to_yojson inspection));
  let expected_intent_sha256 = match I.intent_sha256 inspection with
    | Some intent -> intent
    | None -> Alcotest.fail "actionable Board inspection has no intent"
  in
  let outcome = match action with
    | Bootstrap -> I.bootstrap_offline ~base_path ~expected_intent_sha256
    | Adopt -> I.adopt_offline ~base_path ~expected_intent_sha256
  in
  match I.finish_outcome outcome with
  | I.Completed -> ()
  | I.Not_completed ->
    Alcotest.failf "explicit Board preparation did not complete: %s"
      (Yojson.Safe.to_string (I.outcome_to_yojson outcome))
