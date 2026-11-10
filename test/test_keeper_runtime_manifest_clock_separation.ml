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

let clock_refs ?(source_clock = "wall") fields =
  `Assoc
    ([ ("clock_refs", `Assoc (fields @ [ ("source_clock", `String source_clock) ])) ]
    |> List.rev)

let source_clock_testable =
  let pp fmt sc = Format.fprintf fmt "%s" (M.source_clock_to_string sc) in
  let equal = ( = ) in
  Alcotest.testable pp equal

let test_source_clock_from_manifest () =
  let m =
    manifest ~event:M.Turn_started
      ~decision:(clock_refs ~source_clock:"monotonic" [ ("edge_id", `String "e1") ])
      ~links:(links ())
  in
  Alcotest.(check (option source_clock_testable))
    "extracts monotonic" (Some M.Monotonic) (M.source_clock_from_manifest m);
  let m2 =
    manifest ~event:M.Turn_started
      ~decision:(clock_refs ~source_clock:"monotonic" [ ("edge_id", `String "e1") ])
      ~links:(links ())
  in
  Alcotest.(check (option source_clock_testable))
    "extracts monotonic clock" (Some M.Monotonic) (M.source_clock_from_manifest m2)

let () =
  Alcotest.run "keeper_runtime_manifest_clock_separation"
    [ ( "clock_separation"
      , [ Alcotest.test_case "source_clock_from_manifest" `Quick
            test_source_clock_from_manifest
        ] )
    ]
