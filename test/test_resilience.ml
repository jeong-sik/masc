(** Resilience Module Tests — Time and Zombie pure function coverage *)

open Alcotest

(* ================================================================
   Time.parse_iso8601_opt
   ================================================================ *)

let test_parse_iso8601_valid () =
  let result = Resilience.Time.parse_iso8601_opt "2025-06-15T12:30:00Z" in
  check bool "Some on valid ISO" true (Option.is_some result)
;;

let test_parse_iso8601_valid_value () =
  (* Verify parsed value is a reasonable Unix timestamp (after year 2000) *)
  match Resilience.Time.parse_iso8601_opt "2025-01-01T00:00:00Z" with
  | Some ts -> check bool "timestamp > 2000-01-01" true (ts > 946684800.0)
  | None -> fail "should parse valid ISO8601"
;;

let test_parse_iso8601_epoch () =
  let result = Resilience.Time.parse_iso8601_opt "1970-01-01T00:00:00Z" in
  check bool "Some on epoch" true (Option.is_some result)
;;

let test_parse_iso8601_invalid_garbage () =
  let result = Resilience.Time.parse_iso8601_opt "not a date" in
  check (option (float 0.001)) "None on garbage" None result
;;

let test_parse_iso8601_invalid_partial () =
  let result = Resilience.Time.parse_iso8601_opt "2025-06-15" in
  check (option (float 0.001)) "None on partial" None result
;;

let test_parse_iso8601_empty () =
  let result = Resilience.Time.parse_iso8601_opt "" in
  check (option (float 0.001)) "None on empty" None result
;;

let test_parse_iso8601_wrong_format () =
  let result = Resilience.Time.parse_iso8601_opt "15/06/2025 12:30:00" in
  check (option (float 0.001)) "None on wrong format" None result
;;

let test_parse_iso8601_no_z_suffix () =
  (* Missing Z suffix — Scanf format requires Z *)
  let result = Resilience.Time.parse_iso8601_opt "2025-06-15T12:30:00" in
  check (option (float 0.001)) "None without Z" None result
;;

(* ================================================================
   Time.is_stale
   ================================================================ *)

let test_is_stale_old_timestamp () =
  (* 2020-01-01 is definitely stale with default 300s threshold *)
  check
    bool
    "old timestamp is stale"
    true
    (Resilience.Time.is_stale "2020-01-01T00:00:00Z")
;;

let test_is_stale_invalid_timestamp () =
  (* Invalid timestamps are treated as stale *)
  check bool "invalid is stale" true (Resilience.Time.is_stale "garbage")
;;

let test_is_stale_empty () =
  check bool "empty is stale" true (Resilience.Time.is_stale "")
;;

let test_is_stale_custom_threshold () =
  (* Very large threshold — even old timestamps not stale *)
  check
    bool
    "not stale with huge threshold"
    false
    (Resilience.Time.is_stale ~threshold:999999999999.0 "2020-01-01T00:00:00Z")
;;

let test_is_stale_recent () =
  (* Generate a timestamp for "now" in ISO8601 format *)
  let now = Unix.gettimeofday () in
  let tm = Unix.gmtime now in
  let iso =
    Printf.sprintf
      "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900)
      (tm.Unix.tm_mon + 1)
      tm.Unix.tm_mday
      tm.Unix.tm_hour
      tm.Unix.tm_min
      tm.Unix.tm_sec
  in
  check
    bool
    "recent timestamp not stale"
    false
    (Resilience.Time.is_stale ~threshold:300.0 iso)
;;

(* ================================================================
   Zombie.is_zombie
   ================================================================ *)

let test_zombie_old () =
  check
    bool
    "old last_seen is zombie"
    true
    (Resilience.Zombie.is_zombie "2020-01-01T00:00:00Z")
;;

let test_zombie_invalid () =
  check bool "invalid last_seen is zombie" true (Resilience.Zombie.is_zombie "invalid")
;;

