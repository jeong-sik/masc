module M = Masc_mcp.Keeper_runtime_manifest

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
  ; M.cascade_name = None
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
      ~decision:(clock_refs ~source_clock:"provider" [ ("edge_id", `String "e1") ])
      ~links:(links ())
  in
  Alcotest.(check (option source_clock_testable))
    "extracts provider" (Some M.Provider) (M.source_clock_from_manifest m2)

let test_logical_ordering () =
  let m =
    manifest ~event:M.Turn_started
      ~decision:
        (clock_refs
           [ ("edge_id", `String "e1")
           ; ("parent_event_id", `String "p1")
           ; ("caused_by", `String "c1")
           ; ("logical_seq", `Int 7)
           ])
      ~links:(links ())
  in
  let lo = M.logical_ordering m in
  Alcotest.(check (option string)) "parent_event_id" (Some "p1") lo.parent_event_id;
  Alcotest.(check (option string)) "caused_by" (Some "c1") lo.caused_by;
  Alcotest.(check (option int)) "logical_seq" (Some 7) lo.logical_seq

let test_comparable_for_latency_same_clock () =
  let a =
    manifest ~event:M.Provider_attempt_started
      ~decision:(clock_refs ~source_clock:"provider" [ ("edge_id", `String "e1") ])
      ~links:(links ())
  in
  let b =
    manifest ~event:M.Provider_attempt_finished
      ~decision:(clock_refs ~source_clock:"provider" [ ("edge_id", `String "e2") ])
      ~links:(links ())
  in
  Alcotest.(check (result source_clock_testable string))
    "same provider clock is comparable" (Ok M.Provider)
    (M.comparable_for_latency a b)

let test_comparable_for_latency_different_clock () =
  let a =
    manifest ~event:M.Turn_started
      ~decision:(clock_refs ~source_clock:"wall" [ ("edge_id", `String "e1") ])
      ~links:(links ())
  in
  let b =
    manifest ~event:M.Provider_attempt_started
      ~decision:(clock_refs ~source_clock:"provider" [ ("edge_id", `String "e2") ])
      ~links:(links ())
  in
  match M.comparable_for_latency a b with
  | Ok _ -> Alcotest.fail "expected failure for different source_clock"
  | Error msg ->
    Alcotest.(check bool) "error mentions mismatch" true
      (String.equal msg "latency comparison invalid: source_clock mismatch (wall vs provider)")

let () =
  Alcotest.run "keeper_runtime_manifest_clock_separation"
    [ ( "clock_separation"
      , [ Alcotest.test_case "source_clock_from_manifest" `Quick
            test_source_clock_from_manifest
        ; Alcotest.test_case "logical_ordering" `Quick test_logical_ordering
        ; Alcotest.test_case "comparable_for_latency_same" `Quick
            test_comparable_for_latency_same_clock
        ; Alcotest.test_case "comparable_for_latency_different" `Quick
            test_comparable_for_latency_different_clock
        ] )
    ]
