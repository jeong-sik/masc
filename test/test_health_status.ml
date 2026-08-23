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

(* Every status word the producers in #27560 emit. `of_string_opt` answering
   [None] means that module speaks a vocabulary this type never declared, so
   the value lands on [Unknown] and its severity is whatever [Unknown] ranks —
   not what the producer meant. Adding a producer word without deciding where
   it belongs breaks this list. *)
let producer_vocabulary =
  [ (* channel_gate_metrics.health_of_counts *)
    "idle", None
  ; "healthy", Some Health_status.Ok
  ; "failing", Some Health_status.Error
  ; "degraded", Some Health_status.Degraded
    (* keeper_reaction_ledger *)
  ; "empty", None
    (* keeper_manual_compaction *)
  ; "compacted", None
    (* server_dashboard_http_runtime_info *)
  ; "reachable", None
  ; "no_http_runtimes", None
    (* schedule_runner_status *)
  ; "stale", Some Health_status.Stale
  ]
;;

let test_producer_vocabulary_membership () =
  List.iter
    (fun (raw, expected) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s recognized" raw)
        (Option.is_some expected)
        (Option.is_some (Health_status.of_string_opt raw)))
    producer_vocabulary
;;

let test_failing_outranks_degraded () =
  (* The producer ladder puts `failing` (no successes, or >=50%% errors) above
     `degraded`. Before `failing` was declared here both ranked 2. *)
  Alcotest.(check bool)
    "failing is more severe than degraded"
    true
    (Health_status.rank (Health_status.of_string "failing")
     > Health_status.rank (Health_status.of_string "degraded"))
;;

let test_unknown_word_is_distinguishable () =
  Alcotest.(check bool)
    "an undeclared word is not an explicit unknown"
    true
    (Health_status.of_string_opt "no_http_runtimes" = None
     && Health_status.of_string_opt "unknown" = Some Health_status.Unknown)
;;

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
      ( "producer vocabulary",
        [
          test_case "membership is declared" `Quick test_producer_vocabulary_membership;
          test_case "failing outranks degraded" `Quick test_failing_outranks_degraded;
          test_case "undeclared word is distinguishable" `Quick
            test_unknown_word_is_distinguishable;
        ] );
      ( "agent_status rank",
        [
          test_case "serialized status ranks through the wire" `Quick
            test_serialized_agent_status_ranks_through_the_wire;
        ] );
    ]
