open Alcotest

module T = Keeper_transition_audit_types
module FSM = Keeper_state_machine

let test_transition_json_preserves_observed_facts () =
  let record : T.transition_record =
    { snapshot = None
    ; events_fired = [ FSM.Operator_pause ]
    ; selected_event = FSM.Operator_pause
    ; prev_phase = FSM.Running
    ; new_phase = FSM.Paused
    ; transition_outcome = "applied"
    ; wall_clock_at_decision = 1.25
    }
  in
  let json = T.to_json record in
  let open Yojson.Safe.Util in
  check string "event type" "operator_pause" (json |> member "event_type" |> to_string);
  check string "previous phase" "running" (json |> member "prev_phase" |> to_string);
  check string "new phase" "paused" (json |> member "new_phase" |> to_string);
  check string "outcome" "applied" (json |> member "transition_outcome" |> to_string);
  check (float 1e-9) "decision timestamp" 1.25
    (json |> member "wall_clock_at_decision" |> to_float);
  check int "transition JSON has only observed fields" 8
    (match json with `Assoc fields -> List.length fields | _ -> 0)
;;

let test_completed_turn_json_round_trip () =
  let record : T.completed_turn_record =
    { turn_id = 42
    ; started_at = 10.0
    ; ended_at = 12.5
    ; outcome = T.Turn_failed
    }
  in
  check (option int) "turn id" (Some 42)
    (Option.map (fun (r : T.completed_turn_record) -> r.turn_id)
       (T.completed_turn_of_json (T.completed_turn_to_json record)));
  check (option bool) "outcome"
    (Some true)
    (Option.map
       (fun (r : T.completed_turn_record) -> r.outcome = T.Turn_failed)
       (T.completed_turn_of_json (T.completed_turn_to_json record)))
;;

let () =
  run
    "Keeper_transition_audit_types"
    [ ( "transition_observation"
      , [ test_case
            "JSON preserves exact transition facts"
            `Quick
            test_transition_json_preserves_observed_facts
        ] )
    ; ( "completed_turn"
      , [ test_case "json round-trip preserves fields" `Quick test_completed_turn_json_round_trip
        ] )
    ]
;;
