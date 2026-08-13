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

let fixture_case () =
  match
    create
      ~model_id:None
      ~role:(Exact_lane Librarian)
      ~capability:Librarian_run
      ~scenario:Restart_recovery
      ~protocol:Durable_store
      ~build_commit:None
      ()
  with
  | Ok case -> case
  | Error error -> failf "unexpected case error: %s" (create_error_to_string error)
;;

let test_case_json_round_trip_preserves_absence () =
  let original = fixture_case () in
  match case_of_json (case_to_json original) with
  | Error error -> failf "unexpected codec error: %s" (case_json_error_to_string error)
  | Ok decoded ->
    check
      string
      "identity round trips"
      (original |> case_id |> case_id_to_string)
      (decoded |> case_id |> case_id_to_string);
    check (option string) "model remains null" None (model_id decoded);
    check (option string) "build remains null" None (build_commit decoded)
;;

let add_field name value = function
  | `Assoc fields -> `Assoc ((name, value) :: fields)
  | _ -> fail "case_to_json must emit an object"
;;

let replace_field name replacement = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field, value) ->
           if String.equal field name then field, replacement else field, value)
         fields)
  | _ -> fail "case_to_json must emit an object"
;;

let remove_field name = function
  | `Assoc fields -> `Assoc (List.filter (fun (field, _) -> not (String.equal field name)) fields)
  | _ -> fail "case_to_json must emit an object"
;;

let test_case_json_rejects_unknown_duplicate_and_missing_fields () =
  let json = case_to_json (fixture_case ()) in
  let cases =
    [ Unknown_field "future", add_field "future" `Null json
    ; Duplicate_field "runtime_id", add_field "runtime_id" (`String "duplicate") json
    ; Missing_field "protocol", remove_field "protocol" json
    ]
  in
  List.iter
    (fun (expected, json) ->
      match case_of_json json with
      | Error error ->
        check
          string
          "strict structural error"
          (case_json_error_to_string expected)
          (case_json_error_to_string error)
      | Ok decoded ->
        failf "malformed JSON produced %s" (decoded |> case_id |> case_id_to_string))
    cases
;;

let test_case_json_rejects_unknown_variant () =
  match case_to_json (fixture_case ()) |> replace_field "role" (`String "keeper-ish") |> case_of_json with
  | Error (Unknown_variant ("role", "keeper-ish")) -> ()
  | Error error -> failf "unexpected codec error: %s" (case_json_error_to_string error)
  | Ok _ -> fail "unknown role was accepted"
;;

let test_case_json_rejects_wrong_nullability () =
  match case_to_json (fixture_case ()) |> replace_field "runtime_id" `Null |> case_of_json with
  | Error (Expected_string "runtime_id") -> ()
  | Error error -> failf "unexpected codec error: %s" (case_json_error_to_string error)
  | Ok _ -> fail "null runtime_id was accepted"
;;

let test_case_json_rejects_identity_mismatch () =
  match
    case_to_json (fixture_case ())
    |> replace_field "case_id" (`String "cpc_wrong")
    |> case_of_json
  with
  | Error (Case_id_mismatch { encoded = "cpc_wrong"; _ }) -> ()
  | Error error -> failf "unexpected codec error: %s" (case_json_error_to_string error)
  | Ok _ -> fail "mismatched case id was accepted"
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
    ; ( "case JSON"
      , [ test_case "round trip" `Quick test_case_json_round_trip_preserves_absence
        ; test_case "strict fields" `Quick test_case_json_rejects_unknown_duplicate_and_missing_fields
        ; test_case "closed variants" `Quick test_case_json_rejects_unknown_variant
        ; test_case "nullability" `Quick test_case_json_rejects_wrong_nullability
        ; test_case "identity" `Quick test_case_json_rejects_identity_mismatch
        ] )
    ]
;;
