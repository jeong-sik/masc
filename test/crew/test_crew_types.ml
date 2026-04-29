(* Cycle 25 / Tier A8 — Crew_types tests. *)

module C = Crew.Crew_types

(* ─── persona_kind ────────────────────────────────────────────── *)

let test_all_persona_kinds () =
  assert (List.length C.all_persona_kinds = 4);
  assert (C.all_persona_kinds = [ C.Analyst; C.Executor; C.Scholar; C.Verifier ])

let test_persona_kind_to_string () =
  assert (C.persona_kind_to_string C.Analyst = "analyst");
  assert (C.persona_kind_to_string C.Executor = "executor");
  assert (C.persona_kind_to_string C.Scholar = "scholar");
  assert (C.persona_kind_to_string C.Verifier = "verifier")

let test_persona_kind_of_string_opt_known () =
  assert (C.persona_kind_of_string_opt "analyst" = Some C.Analyst);
  assert (C.persona_kind_of_string_opt "Executor" = Some C.Executor);
  assert (C.persona_kind_of_string_opt "SCHOLAR" = Some C.Scholar)

let test_persona_kind_of_string_opt_unknown () =
  assert (C.persona_kind_of_string_opt "wizard" = None);
  assert (C.persona_kind_of_string_opt "" = None)

let test_persona_kind_json_round_trip () =
  List.iter
    (fun k ->
      let json = C.persona_kind_to_json k in
      match C.persona_kind_of_json json with
      | Ok back -> assert (back = k)
      | Error _ -> assert false)
    C.all_persona_kinds

let test_persona_kind_of_json_rejects_non_string () =
  match C.persona_kind_of_json (`Int 42) with
  | Error _ -> ()
  | Ok _ -> assert false

(* ─── vote ────────────────────────────────────────────────────── *)

let test_vote_label () =
  assert (C.vote_label C.Approve = "approve");
  assert (C.vote_label (C.Dissent "blocked on X") = "dissent");
  assert (C.vote_label C.Abstain = "abstain")

let test_vote_round_trip_approve () =
  match C.vote_of_json (C.vote_to_json C.Approve) with
  | Ok C.Approve -> ()
  | _ -> assert false

let test_vote_round_trip_dissent_with_reason () =
  let v = C.Dissent "tool surface unsafe" in
  match C.vote_of_json (C.vote_to_json v) with
  | Ok (C.Dissent r) -> assert (r = "tool surface unsafe")
  | _ -> assert false

let test_vote_round_trip_abstain () =
  match C.vote_of_json (C.vote_to_json C.Abstain) with
  | Ok C.Abstain -> ()
  | _ -> assert false

let test_vote_dissent_missing_reason_rejected () =
  let bogus = `Assoc [ ("kind", `String "dissent") ] in
  match C.vote_of_json bogus with
  | Error _ -> ()
  | Ok _ -> assert false

(* ─── council_id ──────────────────────────────────────────────── *)

let test_council_id_valid () =
  match C.council_id_of_string "council-001" with
  | Ok id ->
      assert (C.council_id_to_string id = "council-001");
      assert (C.council_id_to_json id = `String "council-001")
  | Error _ -> assert false

let test_council_id_empty_rejected () =
  match C.council_id_of_string "" with
  | Error _ -> ()
  | Ok _ -> assert false

let test_council_id_too_long_rejected () =
  let long_s = String.make 65 'a' in
  match C.council_id_of_string long_s with
  | Error _ -> ()
  | Ok _ -> assert false

let test_council_id_at_max_length () =
  let s = String.make 64 'b' in
  match C.council_id_of_string s with
  | Ok _ -> ()
  | Error _ -> assert false

let test_council_id_json_round_trip () =
  let id = Result.get_ok (C.council_id_of_string "council-roundtrip") in
  match C.council_id_of_json (C.council_id_to_json id) with
  | Ok back -> assert (C.council_id_equal back id)
  | Error _ -> assert false

let test_council_id_compare () =
  let a = Result.get_ok (C.council_id_of_string "abc") in
  let b = Result.get_ok (C.council_id_of_string "abd") in
  assert (C.council_id_compare a b < 0);
  assert (C.council_id_compare a a = 0)

let () =
  test_all_persona_kinds ();
  test_persona_kind_to_string ();
  test_persona_kind_of_string_opt_known ();
  test_persona_kind_of_string_opt_unknown ();
  test_persona_kind_json_round_trip ();
  test_persona_kind_of_json_rejects_non_string ();
  test_vote_label ();
  test_vote_round_trip_approve ();
  test_vote_round_trip_dissent_with_reason ();
  test_vote_round_trip_abstain ();
  test_vote_dissent_missing_reason_rejected ();
  test_council_id_valid ();
  test_council_id_empty_rejected ();
  test_council_id_too_long_rejected ();
  test_council_id_at_max_length ();
  test_council_id_json_round_trip ();
  test_council_id_compare ();
  print_endline "test_crew_types: all assertions passed"
