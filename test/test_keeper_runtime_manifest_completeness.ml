module M = Masc.Keeper_runtime_manifest

let manifest ~event ~decision ~links =
  { M.schema_version = 1
  ; M.ts = "2026-05-22T00:00:00Z"
  ; M.keeper_name = "test-keeper"
  ; M.trace_id = "trace/test"
  ; M.keeper_turn_id = Some 1
  ; M.agent_core_turn_count = Some 1
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
  let keys2 = M.mandatory_clock_refs_for_event M.Checkpoint_saved in
  Alcotest.(check (list string))
    "Checkpoint_saved mandatory keys"
    [ "edge_id"; "lane"; "checkpoint_id" ]
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
    manifest ~event:M.Checkpoint_saved
      ~decision:(clock_refs [ ("edge_id", `String "e1"); ("lane", `String "L1") ])
      ~links:(links ())
  in
  match M.validate_manifest_completeness m with
  | Ok () -> Alcotest.fail "expected failure for missing checkpoint_id"
  | Error msg ->
    Alcotest.(check string) "error mentions missing keys"
      "manifest for checkpoint_saved missing mandatory clock_refs keys: [checkpoint_id]"
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

(* Runtime attempt attribution (#28871): the driver's per-candidate walk
   records the attempted candidate as decision.runtime_id (with idx, and
   error_kind on failures) while the row's top-level runtime_id stays the
   lane id. The public projection must let those three keys through, or
   intra-lane failover becomes unreadable on every API consumer. *)
let test_runtime_attempt_attribution_public_projection () =
  let decision =
    `Assoc
      [ ("idx", `Int 1)
      ; ("runtime_id", `String "glm-coding.glm-5-turbo")
      ; ("error_kind", `String "api")
      ; ("not_allowlisted_probe", `String "must-not-leak")
      ; ( "clock_refs"
        , `Assoc [ ("edge_id", `String "e1"); ("lane", `String "L1") ] )
      ]
  in
  let json =
    manifest ~event:M.Runtime_failed ~decision ~links:(links ())
    |> M.public_to_json
  in
  let open Yojson.Safe.Util in
  let projected = json |> member "decision" in
  Alcotest.(check int)
    "idx retained" 1 (projected |> member "idx" |> to_int);
  Alcotest.(check string)
    "attempted candidate retained"
    "glm-coding.glm-5-turbo"
    (projected |> member "runtime_id" |> to_string);
  Alcotest.(check string)
    "error_kind retained" "api" (projected |> member "error_kind" |> to_string);
  Alcotest.(check bool)
    "projection still redacts unknown keys"
    true
    (projected |> member "not_allowlisted_probe" = `Null)
