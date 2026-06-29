open Alcotest

let test_rank_contract () =
  check int "blocked" 3 (Health_status.rank_string "blocked");
  check int "error" 3 (Health_status.rank_string "error");
  check int "timeout" 3 (Health_status.rank_string "timeout");
  check int "degraded" 2 (Health_status.rank_string "degraded");
  check int "stale" 2 (Health_status.rank_string "stale");
  check int "warning" 2 (Health_status.rank_string "warning");
  check int "unavailable" 2 (Health_status.rank_string "unavailable");
  check int "unknown" 2 (Health_status.rank_string "unknown");
  check int "warming" 1 (Health_status.rank_string "warming");
  check int "snapshot_not_ready" 1 (Health_status.rank_string "snapshot_not_ready");
  check int "ok" 0 (Health_status.rank_string "ok")

let test_dashboard_compat_uses_health_status_ssot () =
  let blocked = Dashboard_utils.health_level_of_string "blocked" in
  check int "blocked rank" 3 (Dashboard_utils.severity_rank_of_health_level blocked);
  check bool "blocked critical" true (Dashboard_utils.is_health_critical blocked);
  check bool "blocked at risk" true (Dashboard_utils.is_health_at_risk blocked);
  check string "blocked label" "blocked" (Dashboard_utils.string_of_health_level blocked);
  let unknown = Dashboard_utils.health_level_of_string "future_status" in
  check int "unknown rank" 2 (Dashboard_utils.severity_rank_of_health_level unknown);
  check bool "unknown warning" true (Dashboard_utils.is_health_warning unknown);
  check string "unknown label" "unknown" (Dashboard_utils.string_of_health_level unknown)

let test_legacy_dashboard_synonyms_map_to_shared_statuses () =
  check Health_status.(testable pp equal) "critical" Error (Health_status.of_string "critical");
  check Health_status.(testable pp equal) "bad" Error (Health_status.of_string "bad");
  check Health_status.(testable pp equal) "risk" Warning (Health_status.of_string "risk");
  check Health_status.(testable pp equal) "watch" Warning (Health_status.of_string "watch");
  check Health_status.(testable pp equal) "interrupted" Degraded
    (Health_status.of_string "interrupted");
  check Health_status.(testable pp equal) "healthy" Ok (Health_status.of_string "healthy")

let test_max_string_canonicalizes_through_ssot () =
  check string "stronger right" "timeout" (Health_status.max_string "warning" "timeout");
  check string "tie keeps left canonical" "blocked" (Health_status.max_string "blocked" "error");
  check string "unknown beats ok" "unknown" (Health_status.max_string "ok" "new_status")

let () =
  run "Health_status"
    [
      ( "rank",
        [
          test_case "rank contract" `Quick test_rank_contract;
          test_case "max string" `Quick test_max_string_canonicalizes_through_ssot;
        ] );
      ( "dashboard compat",
        [
          test_case "dashboard wrappers use SSOT" `Quick test_dashboard_compat_uses_health_status_ssot;
          test_case "legacy synonyms" `Quick test_legacy_dashboard_synonyms_map_to_shared_statuses;
        ] );
    ]
