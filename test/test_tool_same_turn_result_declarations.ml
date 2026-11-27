(* RFC-0510 D6: a tool turns the same-turn pointer on in its own file, and a
   file that says nothing keeps every result whole. *)

open Alcotest
open Masc

let same_turn_result =
  testable
    (fun ppf value -> Fmt.string ppf (Tool_definition_toml.same_turn_result_to_string value))
    ( = )
;;

let fixture key_line =
  Printf.sprintf "name = \"fixture_tool\"\ndescription = \"fixture\"\n%s" key_line
;;

let load contents = Tool_definition_toml.load ~name:"fixture_tool" ~contents

let test_absent_key_keeps_results_whole () =
  match load (fixture "") with
  | Error message -> fail message
  | Ok loaded ->
    check
      same_turn_result
      "no key"
      Tool_definition_toml.Repeat_sent_whole
      loaded.same_turn_result
;;

let test_true_is_a_pointer () =
  match load (fixture "same_turn_result_stub = true\n") with
  | Error message -> fail message
  | Ok loaded ->
    check
      same_turn_result
      "true"
      Tool_definition_toml.Repeat_sent_as_pointer
      loaded.same_turn_result
;;

let test_false_keeps_results_whole () =
  match load (fixture "same_turn_result_stub = false\n") with
  | Error message -> fail message
  | Ok loaded ->
    check
      same_turn_result
      "false"
      Tool_definition_toml.Repeat_sent_whole
      loaded.same_turn_result
;;

let test_a_value_that_is_not_a_bool_is_rejected () =
  match load (fixture "same_turn_result_stub = \"yes\"\n") with
  | Error _ -> ()
  | Ok _ -> fail "a string value was read as a declaration"
;;

let test_a_name_with_no_file_declares_nothing () =
  check
    (option same_turn_result)
    "no file"
    None
    (Tool_same_turn_result_declarations.declared "no-such-tool-exists")
;;

(* The request assembly asks by the name a model calls a tool, which
   [Keeper_tool_descriptor] derives from the descriptor that owns the file. A
   declaring file no descriptor owns, or whose descriptor has no model name,
   would be a declaration nothing honours. *)
let test_every_declaring_file_reaches_a_model_name () =
  List.iter
    (fun file_name ->
       let model_names =
         List.concat_map
           (fun (descriptor : Keeper_tool_descriptor.t) ->
              if String.equal descriptor.internal_name file_name
              then Keeper_tool_descriptor.keeper_model_names descriptor
              else [])
           (Keeper_tool_descriptor.all_descriptors ())
       in
       match model_names with
       | [] -> failf "%s declares same_turn_result_stub and no model calls it by any name" file_name
       | _ :: _ ->
         List.iter
           (fun name ->
              check
                bool
                (Printf.sprintf "%s is asked as %s" file_name name)
                true
                (List.exists
                   (String.equal name)
                   (Keeper_tool_descriptor.same_turn_result_pointer_model_names ())))
           model_names)
    (Tool_same_turn_result_declarations.sent_as_pointer ())
;;

(* RFC-0510 D6 turns the pointer on tool by tool, for tools that only read.
   The board read declares it. [Execute] has effects: a second run that prints
   the same text is a second event, not a second copy of the first. *)
let test_the_board_read_declares_it_and_execute_does_not () =
  check
    (option same_turn_result)
    "masc_board_post_get"
    (Some Tool_definition_toml.Repeat_sent_as_pointer)
    (Tool_same_turn_result_declarations.declared "masc_board_post_get");
  (* The request assembly reads a descriptor's internal name, and Execute's
     is tool_execute: that file decides what the model's Execute results do. *)
  check
    (option same_turn_result)
    "tool_execute"
    (Some Tool_definition_toml.Repeat_sent_whole)
    (Tool_same_turn_result_declarations.declared "tool_execute");
  let model_names = Keeper_tool_descriptor.same_turn_result_pointer_model_names () in
  check
    bool
    "the request assembly is asked about masc_board_post_get"
    true
    (List.exists (String.equal "masc_board_post_get") model_names);
  check
    bool
    "the request assembly is not asked about Execute"
    false
    (List.exists (String.equal "Execute") model_names)
;;

let () =
  run
    "tool same-turn result declarations"
    [ ( "declaration"
      , [ test_case "absent key keeps results whole" `Quick test_absent_key_keeps_results_whole
        ; test_case "true is a pointer" `Quick test_true_is_a_pointer
        ; test_case "false keeps results whole" `Quick test_false_keeps_results_whole
        ; test_case
            "a value that is not a bool is rejected"
            `Quick
            test_a_value_that_is_not_a_bool_is_rejected
        ; test_case
            "a name with no file declares nothing"
            `Quick
            test_a_name_with_no_file_declares_nothing
        ; test_case
            "every declaring file reaches a model name"
            `Quick
            test_every_declaring_file_reaches_a_model_name
        ; test_case
            "the board read declares it and Execute does not"
            `Quick
            test_the_board_read_declares_it_and_execute_does_not
        ] )
    ]
;;
