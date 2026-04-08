(** Coverage tests for Anti_rationalization module.

    Tests local pattern matching (no LLM calls in unit tests).
    LLM unavailability defaults to Approve (liveness > correctness). *)

open Masc_mcp

let () = Printf.printf "\n=== Anti_rationalization Coverage Tests ===\n"

let test name f =
  try
    f ();
    Printf.printf "  pass %s\n" name
  with e ->
    Printf.printf "  FAIL %s: %s\n" name (Printexc.to_string e);
    exit 1

(** Helpers accept review_result and extract .verdict for matching. *)
let assert_reject (r : Anti_rationalization.review_result) =
  match r.verdict with
  | Anti_rationalization.Reject _ -> ()
  | Anti_rationalization.Approve ->
    failwith "expected Reject but got Approve"

let assert_approve (r : Anti_rationalization.review_result) =
  match r.verdict with
  | Anti_rationalization.Approve -> ()
  | Anti_rationalization.Reject reason ->
    failwith (Printf.sprintf "expected Approve but got Reject: %s" reason)

let assert_reject_contains (r : Anti_rationalization.review_result) substring =
  match r.verdict with
  | Anti_rationalization.Reject reason ->
    let lower_reason = String.lowercase_ascii reason in
    let lower_sub = String.lowercase_ascii substring in
    if not (let len_r = String.length lower_reason in
            let len_s = String.length lower_sub in
            if len_s > len_r then false
            else
              let rec scan i =
                if i > len_r - len_s then false
                else if String.sub lower_reason i len_s = lower_sub then true
                else scan (i + 1)
              in scan 0)
    then
      failwith (Printf.sprintf "Reject reason '%s' does not contain '%s'" reason substring)
  | Anti_rationalization.Approve ->
    failwith (Printf.sprintf "expected Reject containing '%s' but got Approve" substring)

let make_request ?(title="Fix login bug") ?(desc="Users cannot login") ?(agent="test-agent") notes =
  { Anti_rationalization.
    task_title = title;
    task_description = desc;
    completion_notes = notes;
    agent_name = agent;
  }

(* ================================================================ *)
(* Gate 1: Empty / short notes                                      *)
(* ================================================================ *)

let () = test "empty_notes_rejected" (fun () ->
  assert_reject (Anti_rationalization.review (make_request "")))

let () = test "whitespace_only_rejected" (fun () ->
  assert_reject (Anti_rationalization.review (make_request "   ")))

let () = test "too_short_rejected" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "done"))
    "too short")

let () = test "minimum_length_boundary" (fun () ->
  (* 10 chars is the minimum *)
  assert_reject_contains
    (Anti_rationalization.review (make_request "123456789"))
    "too short")

(* ================================================================ *)
(* Gate 2: Excuse pattern detection                                  *)
(* ================================================================ *)

let () = test "pre_existing_pattern" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "This was a pre-existing issue that I found"))
    "pre-existing")

let () = test "out_of_scope_pattern" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "After investigation, this is out of scope for the current sprint"))
    "out of scope")

let () = test "will_do_later_pattern" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "Partially completed. Will do later the remaining items"))
    "will do later")

let () = test "will_fix_later_pattern" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "Found the issue but will fix later when we have time"))
    "will fix later")

let () = test "follow_up_pattern" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "Created a follow-up ticket for the remaining work"))
    "follow-up")

let () = test "works_on_my_end_pattern" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "Tested locally and works on my end without issues"))
    "works on my end")

let () = test "not_reproducible_pattern" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "Investigated but the bug is not reproducible in staging"))
    "not reproducible")

let () = test "beyond_scope_pattern" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "This change is beyond the scope of the current task"))
    "beyond the scope")

let () = test "case_insensitive_pattern" (fun () ->
  assert_reject_contains
    (Anti_rationalization.review (make_request "This was a PRE-EXISTING issue in the codebase"))
    "pre-existing")

(* ================================================================ *)
(* Gate 3: LLM review (unavailable in tests -> Approve by default)  *)
(* ================================================================ *)

let () = test "normal_notes_approve_when_llm_unavailable" (fun () ->
  (* In test env, LLM is unavailable. Gate 1+2 pass, Gate 3 defaults to Approve *)
  assert_approve
    (Anti_rationalization.review
       (make_request "Fixed the login bug by updating the OAuth callback URL in the auth service. Added unit test to verify the fix.")))

let () = test "substantive_notes_no_pattern_match" (fun () ->
  assert_approve
    (Anti_rationalization.review
       (make_request "Implemented the search feature with pagination support. 15 new tests added, all passing.")))

