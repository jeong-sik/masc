open Alcotest
open Masc_mcp

module U = Yojson.Safe.Util

let reset_runtime_state () =
  Guardian.reset_runtime_state_for_tests ();
  Sentinel.reset_runtime_state_for_tests ()

let test_guardian_status_defaults () =
  reset_runtime_state ();
  let json = Guardian.status_json () in
  check bool "guardian enabled default false" false (json |> U.member "enabled" |> U.to_bool);
  check bool "masc loops not running" false (json |> U.member "masc_loops_running" |> U.to_bool);
  check string "runtime owner none" "none" (json |> U.member "runtime_owner" |> U.to_string)

let test_guardian_embedded_loops_ignore_master_switch () =
  reset_runtime_state ();
  Guardian.note_embedded_masc_loops_started_for_tests ();
  let json = Guardian.status_json () in
  check bool "guardian configured disabled" false (json |> U.member "enabled" |> U.to_bool);
  check bool "embedded loops running" true (json |> U.member "masc_loops_running" |> U.to_bool);
  check string "owner is sentinel" "sentinel" (json |> U.member "runtime_owner" |> U.to_string)

let test_sentinel_status_reports_embedded_guardian_runtime () =
  reset_runtime_state ();
  Sentinel.mark_started_for_tests ();
  Guardian.note_embedded_masc_loops_started_for_tests ();
  let sentinel = Sentinel.status_json () in
  let consumers = sentinel |> U.member "consumers" |> U.to_list |> List.map U.to_string in
  check bool "sentinel started" true (sentinel |> U.member "started" |> U.to_bool);
  check bool "embedded guardian loops running" true
    (sentinel |> U.member "embedded_guardian_loops_running" |> U.to_bool);
  check string "guardian runtime owner" "sentinel"
    (sentinel |> U.member "guardian_runtime_owner" |> U.to_string);
  check bool "consumer includes guardian-zombie" true (List.mem "guardian-zombie" consumers);
  check bool "consumer includes guardian-gc" true (List.mem "guardian-gc" consumers);
  let guardian = Guardian.status_json () in
  check string "guardian status owner follows sentinel" "sentinel"
    (guardian |> U.member "runtime_owner" |> U.to_string)

let () =
  run "Guardian/Sentinel"
    [
      ("runtime", [
        test_case "guardian status defaults" `Quick test_guardian_status_defaults;
        test_case "guardian embedded loops ignore master switch" `Quick test_guardian_embedded_loops_ignore_master_switch;
        test_case "sentinel reports embedded guardian runtime" `Quick test_sentinel_status_reports_embedded_guardian_runtime;
      ]);
    ]
