(** test_golden_set.ml — Validate golden set structural requirements. *)

open Masc_mcp

(* --- Size requirements (RFC Labeling Protocol Section 4) --- *)

let test_positive_count () =
  let count = List.length Golden_set.positive_cases in
  Alcotest.(check bool) "positive >= 20" true (count >= 20);
  Printf.printf "  positive cases: %d\n%!" count

let test_negative_count () =
  let count = List.length Golden_set.negative_cases in
  Alcotest.(check bool) "negative >= 20" true (count >= 20);
  Printf.printf "  negative cases: %d\n%!" count

let test_edge_count () =
  let count = List.length Golden_set.edge_cases in
  Alcotest.(check bool) "edge >= 5" true (count >= 5);
  Printf.printf "  edge cases: %d\n%!" count

let test_drift_count () =
  let count = List.length Golden_set.drift_probes in
  Alcotest.(check bool) "drift >= 5" true (count >= 5);
  Printf.printf "  drift probes: %d\n%!" count

let test_total_count () =
  let total = List.length Golden_set.all_cases in
  let expected =
    List.length Golden_set.positive_cases
    + List.length Golden_set.negative_cases
    + List.length Golden_set.edge_cases
    + List.length Golden_set.drift_probes
  in
  Alcotest.(check int) "total = sum of parts" expected total;
  Printf.printf "  total cases: %d\n%!" total

(* --- Uniqueness --- *)

let test_unique_ids () =
  let ids = List.map (fun (c : Golden_set.golden_case) -> c.case_id) Golden_set.all_cases in
  let unique_ids = List.sort_uniq String.compare ids in
  Alcotest.(check int) "all ids unique"
    (List.length ids) (List.length unique_ids)

(* --- Verdict consistency --- *)

let test_positive_verdicts () =
  List.iter
    (fun (c : Golden_set.golden_case) ->
      Alcotest.(check string)
        (Printf.sprintf "%s should pass" c.case_id) "pass" c.expected_verdict)
    Golden_set.positive_cases

let test_negative_verdicts () =
  List.iter
    (fun (c : Golden_set.golden_case) ->
      Alcotest.(check string)
        (Printf.sprintf "%s should fail" c.case_id) "fail" c.expected_verdict)
    Golden_set.negative_cases

let test_edge_verdicts () =
  List.iter
    (fun (c : Golden_set.golden_case) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s should be ambiguous" c.case_id)
        true (String.equal c.expected_verdict "ambiguous"))
    Golden_set.edge_cases

(* --- Tags non-empty --- *)

let test_all_have_tags () =
  List.iter
    (fun (c : Golden_set.golden_case) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s has tags" c.case_id)
        true (List.length c.tags > 0))
    Golden_set.all_cases

(* --- Baseline lock consistency --- *)

let test_baseline_lock () =
  let lock = Golden_set.current_lock in
  Alcotest.(check int) "lock case_count" (List.length Golden_set.all_cases) lock.case_count;
  Alcotest.(check int) "lock positive" (List.length Golden_set.positive_cases) lock.positive_count;
  Alcotest.(check int) "lock negative" (List.length Golden_set.negative_cases) lock.negative_count;
  Alcotest.(check int) "lock edge" (List.length Golden_set.edge_cases) lock.edge_count;
  Alcotest.(check int) "lock drift" (List.length Golden_set.drift_probes) lock.drift_count

(* --- JSON serialization roundtrip --- *)

let test_case_to_yojson () =
  let case = List.hd Golden_set.positive_cases in
  let json = Golden_set.case_to_yojson case in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "case_id"
    case.case_id (json |> member "case_id" |> to_string);
  Alcotest.(check string) "verdict"
    case.expected_verdict (json |> member "expected_verdict" |> to_string)

let test_lock_to_yojson () =
  let json = Golden_set.lock_to_yojson Golden_set.current_lock in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "version"
    "1.0.0" (json |> member "golden_set_version" |> to_string);
  Alcotest.(check int) "count"
    Golden_set.current_lock.case_count (json |> member "case_count" |> to_int)

(* --- Test suite --- *)

let () =
  Alcotest.run "golden_set"
    [
      ( "size_requirements",
        [
          Alcotest.test_case "positive >= 20" `Quick test_positive_count;
          Alcotest.test_case "negative >= 20" `Quick test_negative_count;
          Alcotest.test_case "edge >= 5" `Quick test_edge_count;
          Alcotest.test_case "drift >= 5" `Quick test_drift_count;
          Alcotest.test_case "total consistency" `Quick test_total_count;
        ] );
      ( "integrity",
        [
          Alcotest.test_case "unique ids" `Quick test_unique_ids;
          Alcotest.test_case "positive verdicts" `Quick test_positive_verdicts;
          Alcotest.test_case "negative verdicts" `Quick test_negative_verdicts;
          Alcotest.test_case "edge verdicts" `Quick test_edge_verdicts;
          Alcotest.test_case "all have tags" `Quick test_all_have_tags;
        ] );
      ( "baseline_lock",
        [
          Alcotest.test_case "lock matches data" `Quick test_baseline_lock;
        ] );
      ( "serialization",
        [
          Alcotest.test_case "case to json" `Quick test_case_to_yojson;
          Alcotest.test_case "lock to json" `Quick test_lock_to_yojson;
        ] );
    ]
