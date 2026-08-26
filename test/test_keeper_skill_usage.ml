(* Keeper_skill_usage.count over tool-call log rows. *)

open Masc

let check_int = Alcotest.(check int)

let row ?record_kind ?disposition ?success ?composition_tool ?(input = `Assoc []) tool =
  let optional name encode = function
    | None -> []
    | Some value -> [ name, encode value ]
  in
  `Assoc
    ([ "tool", `String tool; "input", input ]
     @ optional "record_kind" (fun value -> `String value) record_kind
     @ optional "disposition" (fun value -> `String value) disposition
     @ optional "success" (fun value -> `Bool value) success
     @ optional "composition_tool" (fun value -> `String value) composition_tool)
;;

let rows =
  [ row "keeper_compose_mission-snapshot"
  ; row "keeper_compose_mission-snapshot"
  ; row "keeper_compose_background-snapshot"
  ; row ~success:true ~input:(`Assoc [ "name", `String "work-intake" ]) "keeper_skill"
  ; row ~success:false ~input:(`Assoc [ "name", `String "work-intake" ]) "keeper_skill"
  ; row
      ~disposition:"deferred"
      ~success:false
      ~input:(`Assoc [ "name", `String "work-intake" ])
      "keeper_skill"
  ; row ~success:true ~input:(`Assoc [ "name", `String "turn-opening" ]) "keeper_skill"
  ; row ~input:(`Assoc [ "name", `Int 3 ]) "keeper_skill"
  ; row "Read"
  ; row
      ~record_kind:"composition_run"
      ~success:true
      ~composition_tool:"keeper_compose_mission-snapshot"
      Keeper_skill_usage.composition_run_summary_tool_name
  ; row
      ~record_kind:"composition_run"
      ~success:false
      ~composition_tool:"keeper_compose_mission-snapshot"
      Keeper_skill_usage.composition_run_summary_tool_name
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
  check_int "work-intake" 3
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Instruction_read "work-intake"));
  check_int "turn-opening" 1
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Instruction_read "turn-opening"));
  check_int "a name that is not a string never matches" 0
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Instruction_read "3"));
  check_int "a Read call is not a skill read" 0
    (Keeper_skill_usage.count ~rows (Keeper_skill_usage.Instruction_read "Read"))
;;

let test_outcomes_do_not_treat_async_acceptance_as_success () =
  let composition =
    Keeper_skill_usage.summarize
      ~rows
      (Keeper_skill_usage.Composition_tool "keeper_compose_mission-snapshot")
  in
  check_int "composition calls" 2 composition.use_count;
  check_int "terminal successes" 1 composition.success_count;
  check_int "terminal failures" 1 composition.failure_count;
  let instruction =
    Keeper_skill_usage.summarize
      ~rows
      (Keeper_skill_usage.Instruction_read "work-intake")
  in
  check_int "instruction reads" 3 instruction.use_count;
  check_int "instruction successes" 1 instruction.success_count;
  check_int "instruction failures" 1 instruction.failure_count
;;

let () =
  Alcotest.run
    "keeper-skill-usage"
    [ ( "count"
      , [ Alcotest.test_case "composition counts its tool" `Quick
            test_composition_counts_its_tool
        ; Alcotest.test_case "instruction counts keeper_skill reads by name" `Quick
            test_instruction_counts_keeper_skill_reads_by_name
        ; Alcotest.test_case "terminal outcomes stay separate from use" `Quick
            test_outcomes_do_not_treat_async_acceptance_as_success
        ] )
    ]
;;
