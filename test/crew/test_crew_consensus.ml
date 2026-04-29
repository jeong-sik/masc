(* Tier A10a — Crew_consensus tally + outcome evaluation. *)

module C = Crew.Crew_consensus
module T = Crew.Crew_types

let check_int label expected actual =
  if expected <> actual then
    failwith
      (Printf.sprintf "%s: expected %d, got %d" label expected actual)

let check_str label expected actual =
  if not (String.equal expected actual) then
    failwith
      (Printf.sprintf "%s: expected %S, got %S" label expected actual)

let check_bool label b =
  if not b then failwith (Printf.sprintf "%s: false" label)

let assoc_string key json =
  match json with
  | `Assoc kv -> (
      match List.assoc_opt key kv with
      | Some (`String s) -> s
      | _ ->
          failwith
            (Printf.sprintf "expected string field %S in %s" key
               (Yojson.Safe.to_string json)))
  | _ -> failwith "expected JSON object"

let assoc_int key json =
  match json with
  | `Assoc kv -> (
      match List.assoc_opt key kv with
      | Some (`Int n) -> n
      | _ ->
          failwith
            (Printf.sprintf "expected int field %S in %s" key
               (Yojson.Safe.to_string json)))
  | _ -> failwith "expected JSON object"

(* ── Tally ──────────────────────────────────────────────────────── *)

let test_empty_tally () =
  let t = C.empty_tally in
  check_int "empty.approve" 0 t.approve;
  check_int "empty.dissent" 0 t.dissent;
  check_int "empty.abstain" 0 t.abstain;
  check_int "empty.total" 0 (C.tally_total t)

let test_tally_of_votes_mixed () =
  let votes =
    [ T.Approve; T.Dissent "policy unclear"; T.Abstain; T.Approve ]
  in
  let t = C.tally_of_votes votes in
  check_int "approve count" 2 t.approve;
  check_int "dissent count" 1 t.dissent;
  check_int "abstain count" 1 t.abstain;
  check_int "total" 4 (C.tally_total t)

let test_tally_of_empty_list () =
  let t = C.tally_of_votes [] in
  check_int "empty list approve" 0 t.approve;
  check_int "empty list total" 0 (C.tally_total t)

(* ── Evaluation: deadlock branches ──────────────────────────────── *)

let test_evaluate_below_quorum () =
  let policy = { C.min_voters = 3; approve_threshold = 0.5 } in
  let outcome = C.evaluate ~policy [ T.Approve; T.Approve ] in
  let tag = C.any_outcome_to_tag outcome in
  check_bool "below_quorum → Stalemate_tag"
    (tag = C.Stalemate_tag);
  let json = C.any_outcome_to_json outcome in
  check_str "stalemate deadlock_kind" "below_quorum"
    (assoc_string "deadlock_kind" json)

let test_evaluate_all_abstain () =
  let outcome =
    C.evaluate ~policy:C.default_policy [ T.Abstain; T.Abstain ]
  in
  let tag = C.any_outcome_to_tag outcome in
  check_bool "all_abstain → Stalemate_tag"
    (tag = C.Stalemate_tag);
  let json = C.any_outcome_to_json outcome in
  check_str "all_abstain deadlock_kind" "all_abstain"
    (assoc_string "deadlock_kind" json)

let test_evaluate_tied () =
  let outcome =
    C.evaluate ~policy:C.default_policy
      [ T.Approve; T.Dissent "no" ]
  in
  let tag = C.any_outcome_to_tag outcome in
  check_bool "tied → Stalemate_tag" (tag = C.Stalemate_tag);
  let json = C.any_outcome_to_json outcome in
  check_str "tied deadlock_kind" "tied"
    (assoc_string "deadlock_kind" json)

(* ── Evaluation: positive verdicts ──────────────────────────────── *)

