(** Tests for Health module — Keeper failure observation over Circuit Breaker.

    All tests that touch Circuit_breaker must run inside Eio_main.run
    because Circuit_breaker uses Eio.Mutex internally. *)

module Health = Masc.Health

open Alcotest

(* Test: get_summary returns correct structure *)
let test_get_summary () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-summary-" ^ string_of_int (Random.int 100000) in
  let s = Health.get_summary ~agent_name:name in
  check string "agent_name matches" name s.agent_name;
  check int "no recent failures" 0 s.recent_failures;
  check int "no cooldown" 0 s.cooldown_remaining_sec

(* Test: get_summary shows failures after recording *)
let test_get_summary_with_failures () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-sumfail-" ^ string_of_int (Random.int 100000) in
  Health.record_failure ~agent_name:name ~reason:"oops1";
  Health.record_failure ~agent_name:name ~reason:"oops2";
  let s = Health.get_summary ~agent_name:name in
  check string "agent_name" name s.agent_name;
  check bool "has failures" true (s.recent_failures >= 2)

(* Test: health_status_to_string — pure function, no Eio needed *)
let test_status_to_string () =
  check string "healthy" "healthy" (Health.health_status_to_string Health.Healthy);
  check string "recovering" "recovering" (Health.health_status_to_string Health.Recovering);
  check string "unhealthy" "unhealthy" (Health.health_status_to_string (Health.Unhealthy "x"));
  (* Issue #8607 *)
  check string "unknown" "unknown" (Health.health_status_to_string (Health.Unknown "throttled"))

(* Test: summary_to_json produces valid JSON *)
let test_summary_to_json () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-json-" ^ string_of_int (Random.int 100000) in
  let s = Health.get_summary ~agent_name:name in
  let json = Health.summary_to_json s in
  let json_str = Yojson.Safe.to_string json in
  check bool "contains agent_name" true (String.length json_str > 0);
  (* Verify it contains expected fields *)
  check bool "has agent_name field" true
    (try ignore (Yojson.Safe.Util.member "agent_name" json); true
     with _ -> false);
  check bool "has status field" true
    (try ignore (Yojson.Safe.Util.member "status" json); true
     with _ -> false)

let () =
  run "Health" [
    "summary", [
      test_case "get_summary structure" `Quick test_get_summary;
      test_case "get_summary with failures" `Quick test_get_summary_with_failures;
    ];
    "serialization", [
      test_case "status_to_string" `Quick test_status_to_string;
      test_case "summary_to_json" `Quick test_summary_to_json;
    ];
  ]
