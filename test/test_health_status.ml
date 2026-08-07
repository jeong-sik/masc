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


(* A serialized agent_status is ranked by decoding it. The string ranker this
   replaced had an arm for "idle" — a spelling agent_status_to_string never
   emits — while [Inactive] fell through to the catch-all and ranked 0, the
   same as garbage. *)
let test_serialized_agent_status_ranks_through_the_wire () =
  List.iter
    (fun status ->
       let raw = Masc_domain.agent_status_to_string status in
       check int
         (Printf.sprintf "%s ranks the same through the wire" raw)
         (Masc_domain.agent_status_rank status)
         (Dashboard_utils.status_rank raw))
    Masc_domain.all_agent_statuses;
  check int "a non-status string ranks 0" 0 (Dashboard_utils.status_rank "idle")

(* [Dashboard_utils.keeper_offline_status_strings] is hand-mirrored: the
   masc_dashboard_utils library cannot depend on the one that owns
   [Keeper_status_runtime.surface_status], so the offline vocabulary is a
   literal list there. This is the mirror test for it, the same role
   test_assertion_kind_mirror plays for masc_check's enum.

   Subset, not equality — offline-ness is a proper subset of the statuses a
   producer can emit. What it catches is the other direction: an entry no
   producer can ever produce, which reads as coverage and is dead. *)
let producible_keeper_statuses =
  List.map
    Masc.Keeper_status_runtime.surface_status_to_string
    [ Masc.Keeper_status_runtime.Surface_active
    ; Masc.Keeper_status_runtime.Surface_busy
    ; Masc.Keeper_status_runtime.Surface_listening
    ; Masc.Keeper_status_runtime.Surface_inactive
    ; Masc.Keeper_status_runtime.Surface_offline
    ; Masc.Keeper_status_runtime.Surface_idle
    ]
  @ [ Masc.Keeper_status_runtime.control_plane_status_to_string
        Masc.Keeper_status_runtime.Cp_paused
    ]

let test_offline_vocabulary_is_producible () =
  List.iter
    (fun entry ->
      check bool
        (Printf.sprintf "%S is a status some producer emits" entry)
        true
        (List.mem entry producible_keeper_statuses))
    Dashboard_utils.keeper_offline_status_strings

let test_offline_predicate_agrees_with_its_vocabulary () =
  List.iter
    (fun status ->
      check bool
        (Printf.sprintf "is_keeper_offline %S" status)
        (List.mem status Dashboard_utils.keeper_offline_status_strings)
        (Dashboard_utils.is_keeper_offline status))
    producible_keeper_statuses

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
      ( "agent_status rank",
        [
          test_case "serialized status ranks through the wire" `Quick
            test_serialized_agent_status_ranks_through_the_wire;
        ] );
      ( "keeper offline vocabulary",
        [
          test_case "every entry is producible" `Quick
            test_offline_vocabulary_is_producible;
          test_case "predicate agrees with its vocabulary" `Quick
            test_offline_predicate_agrees_with_its_vocabulary;
        ] );
    ]
