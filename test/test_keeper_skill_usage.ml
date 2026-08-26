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
  ; row
      ~input:
        (`Assoc
           [ "name", `String "work-intake"
           ; "file", `String "references/REFERENCE.md"
           ])
      "keeper_skill"
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

(* The two answer different questions, so a file read must not land in the body
   count: a skill read twice whose references were opened once is 2 and 1, not
   3 and 1. *)
let test_a_file_read_is_counted_apart_from_the_body () =
  check_int "body reads stay at two" 2
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Instruction_read "work-intake"));
  check_int "the file read is its own count" 1
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Reference_read "work-intake"));
  check_int "a skill whose files were never opened" 0
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Reference_read "turn-opening"))
;;

let () =
  Alcotest.run
    "keeper-skill-usage"
    [ ( "count"
      , [ Alcotest.test_case "composition counts its tool" `Quick
            test_composition_counts_its_tool
        ; Alcotest.test_case "instruction counts keeper_skill reads by name" `Quick
            test_instruction_counts_keeper_skill_reads_by_name
        ; Alcotest.test_case "a file read is counted apart from the body" `Quick
            test_a_file_read_is_counted_apart_from_the_body
        ] )
    ]
;;
