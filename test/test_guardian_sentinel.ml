open Alcotest
open Masc_mcp

module U = Yojson.Safe.Util

let with_temp_room_root f =
  let dir = Filename.temp_dir "guardian-sentinel-" "" in
  let config = Room.default_config dir in
  Fun.protect
    ~finally:(fun () ->
      if Room.is_initialized config then ignore (Room.reset config);
      Unix.rmdir dir)
    (fun () -> f config)

let reset_runtime_state () =
  Guardian.reset_runtime_state_for_tests ();
  Sentinel.reset_runtime_state_for_tests ()

let test_sentinel_ensures_room_initialized () =
  with_temp_room_root (fun config ->
    check bool "room starts uninitialized" false (Room.is_initialized config);
    Sentinel.ensure_room_initialized_for_start config;
    check bool "room initialized by sentinel helper" true (Room.is_initialized config))

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

let test_sentinel_board_patrol_status_defaults_to_silent () =
  reset_runtime_state ();
  Sentinel.mark_started_for_tests ();
  Sentinel.note_board_patrol_result_for_tests ~checked_at:1234567890.0
    ~action:"silent" ~reason:"no stale posts over 7d" ~stale_count:0 ();
  let sentinel = Sentinel.status_json () in
  let patrol = sentinel |> U.member "board_patrol" in
  check string "last action" "silent" (patrol |> U.member "last_action" |> U.to_string);
  check string "last reason" "no stale posts over 7d"
    (patrol |> U.member "last_reason" |> U.to_string);
  check int "last stale count" 0 (patrol |> U.member "last_stale_count" |> U.to_int)

let test_board_patrol_decision_parser () =
  let decision =
    Sentinel.board_patrol_decision_of_llm_json
      (`Assoc
        [
          ("needs_attention", `Bool true);
          ("reason", `String "2 stale posts need review");
          ("board_post", `String "Two stale sentinel-board posts need review.");
        ])
  in
  check bool "needs attention" true decision.needs_attention;
  check (option string) "reason" (Some "2 stale posts need review") decision.reason;
  check (option string) "board post"
    (Some "Two stale sentinel-board posts need review.") decision.board_post

let test_sentinel_board_patrol_day_key_roundtrip () =
  with_temp_room_root (fun config ->
    Sentinel.ensure_room_initialized_for_start config;
    check (option string) "empty default" None
      (Sentinel.read_board_patrol_day_key_for_tests config);
    Sentinel.write_board_patrol_day_key_for_tests config "2026-072";
    check (option string) "persisted day key" (Some "2026-072")
      (Sentinel.read_board_patrol_day_key_for_tests config);
    reset_runtime_state ();
    check (option string) "persists across runtime reset" (Some "2026-072")
      (Sentinel.read_board_patrol_day_key_for_tests config))

let () =
  run "Guardian/Sentinel"
    [
      ("runtime", [
        test_case "sentinel ensures room initialized" `Quick test_sentinel_ensures_room_initialized;
        test_case "guardian status defaults" `Quick test_guardian_status_defaults;
        test_case "guardian embedded loops ignore master switch" `Quick test_guardian_embedded_loops_ignore_master_switch;
        test_case "sentinel reports embedded guardian runtime" `Quick test_sentinel_status_reports_embedded_guardian_runtime;
        test_case "sentinel board patrol status defaults to silent" `Quick test_sentinel_board_patrol_status_defaults_to_silent;
        test_case "board patrol decision parser" `Quick test_board_patrol_decision_parser;
        test_case "board patrol day key roundtrip" `Quick test_sentinel_board_patrol_day_key_roundtrip;
      ]);
    ]
