(* The phase gate writes its decision as the manifest [Phase_gate_decided]
   row. The type fixes which decisions exist; it does not fix how each one is
   spelled on the row. A supervisor stop has no [phase] field at all, a
   missing registry phase has [phase: null], and only an executable phase
   says [executable: true]. These rows pin that spelling. *)

module Plan = Masc.Keeper_unified_turn_phase_plan

let row plan =
  Plan.turn_plan_manifest_status plan
  ^ " "
  ^ Yojson.Safe.to_string (Plan.turn_plan_manifest_decision plan)
;;

let case name plan expected =
  Alcotest.test_case name `Quick (fun () ->
    Alcotest.(check string) name expected (row plan))
;;

let () =
  Alcotest.run
    "keeper phase gate plan"
    [ ( "manifest row"
      , [ case
            "supervisor stop has no phase field"
            Plan.supervisor_stopped
            {|cancelled {"reason":"supervisor_stop","executable":false}|}
        ; case
            "missing registry phase is null"
            (Plan.turn_plan_of_registry_phase None)
            {|error {"phase":null,"reason":"registry_phase_missing","executable":false}|}
        ; case
            "non-executable phase is named"
            (Plan.turn_plan_of_registry_phase (Some Keeper_state_machine.Paused))
            {|skipped {"phase":"paused","reason":"non_executable_phase","executable":false}|}
        ; case
            "executable phase is named and executable"
            (Plan.turn_plan_of_registry_phase (Some Keeper_state_machine.Running))
            {|ok {"phase":"running","reason":"executable_phase","executable":true}|}
        ] )
    ]
;;
