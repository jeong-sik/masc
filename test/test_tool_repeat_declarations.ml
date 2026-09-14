(** A tool says in its own file whether calling it again with the same input
    moves the machine on. The loop guard reads that; nothing else keeps a
    list of which tools step. *)

open Alcotest
open Masc

let repeat =
  testable (fun ppf r -> Fmt.string ppf (Tool_definition_toml.repeat_to_string r)) ( = )

(* Silence is a read: every tool was read that way before this axis existed. *)
let test_absent_declaration_is_a_read () =
  check repeat "a tool with no same_input_advances key is a read"
    Tool_definition_toml.Same_input_reads
    (Tool_repeat_declarations.repeat_of_tool "keeper_tasks_list");
  check bool "and does not advance" false
    (Tool_repeat_declarations.advances "keeper_tasks_list")
;;

let test_unknown_name_is_a_read () =
  check repeat "a name with no tool file is a read"
    Tool_definition_toml.Same_input_reads
    (Tool_repeat_declarations.repeat_of_tool "no-such-tool-exists")
;;

(* The tools that step a machine. Each file says so beside the description
   that says what a repeat does; this holds the two in step. *)
let test_the_machine_steppers_declare_it () =
  List.iter
    (fun name ->
       check repeat (name ^ " advances on a repeat")
         Tool_definition_toml.Same_input_advances
         (Tool_repeat_declarations.repeat_of_tool name))
    [ "masc_msx_step"
    ; "masc_msx_press"
    ; "masc_msx_step_until_change"
    ; "masc_dos_step"
    ; "masc_dos_press"
    ; "masc_dos_type"
    ]
;;

(* Reading the machine is a read, whatever the machine. *)
let test_the_machine_readers_do_not () =
  List.iter
    (fun name ->
       check repeat (name ^ " is a read")
         Tool_definition_toml.Same_input_reads
         (Tool_repeat_declarations.repeat_of_tool name))
    [ "masc_msx_screen"; "masc_msx_peek"; "masc_dos_screen"; "masc_dos_peek" ]
;;

let test_declaration_round_trips () =
  let load flag =
    Tool_definition_toml.load ~name:"fixture_tool"
      ~contents:
        (Printf.sprintf
           {|name = "fixture_tool"
description = "fixture"
same_input_advances = %s
|}
           flag)
  in
  (match load "true" with
   | Ok loaded ->
     check repeat "true reads as advances" Tool_definition_toml.Same_input_advances
       loaded.repeat
   | Error message -> fail message);
  (match load "false" with
   | Ok loaded ->
     check repeat "false reads as a read" Tool_definition_toml.Same_input_reads
       loaded.repeat
   | Error message -> fail message);
  match load "\"yes\"" with
  | Ok _ -> fail "a string is not a declaration"
  | Error message ->
    check bool ("the error names the key: " ^ message) true
      (Astring.String.is_infix ~affix:"same_input_advances" message)
;;

let () =
  run "tool repeat declarations"
    [ ( "declaration"
      , [ test_case "absent is a read" `Quick test_absent_declaration_is_a_read
        ; test_case "unknown name is a read" `Quick test_unknown_name_is_a_read
        ; test_case "the machine steppers declare it" `Quick
            test_the_machine_steppers_declare_it
        ; test_case "the machine readers do not" `Quick test_the_machine_readers_do_not
        ; test_case "the declaration round trips" `Quick test_declaration_round_trips
        ] )
    ]
;;
