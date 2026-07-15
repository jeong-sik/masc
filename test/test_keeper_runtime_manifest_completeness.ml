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

let with_temp_dir f =
  let path = Filename.temp_file "runtime-manifest-once-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir path
      |> Array.iter (fun name -> Sys.remove (Filename.concat path name));
      Unix.rmdir path)
    (fun () -> f path)
;;

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
  let decision =
    M.with_payload_role
      ~payload_role:M.Checkpoint
      (`Assoc
        [ ( "exact_evidence"
          , `Assoc
              [ "before_checkpoint_bytes", `Int 4096
              ; "after_checkpoint_bytes", `Int 1024
              ] )
        ])
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
     |> to_int)

let compaction_manifest ~trace_id ~operation_id =
  { (manifest
       ~event:M.Context_compacted
       ~decision:(`Assoc [ "operation_id", `String operation_id ])
       ~links:(links ())) with
    trace_id
  }
;;

let test_append_once_across_trace_files () =
  with_temp_dir @@ fun dir ->
  let operation_id = "compaction-operation-1" in
  let first_path = Filename.concat dir "trace-a.jsonl" in
  let second_path = Filename.concat dir "trace-b.jsonl" in
  let first = compaction_manifest ~trace_id:"trace-a" ~operation_id in
  let replay = compaction_manifest ~trace_id:"trace-b" ~operation_id in
  Alcotest.(check bool)
    "first projection appended"
    true
    (M.append_once_to_path ~operation_id first_path first = Ok M.Appended);
  Alcotest.(check bool)
    "restart trace reuses existing projection"
    true
    (M.append_once_to_path ~operation_id second_path replay = Ok M.Already_present);
  Alcotest.(check int)
    "one manifest row"
    1
    (Fs_compat.load_file first_path
     |> String.split_on_char '\n'
     |> List.filter (fun line -> String.trim line <> "")
     |> List.length);
  Alcotest.(check bool) "second trace was not written" false
    (Fs_compat.file_exists second_path)
;;

let test_append_once_rejects_corrupt_manifest () =
  with_temp_dir @@ fun dir ->
  let corrupt_path = Filename.concat dir "corrupt.jsonl" in
  Fs_compat.save_file corrupt_path "{not-json}\n";
  let operation_id = "compaction-operation-2" in
  let target_path = Filename.concat dir "target.jsonl" in
  let row = compaction_manifest ~trace_id:"target" ~operation_id in
  match M.append_once_to_path ~operation_id target_path row with
  | Ok _ -> Alcotest.fail "corrupt durable row must not be skipped"
  | Error detail ->
    Alcotest.(check bool)
      "error identifies corrupt manifest"
      true
      (String.length detail > 0);
    Alcotest.(check bool) "target was not written" false
      (Fs_compat.file_exists target_path)
;;

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
        ; Alcotest.test_case "append once across trace files" `Quick
            test_append_once_across_trace_files
        ; Alcotest.test_case "append once rejects corrupt manifest" `Quick
            test_append_once_rejects_corrupt_manifest
        ] )
    ]
