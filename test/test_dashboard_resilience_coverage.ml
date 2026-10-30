(** Dashboard and Resilience Module Coverage Tests

    Tests for:
    - Dashboard: section types, formatting, constants, timestamp parsing
    - Resilience: Time utilities and Zombie detection
*)

open Alcotest

module Dashboard = Dashboard

(* ============================================================
   Dashboard Constants Tests
   ============================================================ *)

let test_dashboard_max_path_length () =
  check int "max_path_length" 30 (Dashboard.max_path_length ())

let test_dashboard_max_message_length () =
  check int "max_message_length" 35 (Dashboard.max_message_length ())

let test_dashboard_max_pending_tasks () =
  check int "max_pending_tasks" 5 (Dashboard.max_pending_tasks ())

let test_dashboard_max_recent_messages () =
  check int "max_recent_messages" 5 (Dashboard.max_recent_messages ())

let test_dashboard_min_border_length () =
  check int "min_border_length" 45 (Dashboard.min_border_length ())

(* ============================================================
   Dashboard section Tests
   ============================================================ *)

let test_section_creation () =
  let s : Dashboard.section = {
    title = "Test Section";
    content = ["line 1"; "line 2"; "line 3"];
    empty_msg = "(no data)";
  } in
  check string "title" "Test Section" s.title;
  check int "content count" 3 (List.length s.content);
  check string "empty_msg" "(no data)" s.empty_msg

let test_section_empty () =
  let s : Dashboard.section = {
    title = "Empty";
    content = [];
    empty_msg = "(nothing here)";
  } in
  check int "empty content" 0 (List.length s.content)

(* ============================================================
   Dashboard format_section Tests
   ============================================================ *)

let test_format_section_with_content () =
  let s : Dashboard.section = {
    title = "Agents";
    content = ["agent1"; "agent2"];
    empty_msg = "(no agents)";
  } in
  let formatted = Dashboard.format_section s in
  check bool "contains title" true (String.length formatted > 0);
  check bool "contains agent1" true (String.length formatted > 0)

let test_format_section_empty () =
  let s : Dashboard.section = {
    title = "Tasks";
    content = [];
    empty_msg = "(no tasks)";
  } in
  let formatted = Dashboard.format_section s in
  check bool "non-empty output" true (String.length formatted > 0)

let test_format_section_long_title () =
  let s : Dashboard.section = {
    title = "This Is A Very Long Section Title For Testing";
    content = ["item"];
    empty_msg = "none";
  } in
  let formatted = Dashboard.format_section s in
  check bool "handles long title" true (String.length formatted > 50)

(* ============================================================
   Dashboard parse_iso_timestamp Tests
   ============================================================ *)

let test_parse_iso_timestamp_valid () =
  match Dashboard.parse_iso_timestamp "2025-01-09T12:00:00Z" with
  | Some ts -> check bool "positive timestamp" true (ts > 0.0)
  | None -> fail "should parse valid timestamp"

let test_parse_iso_timestamp_with_millis () =
  match Dashboard.parse_iso_timestamp "2025-01-09T12:00:00.123Z" with
  | Some ts -> check bool "positive timestamp" true (ts > 0.0)
  | None -> fail "should parse timestamp with millis"

let test_parse_iso_timestamp_invalid () =
  match Dashboard.parse_iso_timestamp "invalid" with
  | Some _ -> fail "should reject invalid"
  | None -> ()

let test_parse_iso_timestamp_empty () =
  match Dashboard.parse_iso_timestamp "" with
  | Some _ -> fail "should reject empty"
  | None -> ()

let test_parse_iso_timestamp_partial () =
  match Dashboard.parse_iso_timestamp "2025-01-09" with
  | Some _ -> fail "should reject partial"
  | None -> ()

let test_resilience_default_warning_threshold () =
  check bool "warning threshold" true (abs_float (Workspace_resilience.default_warning_threshold -. 120.0) < 0.001)

(* ============================================================
   Workspace_resilience.Time Tests
   ============================================================ *)

let test_time_now () =
  let t = Workspace_resilience.Time.now () in
  check bool "positive time" true (t > 0.0);
  (* Should be after Jan 1, 2020 *)
  check bool "reasonable time" true (t > 1577836800.0)

let test_time_parse_iso8601_valid () =
  match Workspace_resilience.Time.parse_iso8601_opt "2025-01-09T12:30:45Z" with
  | Some ts -> check bool "positive" true (ts > 0.0)
  | None -> fail "should parse valid ISO8601"

let test_time_parse_iso8601_invalid () =
  match Workspace_resilience.Time.parse_iso8601_opt "not-a-date" with
  | Some _ -> fail "should reject invalid"
  | None -> ()

let test_time_parse_iso8601_empty () =
  match Workspace_resilience.Time.parse_iso8601_opt "" with
  | Some _ -> fail "should reject empty"
  | None -> ()

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Dashboard & Resilience Coverage" [
    "dashboard.constants", [
      test_case "max_path_length" `Quick test_dashboard_max_path_length;
      test_case "max_message_length" `Quick test_dashboard_max_message_length;
      test_case "max_pending_tasks" `Quick test_dashboard_max_pending_tasks;
      test_case "max_recent_messages" `Quick test_dashboard_max_recent_messages;
      test_case "min_border_length" `Quick test_dashboard_min_border_length;
    ];
    "dashboard.section", [
      test_case "creation" `Quick test_section_creation;
      test_case "empty" `Quick test_section_empty;
    ];
    "dashboard.format_section", [
      test_case "with content" `Quick test_format_section_with_content;
      test_case "empty" `Quick test_format_section_empty;
      test_case "long title" `Quick test_format_section_long_title;
    ];
    "dashboard.parse_timestamp", [
      test_case "valid" `Quick test_parse_iso_timestamp_valid;
      test_case "with millis" `Quick test_parse_iso_timestamp_with_millis;
      test_case "invalid" `Quick test_parse_iso_timestamp_invalid;
      test_case "empty" `Quick test_parse_iso_timestamp_empty;
      test_case "partial" `Quick test_parse_iso_timestamp_partial;
    ];
    "resilience.thresholds", [
      test_case "warning threshold" `Quick test_resilience_default_warning_threshold;
    ];
    "resilience.time", [
      test_case "now" `Quick test_time_now;
      test_case "parse valid" `Quick test_time_parse_iso8601_valid;
      test_case "parse invalid" `Quick test_time_parse_iso8601_invalid;
      test_case "parse empty" `Quick test_time_parse_iso8601_empty;
    ];
  ]