let test_evaluate_approved_majority () =
  let outcome =
    C.evaluate ~policy:C.default_policy
      [ T.Approve; T.Approve; T.Dissent "edge case" ]
  in
  let tag = C.any_outcome_to_tag outcome in
  check_bool "majority approve → Approved_tag"
    (tag = C.Approved_tag);
  let json = C.any_outcome_to_json outcome in
  check_str "approved kind" "approved" (assoc_string "kind" json);
  check_int "approved tally.approve" 2
    (assoc_int "approve"
       (match json with
       | `Assoc kv -> List.assoc "tally" kv
       | _ -> failwith "no tally"))

let test_evaluate_unanimous_single () =
  let outcome =
    C.evaluate ~policy:C.default_policy [ T.Approve ]
  in
  check_bool "single approve → Approved_tag"
    (C.any_outcome_to_tag outcome = C.Approved_tag)

let test_evaluate_rejected_minority () =
  let outcome =
    C.evaluate ~policy:C.default_policy
      [ T.Approve; T.Dissent "x"; T.Dissent "y" ]
  in
  let tag = C.any_outcome_to_tag outcome in
  check_bool "minority approve → Rejected_tag"
    (tag = C.Rejected_tag);
  let json = C.any_outcome_to_json outcome in
  check_str "rejected kind" "rejected" (assoc_string "kind" json);
  match json with
  | `Assoc kv -> (
      match List.assoc_opt "dissent_reasons" kv with
      | Some (`List reasons) ->
          check_int "rejected dissent_reasons length" 2
            (List.length reasons)
      | _ -> failwith "missing dissent_reasons")
  | _ -> failwith "expected object"

(* ── Custom policy thresholds ───────────────────────────────────── *)

let test_evaluate_threshold_boundary () =
  let policy = { C.min_voters = 1; approve_threshold = 0.66 } in
  (* 2 approve / 3 active = 66.67% — passes 0.66 *)
  let pass =
    C.evaluate ~policy
      [ T.Approve; T.Approve; T.Dissent "x" ]
  in
  check_bool "0.6667 ≥ 0.66 → Approved"
    (C.any_outcome_to_tag pass = C.Approved_tag);
  (* 2 approve / 3 active = 66.67% — fails 0.67 *)
  let policy_strict =
    { C.min_voters = 1; approve_threshold = 0.67 }
  in
  let fail =
    C.evaluate ~policy:policy_strict
      [ T.Approve; T.Approve; T.Dissent "x" ]
  in
  check_bool "0.6667 < 0.67 → Rejected"
    (C.any_outcome_to_tag fail = C.Rejected_tag)

(* ── Tag enumerations ───────────────────────────────────────────── *)

let test_all_outcome_tags () =
  check_int "outcome_tag count" 3 (List.length C.all_outcome_tags);
  check_bool "Approved_tag in list"
    (List.mem C.Approved_tag C.all_outcome_tags);
  check_bool "Rejected_tag in list"
    (List.mem C.Rejected_tag C.all_outcome_tags);
  check_bool "Stalemate_tag in list"
    (List.mem C.Stalemate_tag C.all_outcome_tags)

let test_all_deadlock_kinds () =
  check_int "deadlock_kind count" 3
    (List.length C.all_deadlock_kinds);
  check_bool "Tied in list" (List.mem C.Tied C.all_deadlock_kinds);
  check_bool "Below_quorum in list"
    (List.mem C.Below_quorum C.all_deadlock_kinds);
  check_bool "All_abstain in list"
    (List.mem C.All_abstain C.all_deadlock_kinds)

(* ── outcome_to_tag exhaustiveness ──────────────────────────────── *)

let test_outcome_to_tag_projection () =
  let approved : C.approved C.outcome =
    C.Approved C.empty_tally
  in
  check_bool "Approved → Approved_tag"
    (C.outcome_to_tag approved = C.Approved_tag);
  let rejected : C.rejected C.outcome =
    C.Rejected { tally = C.empty_tally; reasons = [] }
  in
  check_bool "Rejected → Rejected_tag"
    (C.outcome_to_tag rejected = C.Rejected_tag);
  let stalemate : C.stalemate C.outcome =
    C.Stalemate { tally = C.empty_tally; kind = C.Tied }
  in
  check_bool "Stalemate → Stalemate_tag"
    (C.outcome_to_tag stalemate = C.Stalemate_tag)

(* ── JSON ───────────────────────────────────────────────────────── *)

let test_tally_json_roundtrip () =
  let t = { C.approve = 5; dissent = 2; abstain = 1 } in
  let json = C.tally_to_json t in
  check_int "json approve" 5 (assoc_int "approve" json);
  check_int "json dissent" 2 (assoc_int "dissent" json);
  check_int "json abstain" 1 (assoc_int "abstain" json)

let test_default_policy_values () =
  let p = C.default_policy in
  check_int "default min_voters" 1 p.min_voters;
  check_bool "default approve_threshold = 0.5"
    (Float.equal p.approve_threshold 0.5)

(* ── Driver ─────────────────────────────────────────────────────── *)

let () =
  let cases =
    [
      ("empty_tally", test_empty_tally);
      ("tally_of_votes_mixed", test_tally_of_votes_mixed);
      ("tally_of_empty_list", test_tally_of_empty_list);
      ("evaluate_below_quorum", test_evaluate_below_quorum);
      ("evaluate_all_abstain", test_evaluate_all_abstain);
      ("evaluate_tied", test_evaluate_tied);
      ("evaluate_approved_majority", test_evaluate_approved_majority);
      ("evaluate_unanimous_single", test_evaluate_unanimous_single);
      ("evaluate_rejected_minority", test_evaluate_rejected_minority);
      ("evaluate_threshold_boundary", test_evaluate_threshold_boundary);
      ("all_outcome_tags", test_all_outcome_tags);
      ("all_deadlock_kinds", test_all_deadlock_kinds);
      ("outcome_to_tag_projection", test_outcome_to_tag_projection);
      ("tally_json_roundtrip", test_tally_json_roundtrip);
      ("default_policy_values", test_default_policy_values);
    ]
  in
  List.iter
    (fun (name, f) ->
      try f ()
      with e ->
        Printf.printf "FAIL %s: %s\n" name (Printexc.to_string e);
        exit 1)
    cases;
  Printf.printf "test_crew_consensus: %d cases OK\n"
    (List.length cases)
