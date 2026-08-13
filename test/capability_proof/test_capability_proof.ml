open Alcotest
open Capability_proof

let create
      ?(runtime_id = "ollama_cloud.deepseek-v4-flash")
      ?(model_id = Some "deepseek-v4-flash")
      ?(role = Autonomous_keeper)
      ?(capability = Autonomous_turn)
      ?(scenario = Nominal)
      ?(protocol = Agent_core_http)
      ?(build_commit = Some "6959248d23")
      ?(config_revision = Some "sha256:runtime-config")
      ()
  =
  Capability_proof.create
    ~runtime_id
    ~model_id
    ~role
    ~capability
    ~scenario
    ~protocol
    ~build_commit
    ~config_revision
;;

let id result =
  match result with
  | Ok case -> case |> case_id |> case_id_to_string
  | Error error -> failf "unexpected create error: %s" (create_error_to_string error)
;;

let test_identity_is_deterministic () =
  check string "same inputs have one identity" (id (create ())) (id (create ()))
;;

let test_absence_is_not_fabricated () =
  match create ~model_id:None ~build_commit:None ~config_revision:None () with
  | Error error -> failf "unexpected create error: %s" (create_error_to_string error)
  | Ok case ->
    check (option string) "model remains absent" None (model_id case);
    check (option string) "build remains absent" None (build_commit case);
    check (option string) "config revision remains absent" None (config_revision case)
;;

let test_present_and_absent_values_have_distinct_identity () =
  check bool "model absence changes identity" true (id (create ~model_id:None ()) <> id (create ()))
;;

let test_blank_values_are_rejected () =
  let cases =
    [ Blank_field Runtime_id, create ~runtime_id:" \t" ()
    ; Blank_field Model_id, create ~model_id:(Some "") ()
    ; Blank_field Build_commit, create ~build_commit:(Some " ") ()
    ; Blank_field Config_revision, create ~config_revision:(Some "\n") ()
    ]
  in
  List.iter
    (fun (expected, actual) ->
      match actual with
      | Error error ->
        check string "typed blank field" (create_error_to_string expected) (create_error_to_string error)
      | Ok case -> failf "blank field produced %s" (case |> case_id |> case_id_to_string))
    cases
;;

let test_closed_inventory_has_unique_case_ids () =
  let seen = Hashtbl.create 32768 in
  let collisions = ref [] in
  List.iter
    (fun role ->
      List.iter
        (fun capability ->
          List.iter
            (fun scenario ->
              List.iter
                (fun protocol ->
                  let case_id = id (create ~role ~capability ~scenario ~protocol ()) in
                  if Hashtbl.mem seen case_id then collisions := case_id :: !collisions;
                  Hashtbl.add seen case_id ())
                all_protocols)
            all_scenarios)
        all_capability_cases)
    all_proof_roles;
  check (list string) "no matrix identity collisions" [] (List.rev !collisions)
;;

let evidence ?(path = Hermetic) ?(kind = Journal) locator =
  create_evidence_ref
    ~path
    ~kind
    ~locator
    ~sha256:(String.make 64 'a')
    ~captured_at:"2026-08-13T09:00:00Z"
  |> function
  | Ok evidence -> evidence
  | Error error -> failf "unexpected evidence error: %s" (evidence_error_to_string error)
;;

let three_path_evidence () =
  [ evidence ~path:Hermetic "fixture:capability-proof"
  ; evidence ~path:Isolated ~kind:Receipt "receipt:isolated-run"
  ; evidence ~path:Fleet ~kind:Api "api:/health?full=1"
  ]
;;

let test_pass_requires_all_three_proof_paths () =
  match passed [ evidence ~path:Hermetic "fixture:only" ] with
  | Error (Invalid_evidence_bundle (Missing_proof_paths [ Isolated; Fleet ])) -> ()
  | Error error -> failf "unexpected pass error: %s" (result_error_to_string error)
  | Ok result -> failf "incomplete evidence passed as %s" (proof_result_to_string result)
