open Masc
module U = Yojson.Safe.Util

let first_list_item name json =
  match json |> U.member name |> U.to_list with
  | x :: _ -> x
  | [] -> Alcotest.failf "expected %s to contain at least one item" name
;;

let test_heuristics_feed_exposes_o5_shape () =
  let event =
    Heuristic_metrics.event_to_json
      { module_name = "keeper"
      ; site = "guard"
      ; raw_value = 0.91
      ; threshold = 0.80
      ; triggered = true
      ; provenance = Heuristic_metrics.Drift_guard "ctx"
      ; timestamp = 1_777_120_045.0
      }
  in
  let feed = Heuristic_metrics.dashboard_feed_json ~limit:50 [ event ] in
  let item = first_list_item "heuristics" feed in
  Alcotest.(check string)
    "heuristics dashboard surface"
    "/api/v1/dashboard/heuristics"
    (feed |> U.member "dashboard_surface" |> U.to_string);
  Alcotest.(check string)
    "heuristics source"
    "heuristic_metrics"
    (feed |> U.member "source" |> U.to_string);
  Alcotest.(check string)
    "heuristics durable store"
    ".masc/heuristic_metrics.jsonl"
    (feed |> U.member "retention" |> U.member "durable_store" |> U.to_string);
  Alcotest.(check int) "raw event count" 1 (feed |> U.member "count" |> U.to_int);
  Alcotest.(check string)
    "rule id"
    "keeper.guard"
    (item |> U.member "rule_id" |> U.to_string);
  Alcotest.(check string) "action" "triggered" (item |> U.member "action" |> U.to_string);
  Alcotest.(check int) "cooldown" 0 (item |> U.member "cooldown_remaining_ms" |> U.to_int)
;;

let test_heuristics_coverage_exposes_source_metadata () =
  let report =
    { Heuristic_metrics.total_events = 2
    ; sites =
        [ { Heuristic_metrics.module_name = "keeper"
          ; site = "guard"
          ; count = 2
          ; triggered_count = 1
          }
        ]
    ; decision_shape_count = 1
    ; mixed_outcome_sites = 1
    ; unique_decision_tuples = 1
    }
  in
  let json = Heuristic_metrics.coverage_report_to_json report in
  Alcotest.(check string)
    "coverage dashboard surface"
    "/api/v1/dashboard/heuristics/coverage"
    (json |> U.member "dashboard_surface" |> U.to_string);
  Alcotest.(check string)
    "coverage source"
    "heuristic_metrics"
    (json |> U.member "source" |> U.to_string);
  Alcotest.(check int)
    "coverage total"
    2
    (json |> U.member "total_events" |> U.to_int)
;;

let () =
  Alcotest.run
    "dashboard_o5_feeds"
    [ ( "o5"
      , [ Alcotest.test_case
            "heuristics response carries issue-shape array"
            `Quick
            test_heuristics_feed_exposes_o5_shape
        ; Alcotest.test_case
            "heuristics coverage carries source metadata"
            `Quick
            test_heuristics_coverage_exposes_source_metadata
        ] )
    ]
;;
