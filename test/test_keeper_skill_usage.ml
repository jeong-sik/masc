(* Keeper_skill_usage.count over tool-call log rows. *)

open Masc

let check_int = Alcotest.(check int)

let row ?(input = `Assoc []) tool = `Assoc [ "tool", `String tool; "input", input ]

let rows =
  [ row "keeper_compose_mission-snapshot"
  ; row "keeper_compose_mission-snapshot"
  ; row "keeper_compose_background-snapshot"
  ; row ~input:(`Assoc [ "name", `String "work-intake" ]) "keeper_skill"
  ; row ~input:(`Assoc [ "name", `String "work-intake" ]) "keeper_skill"
  ; row ~input:(`Assoc [ "name", `String "turn-opening" ]) "keeper_skill"
  ; row ~input:(`Assoc [ "name", `Int 3 ]) "keeper_skill"
  ; row "Read"
  ; `Assoc [ "keeper", `String "no-tool-field" ]
  ]
;;

let test_composition_counts_its_tool () =
  check_int "mission-snapshot" 2
    (Keeper_skill_usage.count ~rows
       (Keeper_skill_usage.Composition_tool "keeper_compose_mission-snapshot"));
  check_int "background-snapshot" 1
    (Keeper_skill_usage.count ~rows
       (Keeper_skill_usage.Composition_tool "keeper_compose_background-snapshot"));
  check_int "unknown tool" 0
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Composition_tool "keeper_compose_nope"))
;;

let test_instruction_counts_keeper_skill_reads_by_name () =
  check_int "work-intake" 2
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Instruction_read "work-intake"));
  check_int "turn-opening" 1
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Instruction_read "turn-opening"));
  check_int "a name that is not a string never matches" 0
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Instruction_read "3"));
  check_int "a Read call is not a skill read" 0
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Instruction_read "Read"))
;;

let () =
  Alcotest.run
    "keeper-skill-usage"
    [ ( "count"
      , [ Alcotest.test_case "composition counts its tool" `Quick
            test_composition_counts_its_tool
        ; Alcotest.test_case "instruction counts keeper_skill reads by name" `Quick
            test_instruction_counts_keeper_skill_reads_by_name
        ] )
    ]
;;