;;

let test_pass_accepts_complete_bundle () =
  match passed (three_path_evidence ()) with
  | Error error -> failf "unexpected pass error: %s" (result_error_to_string error)
  | Ok (Passed bundle) -> check int "all evidence retained" 3 (List.length (evidence_bundle_refs bundle))
  | Ok result -> failf "expected passed, got %s" (proof_result_to_string result)
;;

let test_duplicate_evidence_is_rejected () =
  let duplicate = evidence ~path:Hermetic "fixture:duplicate" in
  match passed (duplicate :: duplicate :: three_path_evidence ()) with
  | Error (Invalid_evidence_bundle (Duplicate_evidence_ref "fixture:duplicate")) -> ()
  | Error error -> failf "unexpected duplicate error: %s" (result_error_to_string error)
  | Ok result -> failf "duplicate evidence passed as %s" (proof_result_to_string result)
;;

let test_invalid_digest_is_typed () =
  match
    create_evidence_ref
      ~path:Hermetic
      ~kind:Journal
      ~locator:"fixture:bad-digest"
      ~sha256:"not-a-sha256"
      ~captured_at:"2026-08-13T09:00:00Z"
  with
  | Error Invalid_sha256 -> ()
  | Error error -> failf "unexpected evidence error: %s" (evidence_error_to_string error)
  | Ok _ -> fail "invalid digest was accepted"
;;

let test_failed_requires_evidence () =
  match failed Provider_failure [] with
  | Error Failure_without_evidence -> ()
  | Error error -> failf "unexpected failure error: %s" (result_error_to_string error)
  | Ok result -> failf "evidence-free failure accepted as %s" (proof_result_to_string result)
;;

let test_unsupported_policy_is_not_a_failure () =
  let result = unsupported (Capability_not_declared Autonomous_turn) in
  check
    string
    "policy exclusion stays typed"
    "unsupported:capability_not_declared:autonomous_turn"
    (proof_result_to_string result)
;;

let test_blank_blocker_is_rejected () =
  match blocked " \t" with
  | Error Blank_blocker_ref -> ()
  | Error error -> failf "unexpected blocker error: %s" (result_error_to_string error)
  | Ok result -> failf "blank blocker accepted as %s" (proof_result_to_string result)
;;

let case ?(model_id = Some "model") runtime_id =
  match create ~runtime_id ~model_id () with
  | Ok case -> case
  | Error error -> failf "unexpected case error: %s" (create_error_to_string error)
;;

let pass () =
  match passed (three_path_evidence ()) with
  | Ok result -> result
  | Error error -> failf "unexpected pass error: %s" (result_error_to_string error)
;;

let block locator =
  match blocked locator with
  | Ok result -> result
  | Error error -> failf "unexpected blocker error: %s" (result_error_to_string error)
;;

let test_campaign_metric_counts_every_unresolved_state () =
  let cases = List.map case [ "passed"; "failed"; "unsupported"; "not-run"; "blocked"; "missing" ] in
  let case_id_at index = List.nth cases index |> case_id in
  let results =
    [ case_id_at 0, pass ()
    ; case_id_at 1, Result.get_ok (failed Provider_failure [ evidence "receipt:failure" ])
    ; case_id_at 2, unsupported (Protocol_not_supported Browser)
    ; case_id_at 3, not_run
    ; case_id_at 4, block "blocker:credential"
    ]
  in
  match summarize_campaign ~expected:cases ~results with
  | Error error -> failf "unexpected campaign error: %s" (campaign_error_to_string error)
  | Ok summary ->
    check int "expected" 6 summary.expected;
    check int "passed" 1 summary.passed;
    check int "failed" 1 summary.failed;
    check int "unsupported" 1 summary.unsupported;
    check int "not run" 1 summary.not_run;
    check int "blocked" 1 summary.blocked;
    check int "missing" 1 summary.missing_evidence;
    check int "strict unresolved metric" 4 summary.unresolved_required_cells;
    check bool "campaign incomplete" false (campaign_complete summary)