(* ================================================================ *)
(* review_result structured fields (#3067)                           *)
(* ================================================================ *)

let () = test "review_result_gate_field_length" (fun () ->
  let r = Anti_rationalization.review (make_request "") in
  assert (r.gate = Anti_rationalization.Length))

let () = test "review_result_gate_field_excuse" (fun () ->
  let r = Anti_rationalization.review (make_request "This is out of scope entirely") in
  assert (r.gate = Anti_rationalization.Excuse))

let () = test "review_result_evaluator_cascade_default" (fun () ->
  let r = Anti_rationalization.review (make_request "") in
  assert (r.evaluator_cascade = "cross_verifier"))

let () = test "review_result_custom_evaluator_cascade" (fun () ->
  let r = Anti_rationalization.review ~evaluator_cascade:"cross_verifier" (make_request "") in
  assert (r.evaluator_cascade = "cross_verifier"))

(* ================================================================ *)
(* Gate 2.5: Completion contract (#3071)                             *)
(* ================================================================ *)

let () = test "contract_all_met" (fun () ->
  let r = Anti_rationalization.review
    ~completion_contract:["test"; "fix"]
    (make_request "Applied fix to the login flow and added test coverage.") in
  (* Contract met — should proceed to Gate 3 (LLM unavailable → approve) *)
  assert_approve r)

let () = test "contract_unmet_rejects" (fun () ->
  let r = Anti_rationalization.review
    ~completion_contract:["test coverage"; "migration"]
    (make_request "Applied fix to the login flow.") in
  assert (r.gate = Anti_rationalization.Contract);
  assert_reject r)

let () = test "contract_unmet_lists_items" (fun () ->
  let r = Anti_rationalization.review
    ~completion_contract:["test"; "migration"; "rollback"]
    (make_request "Applied fix and added test to verify.") in
  match r.verdict with
  | Anti_rationalization.Reject reason ->
    (* "migration" and "rollback" should be unmet *)
    let has sub =
      let slen = String.length sub in
      let rlen = String.length reason in
      if slen > rlen then false
      else let rec s i = if i > rlen - slen then false
        else if String.sub reason i slen = sub then true else s (i+1) in s 0
    in
    assert (has "migration");
    assert (has "rollback")
  | Anti_rationalization.Approve ->
    failwith "expected Reject for unmet contract")

let () = test "contract_empty_no_effect" (fun () ->
  let r = Anti_rationalization.review
    ~completion_contract:[]
    (make_request "Applied fix to the login flow and added test coverage.") in
  assert_approve r)

let () = test "contract_none_no_effect" (fun () ->
  let r = Anti_rationalization.review
    (make_request "Applied fix to the login flow and added test coverage.") in
  assert_approve r)

let () = test "check_contract_direct" (fun () ->
  let unmet = Anti_rationalization.check_contract
    ~notes:"Fixed auth bug, added unit test, ran migration"
    ~contract:["test"; "migration"; "deployment"] in
  assert (List.length unmet = 1);
  assert (List.hd unmet = "deployment"))

(* ================================================================ *)
(* parse_verdict (directly tested)                                  *)
(* ================================================================ *)

let () = test "parse_verdict_approve" (fun () ->
  match Anti_rationalization.parse_verdict "APPROVE" with
  | Ok Anti_rationalization.Approve -> ()
  | Ok _ -> failwith "expected Approve"
  | Error e -> failwith (Printf.sprintf "unexpected error: %s" e))

let () = test "parse_verdict_approve_with_trailing" (fun () ->
  match Anti_rationalization.parse_verdict "APPROVE - looks good" with
  | Ok Anti_rationalization.Approve -> ()
  | Ok _ -> failwith "expected Approve"
  | Error e -> failwith (Printf.sprintf "unexpected error: %s" e))

let () = test "parse_verdict_reject_with_reason" (fun () ->
  match Anti_rationalization.parse_verdict "REJECT: vague notes" with
  | Ok (Anti_rationalization.Reject reason) ->
    assert (String.equal (String.lowercase_ascii reason) "vague notes")
  | Ok _ -> failwith "expected Reject"
  | Error e -> failwith (Printf.sprintf "unexpected error: %s" e))

let () = test "parse_verdict_reject_bare" (fun () ->
  match Anti_rationalization.parse_verdict "REJECT" with
  | Ok (Anti_rationalization.Reject _) -> ()
  | Ok _ -> failwith "expected Reject"
  | Error e -> failwith (Printf.sprintf "unexpected error: %s" e))

let () = test "parse_verdict_reject_colon_only" (fun () ->
  match Anti_rationalization.parse_verdict "REJECT:" with
  | Ok (Anti_rationalization.Reject _) -> ()
  | Ok _ -> failwith "expected Reject"
  | Error e -> failwith (Printf.sprintf "unexpected error: %s" e))

(* ADR D3: unrecognized format now returns Error, NOT Approve *)
let () = test "parse_verdict_unrecognized_returns_error" (fun () ->
  match Anti_rationalization.parse_verdict "I think it looks good" with
  | Error _ -> ()
  | Ok _ -> failwith "expected Error for unrecognized format (ADR D3)")

let () = test "parse_verdict_approved_word_returns_error" (fun () ->
  match Anti_rationalization.parse_verdict "APPROVED" with
  | Error _ -> ()
  | Ok _ -> failwith "expected Error for APPROVED without boundary")

let () = test "parse_verdict_rejected_word_returns_error" (fun () ->
  match Anti_rationalization.parse_verdict "REJECTED" with
  | Error _ -> ()
  | Ok _ -> failwith "expected Error for REJECTED without boundary")

let () = test "parse_verdict_empty_returns_error" (fun () ->
  match Anti_rationalization.parse_verdict "" with
  | Error _ -> ()
  | Ok _ -> failwith "expected Error for empty input (ADR D3)")

(* ================================================================ *)
(* find_excuse_pattern                                               *)
(* ================================================================ *)

let () = test "find_excuse_pattern_none_for_clean_notes" (fun () ->
  match Anti_rationalization.find_excuse_pattern "Fixed the auth bug and added tests" with
  | None -> ()
  | Some (pat, _) -> failwith (Printf.sprintf "unexpected pattern: %s" pat))

let () = test "find_excuse_pattern_some_for_excuse" (fun () ->
  match Anti_rationalization.find_excuse_pattern "this is out of scope for now" with
  | Some ("out of scope", _) -> ()
  | Some (pat, _) -> failwith (Printf.sprintf "wrong pattern: %s" pat)
  | None -> failwith "expected Some but got None")

let () = Printf.printf "=== Anti_rationalization: all tests passed ===\n"
