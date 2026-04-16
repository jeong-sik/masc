(** Unit tests for Cascade_health_tracker record behavior.

    Guards against the regression where record_success / record_failure
    were defined but never wired into the cascade execution path, leaving
    every provider's effective_weight stuck at config_weight * 1.0. *)

open Alcotest
module H = Masc_mcp.Cascade_health_tracker

let test_record_success_keeps_rate_1 () =
  let t = H.create () in
  H.record_success t ~provider_key:"p";
  check (float 0.001) "success rate 1.0 after 1 success"
    1.0 (H.success_rate t ~provider_key:"p")

let test_single_failure_no_cooldown () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p";
  check bool "single failure does not trip cooldown"
    false (H.is_in_cooldown t ~provider_key:"p")

let test_cooldown_after_threshold () =
  (* cooldown_threshold default = 3 *)
  let t = H.create () in
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  check bool "cooldown trips after 3 consecutive failures"
    true (H.is_in_cooldown t ~provider_key:"p")

let test_success_resets_streak () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  H.record_success t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  check bool "success resets consecutive_failures"
    false (H.is_in_cooldown t ~provider_key:"p")

let test_effective_weight_cooldown_zero () =
  let t = H.create () in
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  check int "effective_weight = 0 during cooldown"
    0 (H.effective_weight t ~provider_key:"p" ~config_weight:100)

let test_effective_weight_unknown_full () =
  let t = H.create () in
  check int "unknown provider → full config_weight"
    100 (H.effective_weight t ~provider_key:"unseen" ~config_weight:100)

let test_provider_info_reflects_events () =
  let t = H.create () in
  H.record_success t ~provider_key:"p";
  H.record_failure t ~provider_key:"p";
  match H.provider_info t ~provider_key:"p" with
  | None -> fail "provider_info returned None after record calls"
  | Some info ->
    check int "events_in_window = 2" 2 info.events_in_window;
    check int "consecutive_failures = 1" 1 info.consecutive_failures

let () =
  run "cascade_health_tracker" [
    "record", [
      test_case "record_success keeps rate at 1.0" `Quick
        test_record_success_keeps_rate_1;
      test_case "single failure does not cooldown" `Quick
        test_single_failure_no_cooldown;
      test_case "cooldown after threshold" `Quick
        test_cooldown_after_threshold;
      test_case "success resets streak" `Quick
        test_success_resets_streak;
      test_case "effective_weight zero in cooldown" `Quick
        test_effective_weight_cooldown_zero;
      test_case "unknown provider full weight" `Quick
        test_effective_weight_unknown_full;
      test_case "provider_info reflects events" `Quick
        test_provider_info_reflects_events;
    ];
  ]