let test_zombie_recent () =
  let now = Unix.gettimeofday () in
  let tm = Unix.gmtime now in
  let iso =
    Printf.sprintf
      "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900)
      (tm.Unix.tm_mon + 1)
      tm.Unix.tm_mday
      tm.Unix.tm_hour
      tm.Unix.tm_min
      tm.Unix.tm_sec
  in
  check
    bool
    "recent last_seen not zombie"
    false
    (Resilience.Zombie.is_zombie ~threshold:300.0 iso)
;;

let test_zombie_custom_threshold () =
  check
    bool
    "not zombie with huge threshold"
    false
    (Resilience.Zombie.is_zombie ~threshold:999999999999.0 "2020-01-01T00:00:00Z")
;;

(* ================================================================
   ZeroZombie.cleanup (pure stats tracking)
   ================================================================ *)

let test_zero_zombie_cleanup_with_results () =
  let cleaned =
    Resilience.ZeroZombie.cleanup ~cleanup_fn:(fun () -> [ "agent-a"; "agent-b" ])
  in
  check (list string) "returns cleaned list" [ "agent-a"; "agent-b" ] cleaned;
  check
    bool
    "total_cleanups > 0"
    true
    (Resilience.ZeroZombie.global_stats.total_cleanups > 0)
;;

let test_zero_zombie_cleanup_empty () =
  let prev = Resilience.ZeroZombie.global_stats.total_cleanups in
  let cleaned = Resilience.ZeroZombie.cleanup ~cleanup_fn:(fun () -> []) in
  check (list string) "returns empty" [] cleaned;
  (* total_cleanups should NOT increment on empty cleanup *)
  check
    int
    "total_cleanups unchanged"
    prev
    Resilience.ZeroZombie.global_stats.total_cleanups
;;

(* ================================================================
   ZeroZombie.is_benign_error
   ================================================================ *)

let test_is_benign_error_masc_not_init () =
  let exn = Invalid_argument "MASC not initialized" in
  check
    bool
    "MASC not initialized is benign"
    true
    (Resilience.ZeroZombie.is_benign_error exn)
;;

let test_is_benign_error_no_such_file () =
  let exn = Sys_error "No such file or directory" in
  check
    bool
    "Sys_error 'No such file' is benign"
    true
    (Resilience.ZeroZombie.is_benign_error exn)
;;

let test_is_benign_error_other () =
  let exn = Failure "something bad" in
  check bool "other error is not benign" false (Resilience.ZeroZombie.is_benign_error exn)
;;

let test_is_benign_error_short_msg () =
  let exn = Failure "short" in
  check bool "short message not benign" false (Resilience.ZeroZombie.is_benign_error exn)
;;

(* ================================================================
   Zombie.is_keeper_name
   ================================================================ *)

let test_keeper_name_valid () =
  check
    bool
    "keeper-abc-agent is keeper"
    true
    (Resilience.Zombie.is_keeper_name "keeper-abc-agent")
;;

let test_keeper_name_case_insensitive () =
  check
    bool
    "Keeper-ABC-Agent is keeper"
    true
    (Resilience.Zombie.is_keeper_name "Keeper-ABC-Agent")
;;

let test_keeper_name_with_spaces () =
  check
    bool
    "trimmed keeper name"
    true
    (Resilience.Zombie.is_keeper_name "  keeper-test-agent  ")
;;

let test_keeper_name_regular_agent () =
  check bool "claude is not keeper" false (Resilience.Zombie.is_keeper_name "claude")
;;

let test_keeper_name_partial_match () =
  check
    bool
    "keeper-only prefix not keeper"
    false
    (Resilience.Zombie.is_keeper_name "keeper-")
;;

let test_keeper_name_empty () =
  check bool "empty not keeper" false (Resilience.Zombie.is_keeper_name "")
;;

(* ================================================================
   Zombie.is_zombie_for_agent
   ================================================================ *)

let make_iso_seconds_ago n =
  let t = Unix.gettimeofday () -. n in
  let tm = Unix.gmtime t in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
;;

let test_zombie_for_agent_regular_600s () =
  (* 600s old regular agent: should be zombie (default threshold 300s) *)
  let ts = make_iso_seconds_ago 600.0 in
  check
    bool
    "600s old regular agent is zombie"
    true
    (Resilience.Zombie.is_zombie_for_agent ~agent_name:"claude" ts)
;;

