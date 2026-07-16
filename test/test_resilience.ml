(** Resilience Module Tests — timestamp parsing. *)

open Alcotest

(* ================================================================
   Time.parse_iso8601_opt
   ================================================================ *)

let test_parse_iso8601_valid () =
  let result = Workspace_resilience.Time.parse_iso8601_opt "2025-06-15T12:30:00Z" in
  check bool "Some on valid ISO" true (Option.is_some result)

let test_parse_iso8601_valid_value () =
  (* Verify parsed value is a reasonable Unix timestamp (after year 2000) *)
  match Workspace_resilience.Time.parse_iso8601_opt "2025-01-01T00:00:00Z" with
  | Some ts -> check bool "timestamp > 2000-01-01" true (ts > 946684800.0)
  | None -> fail "should parse valid ISO8601"

let test_parse_iso8601_epoch () =
  let result = Workspace_resilience.Time.parse_iso8601_opt "1970-01-01T00:00:00Z" in
  check bool "Some on epoch" true (Option.is_some result)

let test_parse_iso8601_invalid_garbage () =
  let result = Workspace_resilience.Time.parse_iso8601_opt "not a date" in
  check (option (float 0.001)) "None on garbage" None result

let test_parse_iso8601_invalid_partial () =
  let result = Workspace_resilience.Time.parse_iso8601_opt "2025-06-15" in
  check (option (float 0.001)) "None on partial" None result

let test_parse_iso8601_empty () =
  let result = Workspace_resilience.Time.parse_iso8601_opt "" in
  check (option (float 0.001)) "None on empty" None result

let test_parse_iso8601_wrong_format () =
  let result = Workspace_resilience.Time.parse_iso8601_opt "15/06/2025 12:30:00" in
  check (option (float 0.001)) "None on wrong format" None result

let test_parse_iso8601_no_z_suffix () =
  (* Missing Z suffix — Scanf format requires Z *)
  let result = Workspace_resilience.Time.parse_iso8601_opt "2025-06-15T12:30:00" in
  check (option (float 0.001)) "None without Z" None result

(* ================================================================
   Runner
   ================================================================ *)

let () =
  run "Resilience" [
    "Time.parse_iso8601_opt", [
      test_case "valid ISO" `Quick test_parse_iso8601_valid;
      test_case "valid value range" `Quick test_parse_iso8601_valid_value;
      test_case "epoch" `Quick test_parse_iso8601_epoch;
      test_case "garbage" `Quick test_parse_iso8601_invalid_garbage;
      test_case "partial" `Quick test_parse_iso8601_invalid_partial;
      test_case "empty" `Quick test_parse_iso8601_empty;
      test_case "wrong format" `Quick test_parse_iso8601_wrong_format;
      test_case "no Z suffix" `Quick test_parse_iso8601_no_z_suffix;
    ];
  ]
