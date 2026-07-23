module M = Masc.Keeper_runtime_manifest

let manifest ~event ~decision ~links =
  { M.schema_version = 1
  ; M.ts = "2026-05-22T00:00:00Z"
  ; M.keeper_name = "test-keeper"
  ; M.agent_name = None
  ; M.trace_id = "trace/test"
  ; M.generation = None
  ; M.keeper_turn_id = Some 1
  ; M.oas_turn_count = Some 1
  ; M.logical_seq = None
  ; M.event
  ; M.runtime_id = None
  ; M.status = "ok"
  ; M.decision
  ; M.links
  }

let links ?receipt_path ?checkpoint_path () =
  { M.receipt_path; M.checkpoint_path; M.tool_call_log_path = None }

let clock_refs fields = `Assoc ([ ("clock_refs", `Assoc fields) ] |> List.rev)

let test_mandatory_clock_refs () =
  let keys = M.mandatory_clock_refs_for_event M.Turn_started in
  Alcotest.(check (list string))
    "Turn_started mandatory keys" [ "edge_id"; "lane" ] keys;
  let keys2 =
    M.mandatory_clock_refs_for_event M.Provider_attempt_finished
  in
  Alcotest.(check (list string))
    "Provider_attempt_finished mandatory keys"
    [ "edge_id"; "lane"; "provider_attempt_id"; "elapsed_ms" ]
    keys2

let test_validate_completeness_pass () =
  let m =
    manifest ~event:M.Turn_started
      ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
      ~links:(links ())
  in
  Alcotest.(check (result unit string))
    "valid manifest passes" (Ok ()) (M.validate_manifest_completeness m)

let test_validate_completeness_fail_missing_key () =
  let m =
    manifest ~event:M.Provider_attempt_finished
      ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
      ~links:(links ())
  in
  match M.validate_manifest_completeness m with
  | Ok () -> Alcotest.fail "expected failure for missing provider_attempt_id"
  | Error msg ->
    Alcotest.(check string) "error mentions missing keys"
      "manifest for provider_attempt_finished missing mandatory clock_refs keys: [provider_attempt_id, elapsed_ms]"
      msg

let test_is_finished_turn () =
  let manifests =
    [ manifest ~event:M.Turn_started
        ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
        ~links:(links ())
    ; manifest ~event:M.Runtime_execution_built
        ~decision:(clock_refs [ ("edge_id", `String "e2"); ("lane", `String "L1") ])
        ~links:(links ())
    ; manifest ~event:M.Turn_finished
        ~decision:(clock_refs [ ("edge_id", `String "e3"); ("lane", `String "L1") ])
        ~links:(links ())
    ]
  in
  Alcotest.(check bool) "turn with Turn_finished is finished" true
    (M.is_finished_turn manifests);
  let pre_dispatch_ready =
    [ manifest ~event:M.Turn_started
        ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
        ~links:(links ())
    ; manifest ~event:M.Runtime_execution_built
        ~decision:(clock_refs [ ("edge_id", `String "e2"); ("lane", `String "L1") ])
        ~links:(links ())
    ]
  in
  Alcotest.(check bool)
    "runtime execution built is not a terminal turn" false
    (M.is_finished_turn pre_dispatch_ready)

let test_is_complete_turn () =
  let finished_only =
    [ manifest ~event:M.Turn_finished
        ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
        ~links:(links ())
    ]
  in
  Alcotest.(check bool)
    "finished without receipt+checkpoint is not complete" false
    (M.is_complete_turn finished_only);
  let with_receipt =
    [ manifest ~event:M.Turn_finished
        ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
        ~links:(links ~receipt_path:"/tmp/r.jsonl" ())
    ; manifest ~event:M.Receipt_appended
        ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
        ~links:(links ~receipt_path:"/tmp/r.jsonl" ())
    ]
  in
  Alcotest.(check bool)
    "finished+receipt without checkpoint is not complete" false
    (M.is_complete_turn with_receipt);
  let complete =
    [ manifest ~event:M.Turn_finished
        ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
        ~links:(links ~receipt_path:"/tmp/r.jsonl" ~checkpoint_path:"/tmp/c.jsonl" ())
    ; manifest ~event:M.Receipt_appended
        ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
        ~links:(links ~receipt_path:"/tmp/r.jsonl" ~checkpoint_path:"/tmp/c.jsonl" ())
    ; manifest ~event:M.Checkpoint_saved
        ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1"); ("checkpoint_id", `String "c1") ])
        ~links:(links ~receipt_path:"/tmp/r.jsonl" ~checkpoint_path:"/tmp/c.jsonl" ())
    ]
  in
  Alcotest.(check bool) "finished+receipt+checkpoint is complete" true
    (M.is_complete_turn complete)

let test_compaction_evidence_public_projection () =
  let evidence =
    Keeper_compaction_evidence.create
      ~slot_id:"compaction-slot"
      ~call_id:"call-01"
      ~target_identity_fingerprint:"target-identity"
      ~catalog_generation_fingerprint:"catalog-generation"
      ~catalog_evidence_sha256:"catalog-evidence"
      ~plan_fingerprint:"plan-fingerprint"
      ~receipt_plan_fingerprint:"plan-fingerprint"
      ~receipt_request_body_sha256:"request-body"
      ~before_checkpoint_bytes:4096
      ~after_checkpoint_bytes:1024
      ~before_message_count:12
      ~after_message_count:4
      ~summarized_message_count:4
      ~dropped_message_count:8
      ~before_tool_use_count:3
      ~after_tool_use_count:3
      ~before_tool_result_count:3
      ~after_tool_result_count:3
    |> Result.get_ok
    |> Keeper_compaction_evidence.to_json
  in
  let decision =
    let evidence_with_cross_scope_field =
      match evidence with
      | `Assoc fields -> `Assoc (("error", `String "must-not-leak") :: fields)
      | _ -> Alcotest.fail "canonical compaction evidence must be an object"
    in
    M.with_payload_role
      ~payload_role:M.Checkpoint
      (`Assoc
        [ "exact_evidence", evidence_with_cross_scope_field ])
  in
  let json =
    manifest ~event:M.Context_compacted ~decision ~links:(links ())
    |> M.public_to_json
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "checkpoint role retained"
    "checkpoint"
    (json |> member "decision" |> member "payload_role" |> to_string);
  Alcotest.(check int)
    "exact before bytes retained"
    4096
    (json
     |> member "decision"
     |> member "exact_evidence"
     |> member "before_checkpoint_bytes"
     |> to_int);
  Alcotest.check
    (Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal)
    "all canonical evidence fields retained"
    evidence
    (json |> member "decision" |> member "exact_evidence")

let () =
  Alcotest.run "keeper_runtime_manifest_completeness"
    [ ( "completeness"
      , [ Alcotest.test_case "mandatory_clock_refs_for_event" `Quick
            test_mandatory_clock_refs
        ; Alcotest.test_case "validate_completeness_pass" `Quick
            test_validate_completeness_pass
        ; Alcotest.test_case "validate_completeness_fail_missing_key" `Quick
            test_validate_completeness_fail_missing_key
        ; Alcotest.test_case "is_finished_turn" `Quick test_is_finished_turn
        ; Alcotest.test_case "is_complete_turn" `Quick
            test_is_complete_turn
        ; Alcotest.test_case "compaction evidence public projection" `Quick
            test_compaction_evidence_public_projection
        ] )
    ]
