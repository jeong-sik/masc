(** Test Keeper_behavior_trace shadow trace harness (P3-2). *)

open Masc

let sample_events () =
  [ { Keeper_behavior_trace.agent = "alice"; turn = 1; tool = "masc_board_post"
    ; arguments = `Assoc [ ("title", `String "hello") ]
    }
  ; { Keeper_behavior_trace.agent = "alice"; turn = 2; tool = "masc_tasks"
    ; arguments = `Assoc [ ("limit", `Int 10) ]
    }
  ; { Keeper_behavior_trace.agent = "bob"; turn = 1; tool = "masc_board_post"
    ; arguments = `Assoc [ ("title", `String "hi") ]
    }
  ]
;;

let select_tool () =
  let events = sample_events () in
  let selected = Keeper_behavior_trace.select (Tool "masc_board_post") events in
  Alcotest.(check int) "two board posts" 2 (List.length selected);
  Alcotest.(check bool) "all board posts" true
    (List.for_all (fun e -> String.equal e.Keeper_behavior_trace.tool "masc_board_post") selected)
;;

let select_agent () =
  let events = sample_events () in
  let selected = Keeper_behavior_trace.select (Agent "alice") events in
  Alcotest.(check int) "two alice events" 2 (List.length selected)
;;

let select_turn_range () =
  let events = sample_events () in
  let selected = Keeper_behavior_trace.select (Turn_range (1, 1)) events in
  Alcotest.(check int) "two turn-1 events" 2 (List.length selected)
;;

let fixture_roundtrip () =
  let fixture =
    { Keeper_behavior_trace.name = "demo"
    ; identity = "keeper-demo"
    ; surface = [ "masc_board_post"; "masc_tasks" ]
    ; events = sample_events ()
    }
  in
  let json = Keeper_behavior_trace.fixture_to_json fixture in
  match Keeper_behavior_trace.fixture_of_json json with
  | Ok f ->
    Alcotest.(check string) "name" "demo" f.name;
    Alcotest.(check string) "identity" "keeper-demo" f.identity;
    Alcotest.(check int) "surface count" 2 (List.length f.surface);
    Alcotest.(check int) "events count" 3 (List.length f.events)
  | Error msg -> Alcotest.fail msg
;;

let () =
  Alcotest.run
    "Keeper_behavior_trace P3-2"
    [ ( "selectors"
      , [ Alcotest.test_case "select tool" `Quick select_tool
        ; Alcotest.test_case "select agent" `Quick select_agent
        ; Alcotest.test_case "select turn range" `Quick select_turn_range
        ; Alcotest.test_case "fixture roundtrip" `Quick fixture_roundtrip
        ] )
    ]
;;