;;

let test_campaign_complete_accepts_passed_and_typed_unsupported () =
  let passed_case = case "passed" in
  let unsupported_case = case "unsupported" in
  let results =
    [ case_id passed_case, pass ()
    ; ( case_id unsupported_case
      , unsupported (Capability_not_declared Autonomous_turn) )
    ]
  in
  match summarize_campaign ~expected:[ passed_case; unsupported_case ] ~results with
  | Error error -> failf "unexpected campaign error: %s" (campaign_error_to_string error)
  | Ok summary ->
    check int "unresolved zero" 0 summary.unresolved_required_cells;
    check bool "campaign complete" true (campaign_complete summary)
;;

let test_campaign_rejects_duplicate_expected_identity () =
  let duplicate = case "same" in
  match summarize_campaign ~expected:[ duplicate; duplicate ] ~results:[] with
  | Error (Duplicate_expected_case _) -> ()
  | Error error -> failf "unexpected campaign error: %s" (campaign_error_to_string error)
  | Ok _ -> fail "duplicate expected identity was accepted"
;;

let test_campaign_rejects_duplicate_result_identity () =
  let expected = case "same" in
  let id = case_id expected in
  match summarize_campaign ~expected:[ expected ] ~results:[ id, not_run; id, not_run ] with
  | Error (Duplicate_result_case _) -> ()
  | Error error -> failf "unexpected campaign error: %s" (campaign_error_to_string error)
  | Ok _ -> fail "duplicate result identity was accepted"
;;

let test_campaign_rejects_unexpected_result_identity () =
  let expected = case "expected" in
  let unexpected = case "unexpected" in
  match summarize_campaign ~expected:[ expected ] ~results:[ case_id unexpected, not_run ] with
  | Error (Unexpected_result_case _) -> ()
  | Error error -> failf "unexpected campaign error: %s" (campaign_error_to_string error)
  | Ok _ -> fail "unexpected result identity was accepted"
;;

let () =
  run
    "capability proof identity"
    [ ( "identity"
      , [ test_case "deterministic" `Quick test_identity_is_deterministic
        ; test_case "absence preserved" `Quick test_absence_is_not_fabricated
        ; test_case "absence is distinct" `Quick test_present_and_absent_values_have_distinct_identity
        ; test_case "blank rejected" `Quick test_blank_values_are_rejected
        ; test_case "closed inventory unique" `Quick test_closed_inventory_has_unique_case_ids
        ] )
    ; ( "verdict"
      , [ test_case "pass requires A/B/C" `Quick test_pass_requires_all_three_proof_paths
        ; test_case "complete pass" `Quick test_pass_accepts_complete_bundle
        ; test_case "duplicate evidence" `Quick test_duplicate_evidence_is_rejected
        ; test_case "invalid digest" `Quick test_invalid_digest_is_typed
        ; test_case "failure needs evidence" `Quick test_failed_requires_evidence
        ; test_case "unsupported is typed" `Quick test_unsupported_policy_is_not_a_failure
        ; test_case "blocker nonblank" `Quick test_blank_blocker_is_rejected
        ] )
    ; ( "campaign metric"
      , [ test_case "all unresolved states" `Quick test_campaign_metric_counts_every_unresolved_state
        ; test_case "complete" `Quick test_campaign_complete_accepts_passed_and_typed_unsupported
        ; test_case "duplicate expected" `Quick test_campaign_rejects_duplicate_expected_identity
        ; test_case "duplicate result" `Quick test_campaign_rejects_duplicate_result_identity
        ; test_case "unexpected result" `Quick test_campaign_rejects_unexpected_result_identity
        ] )
    ]
;;
