open Alcotest
open Masc

module Host = Keeper_official_client_host

let () = Random.self_init ()

(* {1 Where a start seed begins (창 RFC §7 (라), §10.4)} *)

module Choice = Keeper_turn_driver_try_provider

let msg role text = Agent_core.Types.make_message ~role [ Agent_core.Types.Text text ]

let start_seed_trace = "official-front-trace"

(* Two atoms the Memory writer read, then one the keeper is still on. *)
let absorbed_messages =
  [ msg Agent_core.Types.User "Build the patch."
  ; msg Agent_core.Types.Assistant "The build passed."
  ]
;;

let working_state = "Build passed. Review is open."

(* Every atom of [absorbed_messages] is read. *)
let absorbed_end = snd (Runtime_model_input_tail_window.annotate absorbed_messages)

(* The writer's read end after [absorbed_messages], with the working state it
   committed ([state], the fixture's by default). *)
let absorbed ?(state = working_state) () =
  Choice.Covered { Choice.end_atom = absorbed_end; working_state = Some state }
;;

(* What the Memory screen records for a request this lane composed, in the
   Agent Core lane's words. A read-end front records itself; any other front
   records whether the turn had a read end, and a read end this request did
   not start from is [Not_applied], as a turn that read none is. *)
module Observation = Keeper_continuity_observation

let test_the_observation_records_the_front_or_why_the_choice_was_not_applied () =
  let input ?continuity front =
    Host.continuity_observation_input ~trace_id:start_seed_trace ~continuity front
  in
  (match input (Host.Covered_with_working_state { end_atom = absorbed_end }) with
   | Observation.Absorbed { trace_id; end_atom } ->
     check string "the turn's trace" start_seed_trace trace_id;
     check int "the read end" absorbed_end end_atom
   | Observation.Summarized _ | Observation.Without_snapshot | Observation.Not_applied ->
     fail "a working-state front was not recorded as absorbed");
  (match input (Host.Covered { end_atom = 2 }) with
   | Observation.Absorbed { end_atom = 2; _ } -> ()
   | _ -> fail "a read-end front was not recorded as absorbed");
  (match input Host.Turn_start with
   | Observation.Not_applied -> ()
   | _ -> fail "a turn that read no continuity was not recorded as not applied");
  (match input ~continuity:Choice.No_read_end Host.Turn_start with
   | Observation.Without_snapshot -> ()
   | _ -> fail "a turn with no read end was not recorded so");
  match input ~continuity:(absorbed ()) Host.Lane_cut with
  | Observation.Not_applied -> ()
  | _ -> fail "a read end the lane cut passed was recorded as applied"
;;

let () =
  run
    "keeper_official_client_host_continuity_observation"
    [ ( "where a start seed begins"
      , [ test_case
            "the observation records the front or why the choice was not applied"
            `Quick
            test_the_observation_records_the_front_or_why_the_choice_was_not_applied
        ] )
    ]
;;
