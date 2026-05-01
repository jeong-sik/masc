(** JSON round-trip and helper tests for Chronicle_types.
    @since Project Chronicle Phase 1 *)

open Alcotest

module CT = Masc_mcp.Chronicle_types
module CI = Masc_mcp.Chronicle_index

(* --- Chronicle_types tests --- *)

let sample_causation () =
  [ { CT.trigger = "CI failure on main"
    ; CT.conclusion = "pin dune-project version"
    ; CT.rationale = "unpin caused drift across 9 PRs"
    }
  ]

let sample_epoch () =
  { CT.id = "2026-Q1-chronicle-types"
  ; CT.label = "Project Chronicle Types"
  ; CT.repo = "masc-mcp"
  ; CT.start_date = "2026-05-01"
  ; CT.end_date = "2026-05-01"
  ; CT.start_commit = "abc1234"
  ; CT.end_commit = "def5678"
  ; CT.goal_ids = [ "g-chronicle" ]
  ; CT.status = CT.Active
  ; CT.causation = sample_causation ()
  ; CT.outcomes_achieved = [ "type model defined"; "JSON serialization verified" ]
  ; CT.outcomes_failed = []
  ; CT.lessons =
    [ { CT.pattern = "compile-first verify"
      ; CT.context = "dune worktree detection"
      ; CT.outcome = CT.Positive
      }
    ]
  ; CT.key_files =
    [ { CT.path = "lib/chronicle_types.ml"; CT.role = "data model" }
    ; { CT.path = "lib/chronicle_index.ml"; CT.role = "index navigation" }
    ]
  ; CT.rfc_refs = []
  ; CT.historian_validated_at = None
  }

let test_epoch_id_deterministic () =
  let id1 = CT.epoch_id ~year:"2026" ~label:"Q1-types" in
  let id2 = CT.epoch_id ~year:"2026" ~label:"Q1-types" in
  check string "deterministic" id1 id2;
  check string "format" "2026-Q1-types" id1

let test_is_active () =
  let epoch = { (sample_epoch ()) with CT.status = CT.Active } in
  check bool "active" true (CT.is_active epoch);
  check bool "not completed" false (CT.is_completed epoch)

let test_is_completed () =
  let epoch = { (sample_epoch ()) with CT.status = CT.Completed } in
  check bool "completed" true (CT.is_completed epoch);
  check bool "not active" false (CT.is_active epoch)

let test_is_abandoned () =
  let epoch = { (sample_epoch ()) with CT.status = CT.Abandoned } in
  check bool "not active" false (CT.is_active epoch);
  check bool "not completed" false (CT.is_completed epoch)

let test_lesson_counts () =
  let epoch =
    { (sample_epoch ()) with
      CT.lessons =
        [ { CT.pattern = "a"; CT.context = "x"; CT.outcome = CT.Positive }
        ; { CT.pattern = "b"; CT.context = "y"; CT.outcome = CT.Positive }
        ; { CT.pattern = "c"; CT.context = "z"; CT.outcome = CT.Negative }
        ; { CT.pattern = "d"; CT.context = "w"; CT.outcome = CT.Mixed }
        ]
    }
  in
  let pos, neg, mix = CT.lesson_counts epoch in
  check int "positive" 2 pos;
  check int "negative" 1 neg;
  check int "mixed" 1 mix

let test_lesson_counts_empty () =
  let epoch = { (sample_epoch ()) with CT.lessons = [] } in
  let pos, neg, mix = CT.lesson_counts epoch in
  check int "positive" 0 pos;
  check int "negative" 0 neg;
  check int "mixed" 0 mix

let test_json_roundtrip_epoch () =
  let epoch = sample_epoch () in
  let json = CT.chronicle_epoch_to_yojson epoch in
  match CT.chronicle_epoch_of_yojson json with
  | Ok decoded ->
    check string "id roundtrip" epoch.CT.id decoded.CT.id;
    check string "label roundtrip" epoch.CT.label decoded.CT.label;
    check string "repo roundtrip" epoch.CT.repo decoded.CT.repo;
    check int "causation count" (List.length epoch.CT.causation)
      (List.length decoded.CT.causation);
    check int "lessons count" (List.length epoch.CT.lessons)
      (List.length decoded.CT.lessons);
    check int "key_files count" (List.length epoch.CT.key_files)
      (List.length decoded.CT.key_files)
  | Error msg ->
    failf "JSON parse error: %s" msg

let test_json_roundtrip_status () =
  let check_status label status =
    let json = CT.epoch_status_to_yojson status in
    match CT.epoch_status_of_yojson json with
    | Ok s ->
      check string label (CT.show_epoch_status status) (CT.show_epoch_status s)
    | Error msg -> failf "status %s parse error: %s" label msg
  in
  check_status "Active" CT.Active;
  check_status "Completed" CT.Completed;
  check_status "Abandoned" CT.Abandoned

