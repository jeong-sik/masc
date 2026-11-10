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

(* Runtime attempt attribution (#28871): the driver's per-candidate walk
   records the attempted candidate as decision.runtime_id (with idx, and
   error_kind on failures) while the row's top-level runtime_id stays the
   lane id. The public projection must let those three keys through, or
   intra-lane failover becomes unreadable on every API consumer. *)
let test_runtime_attempt_attribution_public_projection () =
  let decision =
    `Assoc
      [ ("idx", `Int 1)
      ; ("routing_run_id", `String "routing-run")
      ; ("attempt_total_usage", `Null)
      ; ("attempt_usage_status", `String "unresolved")
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
  Alcotest.(check string) "routing identity survives API projection" "routing-run"
    (projected |> member "routing_run_id" |> to_string);
  Alcotest.(check string) "failure usage remains explicitly unresolved" "unresolved"
    (projected |> member "attempt_usage_status" |> to_string);
  Alcotest.(check bool) "unknown usage is not zero" true
    (projected |> member "attempt_total_usage" = `Null);
  Alcotest.(check string)
    "error_kind retained" "api" (projected |> member "error_kind" |> to_string);
  Alcotest.(check bool)
    "projection still redacts unknown keys"
    true
    (projected |> member "not_allowlisted_probe" = `Null)

let test_intake_source_public_projection () =
  let source =
    [ "stimulus_id", `String "schedule:occurrence-one"
    ; "source_kind", `String "schedule_due"
    ; "source_snapshot_ref", `String "snapshot-one"
    ; "admitted_revision", `String "17"
    ; "first_admitted_at", `Float 123.0
    ]
  in
  let decision =
    `Assoc
      [ "channel", `String "reactive"
      ; "intake_sources",
        `List [ `Assoc (source @ [ "payload", `String "private instruction"
                               ; "error", `String "private nested error" ]) ]
      ; "stimulus_id", `String "not a top-level source"
      ]
  in
  let projected =
    manifest ~event:M.Turn_started ~decision ~links:(links ())
    |> M.public_to_json
  in
  let open Yojson.Safe.Util in
  let projected_decision = projected |> member "decision" in
  Alcotest.(check string) "turn entry remains visible" "reactive"
    (projected_decision |> member "channel" |> to_string);
  Alcotest.(check string) "only exact source references survive"
    (Yojson.Safe.to_string (`List [ `Assoc source ]))
    (Yojson.Safe.to_string (projected_decision |> member "intake_sources"));
  Alcotest.(check bool) "source keys are scoped to the source list" true
    (projected_decision |> member "stimulus_id" = `Null)

let () =
  Alcotest.run "KeeperRuntimeManifestCompleteness"
    [ ( "defined but never registered until task-1768",
          [ Alcotest.test_case "mandatory clock refs" `Quick test_mandatory_clock_refs
          ; Alcotest.test_case "is finished turn" `Quick test_is_finished_turn
          ; Alcotest.test_case "runtime attempt attribution public projection" `Quick test_runtime_attempt_attribution_public_projection
          ; Alcotest.test_case "intake source public projection" `Quick test_intake_source_public_projection
          ] )
    ]
