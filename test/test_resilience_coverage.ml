(** Resilience Module Coverage Tests

    Tests for MASC Resilience:
    - default_warning_threshold: constant
    - Time.now: current time
    - Time.parse_iso8601_opt: ISO timestamp parsing
*)

open Alcotest


(* ============================================================
   Constants Tests
   ============================================================ *)

let test_default_warning_threshold_positive () =
  check bool "positive" true (Workspace_resilience.default_warning_threshold > 0.0)

(* ============================================================
   Time.now Tests
   ============================================================ *)

let test_time_now_positive () =
  let t = Workspace_resilience.Time.now () in
  check bool "positive" true (t > 0.0)

let test_time_now_reasonable () =
  (* Should be after year 2024 (timestamp > 1704067200) *)
  let t = Workspace_resilience.Time.now () in
  check bool "after 2024" true (t > 1704067200.0)

let test_time_now_not_future () =
  (* Should not be in year 2100+ (timestamp < 4102444800) *)
  let t = Workspace_resilience.Time.now () in
  check bool "not future" true (t < 4102444800.0)

(* ============================================================
   Time.parse_iso8601_opt Tests
   ============================================================ *)

let test_parse_iso8601_valid () =
  match Workspace_resilience.Time.parse_iso8601_opt "2024-01-15T10:30:00Z" with
  | Some _ -> ()
  | None -> fail "expected Some"

let test_parse_iso8601_invalid () =
  match Workspace_resilience.Time.parse_iso8601_opt "not a timestamp" with
  | None -> ()
  | Some _ -> fail "expected None"

let test_parse_iso8601_empty () =
  match Workspace_resilience.Time.parse_iso8601_opt "" with
  | None -> ()
  | Some _ -> fail "expected None"

let test_parse_iso8601_partial () =
  match Workspace_resilience.Time.parse_iso8601_opt "2024-01-15" with
  | None -> ()
  | Some _ -> fail "expected None"

let test_parse_iso8601_no_z () =
  match Workspace_resilience.Time.parse_iso8601_opt "2024-01-15T10:30:00" with
  | None -> ()
  | Some _ -> fail "expected None"

let test_parse_iso8601_midnight () =
  match Workspace_resilience.Time.parse_iso8601_opt "2024-01-01T00:00:00Z" with
  | Some _ -> ()
  | None -> fail "expected Some"

let test_parse_iso8601_end_of_day () =
  match Workspace_resilience.Time.parse_iso8601_opt "2024-12-31T23:59:59Z" with
  | Some _ -> ()
  | None -> fail "expected Some"

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Resilience Coverage" [
    "constants", [
      test_case "warning threshold positive" `Quick test_default_warning_threshold_positive;
    ];
    "time_now", [
      test_case "positive" `Quick test_time_now_positive;
      test_case "reasonable" `Quick test_time_now_reasonable;
      test_case "not future" `Quick test_time_now_not_future;
    ];
    "parse_iso8601_opt", [
      test_case "valid" `Quick test_parse_iso8601_valid;
      test_case "invalid" `Quick test_parse_iso8601_invalid;
      test_case "empty" `Quick test_parse_iso8601_empty;
      test_case "partial" `Quick test_parse_iso8601_partial;
      test_case "no Z" `Quick test_parse_iso8601_no_z;
      test_case "midnight" `Quick test_parse_iso8601_midnight;
      test_case "end of day" `Quick test_parse_iso8601_end_of_day;
    ];
  ]