let test_json_roundtrip_outcome_kind () =
  let check_outcome label outcome =
    let json = CT.outcome_kind_to_yojson outcome in
    match CT.outcome_kind_of_yojson json with
    | Ok o ->
      check string label (CT.show_outcome_kind outcome) (CT.show_outcome_kind o)
    | Error msg -> failf "outcome %s parse error: %s" label msg
  in
  check_outcome "Positive" CT.Positive;
  check_outcome "Negative" CT.Negative;
  check_outcome "Mixed" CT.Mixed

(* --- Chronicle_index tests --- *)

let sample_summary () =
  { CI.id = "2026-Q1-types"
  ; CI.label = "Types"
  ; CI.start_date = "2026-05-01"
  ; CI.end_date = "2026-05-01"
  ; CI.status = CT.Active
  ; CI.file_path = "docs/chronicle/epoch-2026-Q1-types.md"
  }

let test_empty_index () =
  let idx = CI.empty ~repo:"masc-mcp" ~now:"2026-05-01T00:00:00Z" in
  check int "schema_version" CI.current_schema_version idx.CI.schema_version;
  check string "repo" "masc-mcp" idx.CI.repo;
  check int "epochs empty" 0 (List.length idx.CI.epochs);
  check string "last_commit empty" "" idx.CI.last_commit_indexed

let test_find_epoch () =
  let idx = CI.empty ~repo:"masc-mcp" ~now:"2026-05-01T00:00:00Z" in
  let summary = sample_summary () in
  let idx = CI.add_or_replace_epoch idx summary in
  check int "has 1 epoch" 1 (List.length idx.CI.epochs);
  match CI.find_epoch idx "2026-Q1-types" with
  | Some s -> check string "found id" "2026-Q1-types" s.CI.id
  | None -> fail "epoch not found"

let test_find_epoch_missing () =
  let idx = CI.empty ~repo:"masc-mcp" ~now:"2026-05-01T00:00:00Z" in
  match CI.find_epoch idx "nonexistent" with
  | Some _ -> fail "should not find missing epoch"
  | None -> ()

let test_active_epochs () =
  let idx = CI.empty ~repo:"masc-mcp" ~now:"2026-05-01T00:00:00Z" in
  let active = sample_summary () in
  let completed =
    { (sample_summary ()) with
      CI.id = "2026-Q0-old"; CI.status = CT.Completed
    }
  in
  let idx = CI.add_or_replace_epoch idx active in
  let idx = CI.add_or_replace_epoch idx completed in
  let actives = CI.active_epochs idx in
  check int "1 active" 1 (List.length actives)

let test_add_or_replace_replaces () =
  let idx = CI.empty ~repo:"masc-mcp" ~now:"2026-05-01T00:00:00Z" in
  let s1 = sample_summary () in
  let idx = CI.add_or_replace_epoch idx s1 in
  let s2 = { s1 with CI.status = CT.Completed } in
  let idx = CI.add_or_replace_epoch idx s2 in
  check int "still 1 epoch" 1 (List.length idx.CI.epochs);
  match CI.find_epoch idx "2026-Q1-types" with
  | Some s -> check string "replaced status" (CT.show_epoch_status CT.Completed) (CT.show_epoch_status s.CI.status)
  | None -> fail "epoch missing after replace"

let test_json_roundtrip_index () =
  let idx = CI.empty ~repo:"masc-mcp" ~now:"2026-05-01T00:00:00Z" in
  let summary = sample_summary () in
  let idx = CI.add_or_replace_epoch idx summary in
  let json = CI.index_to_yojson idx in
  match CI.index_of_yojson json with
  | Ok decoded ->
    check int "schema roundtrip" idx.CI.schema_version decoded.CI.schema_version;
    check string "repo roundtrip" idx.CI.repo decoded.CI.repo;
    check int "epochs count" (List.length idx.CI.epochs) (List.length decoded.CI.epochs)
  | Error msg -> failf "index JSON parse error: %s" msg

let () =
  run "Chronicle_types" [
    ("epoch_id", [
      test_case "deterministic" `Quick test_epoch_id_deterministic;
    ]);
    ("status_queries", [
      test_case "is_active" `Quick test_is_active;
      test_case "is_completed" `Quick test_is_completed;
      test_case "is_abandoned" `Quick test_is_abandoned;
    ]);
    ("lesson_counts", [
      test_case "mixed outcomes" `Quick test_lesson_counts;
      test_case "empty" `Quick test_lesson_counts_empty;
    ]);
    ("json_roundtrip", [
      test_case "chronicle_epoch" `Quick test_json_roundtrip_epoch;
      test_case "epoch_status variants" `Quick test_json_roundtrip_status;
      test_case "outcome_kind variants" `Quick test_json_roundtrip_outcome_kind;
      test_case "index" `Quick test_json_roundtrip_index;
    ]);
    ("index_operations", [
      test_case "empty" `Quick test_empty_index;
      test_case "find_epoch" `Quick test_find_epoch;
      test_case "find_epoch missing" `Quick test_find_epoch_missing;
      test_case "active_epochs" `Quick test_active_epochs;
      test_case "add_or_replace replaces" `Quick test_add_or_replace_replaces;
    ]);
  ]
