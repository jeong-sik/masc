(** Tests for Agent_health module — Autonomy-specific health gate over Circuit Breaker.

    All tests that touch Circuit_breaker must run inside Eio_main.run
    because Circuit_breaker uses Eio.Mutex internally. *)

module Agent_health = Masc_mcp.Agent_health

open Alcotest

(* Test: fresh agent is healthy *)
let test_fresh_agent_healthy () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-health-fresh-" ^ string_of_int (Random.int 100000) in
  let status = Agent_health.check_health ~agent_name:name in
  match status with
  | Agent_health.Healthy -> ()
  | Agent_health.Recovering -> fail "expected Healthy, got Recovering"
  | Agent_health.Unhealthy r -> fail (Printf.sprintf "expected Healthy, got Unhealthy(%s)" r)
  | Agent_health.Unknown raw -> fail (Printf.sprintf "expected Healthy, got Unknown(%S)" raw)

(* Test: is_healthy returns true for fresh agent *)
let test_is_healthy_fresh () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-healthy-" ^ string_of_int (Random.int 100000) in
  check bool "fresh agent is healthy" true (Agent_health.is_healthy ~agent_name:name)

(* Test: recording success keeps agent healthy *)
let test_record_success_stays_healthy () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-success-" ^ string_of_int (Random.int 100000) in
  Agent_health.record_success ~agent_name:name;
  check bool "still healthy after success" true (Agent_health.is_healthy ~agent_name:name)

(* Test: repeated failures make agent unhealthy *)
let test_failures_make_unhealthy () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-fail-" ^ string_of_int (Random.int 100000) in
  (* Default threshold is 3 failures in 60s *)
  Agent_health.record_failure ~agent_name:name ~reason:"test-error-1";
  Agent_health.record_failure ~agent_name:name ~reason:"test-error-2";
  Agent_health.record_failure ~agent_name:name ~reason:"test-error-3";
  let healthy = Agent_health.is_healthy ~agent_name:name in
  check bool "unhealthy after 3 failures" false healthy

(* Test: check_health returns Unhealthy with reason after breaker opens *)
let test_unhealthy_has_reason () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-reason-" ^ string_of_int (Random.int 100000) in
  Agent_health.record_failure ~agent_name:name ~reason:"boom-1";
  Agent_health.record_failure ~agent_name:name ~reason:"boom-2";
  Agent_health.record_failure ~agent_name:name ~reason:"boom-3";
  match Agent_health.check_health ~agent_name:name with
  | Agent_health.Unhealthy _ -> ()  (* reason present *)
  | Agent_health.Healthy -> fail "expected Unhealthy, got Healthy"
  | Agent_health.Recovering -> fail "expected Unhealthy, got Recovering"
  | Agent_health.Unknown raw -> fail (Printf.sprintf "expected Unhealthy, got Unknown(%S)" raw)

(* Test: filter_healthy separates healthy from unhealthy *)
let test_filter_healthy () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let healthy_name = "test-filter-ok-" ^ string_of_int (Random.int 100000) in
  let sick_name = "test-filter-sick-" ^ string_of_int (Random.int 100000) in
  (* Make one agent unhealthy *)
  Agent_health.record_failure ~agent_name:sick_name ~reason:"err1";
  Agent_health.record_failure ~agent_name:sick_name ~reason:"err2";
  Agent_health.record_failure ~agent_name:sick_name ~reason:"err3";
  let agents = [(healthy_name, 1); (sick_name, 2)] in
  let (healthy, skipped) = Agent_health.filter_healthy agents in
  check int "one healthy" 1 (List.length healthy);
  check int "one skipped" 1 (List.length skipped);
  check string "healthy name" healthy_name (fst (List.hd healthy));
  check string "skipped name" sick_name (fst (List.hd skipped))

(* Test: get_summary returns correct structure *)
let test_get_summary () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-summary-" ^ string_of_int (Random.int 100000) in
  let s = Agent_health.get_summary ~agent_name:name in
  check string "agent_name matches" name s.agent_name;
  check int "no recent failures" 0 s.recent_failures;
  check int "no cooldown" 0 s.cooldown_remaining_sec

(* Test: get_summary shows failures after recording *)
let test_get_summary_with_failures () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-sumfail-" ^ string_of_int (Random.int 100000) in
  Agent_health.record_failure ~agent_name:name ~reason:"oops1";
  Agent_health.record_failure ~agent_name:name ~reason:"oops2";
  let s = Agent_health.get_summary ~agent_name:name in
  check string "agent_name" name s.agent_name;
  check bool "has failures" true (s.recent_failures >= 2)

(* Test: health_status_to_string — pure function, no Eio needed *)
let test_status_to_string () =
  check string "healthy" "healthy" (Agent_health.health_status_to_string Agent_health.Healthy);
  check string "recovering" "recovering" (Agent_health.health_status_to_string Agent_health.Recovering);
  check string "unhealthy" "unhealthy" (Agent_health.health_status_to_string (Agent_health.Unhealthy "x"));
  (* Issue #8607 *)
  check string "unknown" "unknown" (Agent_health.health_status_to_string (Agent_health.Unknown "throttled"))

(* Test: summary_to_json produces valid JSON *)
let test_summary_to_json () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-json-" ^ string_of_int (Random.int 100000) in
  let s = Agent_health.get_summary ~agent_name:name in
  let json = Agent_health.summary_to_json s in
  let json_str = Yojson.Safe.to_string json in
  check bool "contains agent_name" true (String.length json_str > 0);
  (* Verify it contains expected fields *)
  check bool "has agent_name field" true
    (try ignore (Yojson.Safe.Util.member "agent_name" json); true
     with _ -> false);
  check bool "has status field" true
    (try ignore (Yojson.Safe.Util.member "status" json); true
     with _ -> false)

(* Test: success after failures resets health (if not yet opened) *)
let test_success_resets_partial_failures () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-reset-" ^ string_of_int (Random.int 100000) in
  Agent_health.record_failure ~agent_name:name ~reason:"err1";
  Agent_health.record_failure ~agent_name:name ~reason:"err2";
  (* 2 failures, not enough to open breaker (threshold=3) *)
  Agent_health.record_success ~agent_name:name;
  check bool "still healthy after reset" true (Agent_health.is_healthy ~agent_name:name)

let () =
  run "Agent_health" [
    "check_health", [
      test_case "fresh agent is healthy" `Quick test_fresh_agent_healthy;
      test_case "is_healthy returns true for fresh" `Quick test_is_healthy_fresh;
      test_case "success keeps healthy" `Quick test_record_success_stays_healthy;
      test_case "3 failures make unhealthy" `Quick test_failures_make_unhealthy;
      test_case "unhealthy has reason" `Quick test_unhealthy_has_reason;
      test_case "success resets partial failures" `Quick test_success_resets_partial_failures;
    ];
    "filter_healthy", [
      test_case "separates healthy from sick" `Quick test_filter_healthy;
    ];
    "summary", [
      test_case "get_summary structure" `Quick test_get_summary;
      test_case "get_summary with failures" `Quick test_get_summary_with_failures;
    ];
    "serialization", [
      test_case "status_to_string" `Quick test_status_to_string;
      test_case "summary_to_json" `Quick test_summary_to_json;
    ];
  ]
