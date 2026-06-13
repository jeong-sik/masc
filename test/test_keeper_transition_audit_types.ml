open Alcotest

module T = Keeper_transition_audit_types
module FSM = Keeper_state_machine

let test_operator_pause_signal_requires_decision () =
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
  let signal = T.operator_signal_of_transition record in
  check string "class" "operator_gate" signal.signal_class;
  check bool "requires decision" true signal.requires_operator_decision;
  check (option string) "next action" (Some "resume_or_update_policy")
    signal.next_human_action
;;

let test_completed_turn_json_round_trip () =
  let record : T.completed_turn_record =
    { turn_id = 42
    ; started_at = 10.0
    ; ended_at = 12.5
    ; outcome = T.Turn_gate_rejected
    }
  in
  check (option int) "turn id" (Some 42)
    (Option.map (fun (r : T.completed_turn_record) -> r.turn_id)
       (T.completed_turn_of_json (T.completed_turn_to_json record)));
  check (option bool) "outcome"
    (Some true)
    (Option.map
       (fun (r : T.completed_turn_record) -> r.outcome = T.Turn_gate_rejected)
       (T.completed_turn_of_json (T.completed_turn_to_json record)))
;;

let () =
  run
    "Keeper_transition_audit_types"
    [ ( "operator_signal"
      , [ test_case
            "operator pause requires a human decision"
            `Quick
            test_operator_pause_signal_requires_decision
        ] )
    ; ( "completed_turn"
      , [ test_case "json round-trip preserves fields" `Quick test_completed_turn_json_round_trip
        ] )
    ]
;;
