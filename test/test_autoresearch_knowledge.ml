(** E2E roundtrip test for Autoresearch_knowledge: record + search. *)

open Alcotest
open Masc_mcp

let test_record_and_search () =
  let f : Autoresearch_knowledge.finding = {
    id = Autoresearch_knowledge.generate_finding_id ();
    loop_id = "test-loop-e2e";
    keeper_name = "test-researcher";
    goal = "Understand attention window effect on BPB";
    hypothesis = "Full attention (L) produces lower BPB than sliding window (SSSL)";
    evidence = "MPS baseline L pattern: val_bpb=1.698";
    conclusion = "Window pattern effect needs same-hardware comparison.";
    confidence = Autoresearch_knowledge.Medium;
    tags = ["attention"; "window-pattern"; "e2e-test"];
    related_findings = [];
    cycle_range = Some (1, 87);
    timestamp = Unix.gettimeofday ();
  } in
  let result = Autoresearch_knowledge.record_finding ~finding:f in
  let ok = Yojson.Safe.Util.(member "ok" result |> to_bool_option)
           |> Option.value ~default:false in
  check bool "record ok" true ok;
  let found = Autoresearch_knowledge.search_findings ~query:"attention" () in
  check bool "found at least 1" true (List.length found >= 1);
  let has_ours = List.exists (fun (r : Autoresearch_knowledge.finding) ->
    r.id = f.id) found in
  check bool "found our finding" true has_ours

let test_search_no_match () =
  let found = Autoresearch_knowledge.search_findings
    ~query:"xyzzy_nonexistent_42" () in
  check int "no results" 0 (List.length found)

let test_finding_serde_roundtrip () =
  let f : Autoresearch_knowledge.finding = {
    id = "fn-test-serde";
    loop_id = "loop-42";
    keeper_name = "serde-tester";
    goal = "Test serialization";
    hypothesis = "JSON roundtrip preserves all fields";
    evidence = "Encode then decode";
    conclusion = "All fields match";
    confidence = Autoresearch_knowledge.High;
    tags = ["serde"; "test"];
    related_findings = ["fn-other"];
    cycle_range = Some (10, 20);
    timestamp = 1234567890.0;
  } in
  let json = Autoresearch_knowledge.finding_to_yojson f in
  match Autoresearch_knowledge.finding_of_yojson json with
  | Error e -> fail ("deserialize failed: " ^ e)
  | Ok f2 ->
    check string "id" f.id f2.id;
    check string "goal" f.goal f2.goal;
    check string "confidence" "high"
      (Autoresearch_knowledge.confidence_to_string f2.confidence);
    check int "tags count" 2 (List.length f2.tags)

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "Autoresearch_knowledge" [
    "record_search", [
      test_case "record and search roundtrip" `Quick test_record_and_search;
      test_case "search no match" `Quick test_search_no_match;
    ];
    "serialization", [
      test_case "finding JSON roundtrip" `Quick test_finding_serde_roundtrip;
    ];
  ]