let test_zombie_for_agent_keeper_600s () =
  (* 600s old keeper agent: should NOT be zombie (keeper threshold 3600s) *)
  let ts = make_iso_seconds_ago 600.0 in
  check
    bool
    "600s old keeper agent is not zombie"
    false
    (Resilience.Zombie.is_zombie_for_agent ~agent_name:"keeper-eval-agent" ts)
;;

let test_zombie_for_agent_keeper_4000s () =
  (* 4000s old keeper agent: should be zombie (exceeds keeper threshold 3600s) *)
  let ts = make_iso_seconds_ago 4000.0 in
  check
    bool
    "4000s old keeper agent is zombie"
    true
    (Resilience.Zombie.is_zombie_for_agent ~agent_name:"keeper-eval-agent" ts)
;;

let test_zombie_for_agent_keeper_recent () =
  (* Recent keeper agent: not zombie *)
  let ts = make_iso_seconds_ago 10.0 in
  check
    bool
    "recent keeper agent not zombie"
    false
    (Resilience.Zombie.is_zombie_for_agent ~agent_name:"keeper-eval-agent" ts)
;;

(* ================================================================
   Runner
   ================================================================ *)

let () =
  run
    "Resilience"
    [ ( "Time.parse_iso8601_opt"
      , [ test_case "valid ISO" `Quick test_parse_iso8601_valid
        ; test_case "valid value range" `Quick test_parse_iso8601_valid_value
        ; test_case "epoch" `Quick test_parse_iso8601_epoch
        ; test_case "garbage" `Quick test_parse_iso8601_invalid_garbage
        ; test_case "partial" `Quick test_parse_iso8601_invalid_partial
        ; test_case "empty" `Quick test_parse_iso8601_empty
        ; test_case "wrong format" `Quick test_parse_iso8601_wrong_format
        ; test_case "no Z suffix" `Quick test_parse_iso8601_no_z_suffix
        ] )
    ; ( "Time.is_stale"
      , [ test_case "old timestamp" `Quick test_is_stale_old_timestamp
        ; test_case "invalid" `Quick test_is_stale_invalid_timestamp
        ; test_case "empty" `Quick test_is_stale_empty
        ; test_case "custom threshold" `Quick test_is_stale_custom_threshold
        ; test_case "recent" `Quick test_is_stale_recent
        ] )
    ; ( "Zombie.is_zombie"
      , [ test_case "old" `Quick test_zombie_old
        ; test_case "invalid" `Quick test_zombie_invalid
        ; test_case "recent" `Quick test_zombie_recent
        ; test_case "custom threshold" `Quick test_zombie_custom_threshold
        ] )
    ; ( "Zombie.is_keeper_name"
      , [ test_case "valid keeper" `Quick test_keeper_name_valid
        ; test_case "case insensitive" `Quick test_keeper_name_case_insensitive
        ; test_case "with spaces" `Quick test_keeper_name_with_spaces
        ; test_case "regular agent" `Quick test_keeper_name_regular_agent
        ; test_case "partial match" `Quick test_keeper_name_partial_match
        ; test_case "empty" `Quick test_keeper_name_empty
        ] )
    ; ( "Zombie.is_zombie_for_agent"
      , [ test_case "regular 600s" `Quick test_zombie_for_agent_regular_600s
        ; test_case "keeper 600s" `Quick test_zombie_for_agent_keeper_600s
        ; test_case "keeper 4000s" `Quick test_zombie_for_agent_keeper_4000s
        ; test_case "keeper recent" `Quick test_zombie_for_agent_keeper_recent
        ] )
    ; ( "ZeroZombie.cleanup"
      , [ test_case "with results" `Quick test_zero_zombie_cleanup_with_results
        ; test_case "empty" `Quick test_zero_zombie_cleanup_empty
        ] )
    ; ( "ZeroZombie.is_benign_error"
      , [ test_case "MASC not init" `Quick test_is_benign_error_masc_not_init
        ; test_case "no such file" `Quick test_is_benign_error_no_such_file
        ; test_case "other error" `Quick test_is_benign_error_other
        ; test_case "short message" `Quick test_is_benign_error_short_msg
        ] )
    ]
;;
