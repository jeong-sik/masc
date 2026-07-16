(** Resilience Module Coverage Tests

    Tests for MASC Resilience:
    - default_zombie_threshold: constant
    - default_warning_threshold: constant
    - Time.now: current time
    - Time.parse_iso8601_opt: ISO timestamp parsing
    - Time.is_stale: staleness check
    - Zombie.is_zombie: zombie detection
*)

open Alcotest


(* ============================================================
   Constants Tests
   ============================================================ *)

let test_default_zombie_threshold_positive () =
  check bool "positive" true (Workspace_resilience.default_zombie_threshold > 0.0)

let test_default_zombie_threshold_matches_env_config () =
  check (float 0.01) "matches env config"
    Env_config.Zombie.threshold_seconds
    Workspace_resilience.default_zombie_threshold

let test_default_zombie_threshold_reasonable () =
  (* Should be between 30 seconds and 24 hours *)
  check bool "reasonable" true
    (Workspace_resilience.default_zombie_threshold >= 30.0 &&
     Workspace_resilience.default_zombie_threshold <= 86400.0)

let test_default_warning_threshold_positive () =
  check bool "positive" true (Workspace_resilience.default_warning_threshold > 0.0)

let test_default_warning_less_than_zombie () =
  check bool "warning < zombie" true
    (Workspace_resilience.default_warning_threshold <= Workspace_resilience.default_zombie_threshold)

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
   Time.is_stale Tests
   ============================================================ *)

let test_is_stale_old_timestamp () =
  let old_ts = "2020-01-01T00:00:00Z" in
  check bool "old is stale" true (Workspace_resilience.Time.is_stale old_ts)

let test_is_stale_invalid_timestamp () =
  check bool "invalid is stale" true (Workspace_resilience.Time.is_stale "invalid")

let test_is_stale_empty_timestamp () =
  check bool "empty is stale" true (Workspace_resilience.Time.is_stale "")

let test_is_stale_custom_threshold () =
  let old_ts = "2020-01-01T00:00:00Z" in
  check bool "stale with threshold" true
    (Workspace_resilience.Time.is_stale ~threshold:1.0 old_ts)

(* ============================================================
   Zombie.is_zombie Tests
   ============================================================ *)

let test_zombie_old_agent () =
  let old_ts = "2020-01-01T00:00:00Z" in
  check bool "old agent is zombie" true (Workspace_resilience.Zombie.is_zombie old_ts)

let test_zombie_invalid_timestamp () =
  check bool "invalid is zombie" true (Workspace_resilience.Zombie.is_zombie "invalid")

let test_zombie_custom_threshold () =
  let old_ts = "2020-01-01T00:00:00Z" in
  check bool "zombie with threshold" true
    (Workspace_resilience.Zombie.is_zombie ~threshold:1.0 old_ts)

let test_keeper_zombie_threshold_matches_env_config () =
  let old_ts = "2020-01-01T00:00:00Z" in
  let expected =
    Workspace_resilience.Zombie.is_zombie
      ~threshold:Env_config.Zombie.keeper_threshold_seconds
      old_ts
  in
  check bool "keeper threshold uses env config" expected
    (Workspace_resilience.Zombie.is_zombie_for_agent
       ~agent_type:"keeper"
       ~agent_name:"keeper-demo-agent"
       old_ts)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Resilience Coverage" [
    "constants", [
      test_case "zombie threshold positive" `Quick test_default_zombie_threshold_positive;
      test_case "zombie threshold matches env config" `Quick test_default_zombie_threshold_matches_env_config;
      test_case "zombie threshold reasonable" `Quick test_default_zombie_threshold_reasonable;
      test_case "warning threshold positive" `Quick test_default_warning_threshold_positive;
      test_case "warning < zombie" `Quick test_default_warning_less_than_zombie;
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
    "is_stale", [
      test_case "old timestamp" `Quick test_is_stale_old_timestamp;
      test_case "invalid timestamp" `Quick test_is_stale_invalid_timestamp;
      test_case "empty timestamp" `Quick test_is_stale_empty_timestamp;
      test_case "custom threshold" `Quick test_is_stale_custom_threshold;
    ];
    "zombie", [
      test_case "old agent" `Quick test_zombie_old_agent;
      test_case "invalid timestamp" `Quick test_zombie_invalid_timestamp;
      test_case "custom threshold" `Quick test_zombie_custom_threshold;
      test_case "keeper threshold matches env config" `Quick test_keeper_zombie_threshold_matches_env_config;
    ];
  ]
