open Masc_mcp
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
  Alcotest.(check int) "raw event count" 1 (feed |> U.member "count" |> U.to_int);
  Alcotest.(check string)
    "rule id"
    "keeper.guard"
    (item |> U.member "rule_id" |> U.to_string);
  Alcotest.(check string) "action" "triggered" (item |> U.member "action" |> U.to_string);
  Alcotest.(check int) "cooldown" 0 (item |> U.member "cooldown_remaining_ms" |> U.to_int)
;;

let test_agent_stress_feed_exposes_board_rows () =
  let event =
    Agent_stress.event_to_json
      { agent_name = "sangsu"
      ; room_id = "default"
      ; kind =
          Agent_stress.Turn_failure
            { consecutive = 2
            ; threshold = 4
            ; counted_toward_crash = true
            ; recoverable = false
            ; error_kind = Some (Agent_stress.error_kind_of_string "api")
            }
      ; timestamp = 99.0
      }
  in
  let agents =
    [ { Agent_stress.agent = "sangsu"
      ; ctx_pressure = Some 0.80
      ; queue_depth = Some 2
      ; blocked_on = Some "Admission_queue_wait_timeout"
      ; ts = Some 100.0
      }
    ]
  in
  let feed = Agent_stress.dashboard_feed_json ~limit:25 ~agents [ event ] in
  let row = first_list_item "agent_stress" feed in
  Alcotest.(check int) "raw event count" 1 (feed |> U.member "count" |> U.to_int);
  Alcotest.(check string) "agent" "sangsu" (row |> U.member "agent" |> U.to_string);
  Alcotest.(check (float 0.001))
    "budget pressure"
    0.50
    (row |> U.member "budget_pressure" |> U.to_float);
  Alcotest.(check (float 0.001))
    "context pressure"
    0.80
    (row |> U.member "ctx_pressure" |> U.to_float);
  Alcotest.(check int) "queue depth" 2 (row |> U.member "queue_depth" |> U.to_int);
  Alcotest.(check string)
    "blocked on"
    "Admission_queue_wait_timeout"
    (row |> U.member "blocked_on" |> U.to_string)
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
            "stress response carries agent board rows"
            `Quick
            test_agent_stress_feed_exposes_board_rows
        ] )
    ]
;;
