open Alcotest

module Policy = Masc.Keeper_tool_approval_policy
module Descriptor = Masc.Keeper_tool_descriptor

let asks ~tool_name ~input =
  match Policy.verdict_for ~tool_name ~input with
  | Policy.Ask _ -> true
  | Policy.Run _ -> false

let because ~tool_name ~input =
  Policy.verdict_because (Policy.verdict_for ~tool_name ~input)

let no_input = `Assoc []

(* The catalogue itself, not a fixture. What matters is how the policy splits
   the tools a keeper actually has: a rule that reads well but puts Read on
   the asking side would make an operator stop reading the questions. *)
let test_the_split_over_the_real_catalogue () =
  let asked, ran =
    Descriptor.public_names ()
    |> List.partition (fun tool_name -> asks ~tool_name ~input:no_input)
  in
  check (slist string String.compare) "only the tools that change something"
    [ "Edit"; "Execute"; "Write" ] asked;
  check (slist string String.compare) "everything else runs unasked"
    [ "Grep"; "Read"; "WebFetch"; "WebSearch" ] ran

let test_reading_is_never_asked_about () =
  (* Reading to answer a question is the bulk of what a keeper does. *)
  check bool "reading a file" false
    (asks ~tool_name:"Read" ~input:(`Assoc [ "file_path", `String "a.ml" ]));
  check string "and the reason says why" "this call only reads"
    (because ~tool_name:"Read" ~input:(`Assoc [ "file_path", `String "a.ml" ]))

let test_writing_and_running_are_asked_about () =
  check bool "editing a file" true
    (asks ~tool_name:"Edit" ~input:(`Assoc [ "file_path", `String "a.ml" ]));
  check bool "writing a file" true
    (asks ~tool_name:"Write" ~input:(`Assoc [ "file_path", `String "a.ml" ]));
  check bool "running a program" true
    (asks ~tool_name:"Execute" ~input:(`Assoc [ "argv", `List [ `String "rm" ] ]))

let test_an_unclassifiable_tool_is_asked_about () =
  (* An unknown tool is not a safe tool. If it ran unasked, "no descriptor"
     would be the quietest way past the gate. *)
  check bool "a tool no descriptor claims" true
    (asks ~tool_name:"not-a-real-tool" ~input:no_input);
  check string "and the reason names the gap"
    "no descriptor declares what this tool does"
    (because ~tool_name:"not-a-real-tool" ~input:no_input)

let test_every_group_is_classified () =
  (* The groups are a closed type and the policy matches all of them, so this
     passes by construction today. It is here to fail loudly if that match is
     ever loosened to a catch-all: a new family of tools must not inherit
     "runs without asking" by saying nothing. *)
  let groups =
    [ Descriptor.Execute_group
    ; Descriptor.Search_files_group
    ; Descriptor.Filesystem_group
    ; Descriptor.Board_group
    ; Descriptor.Voice_group
    ; Descriptor.Workspace_group
    ; Descriptor.Surface_group
    ; Descriptor.Memory_group
    ; Descriptor.Meta_group
    ; Descriptor.Core_group
    ]
  in
  check int "every group in the closed type is named here" 10
    (List.length groups)

let test_the_question_names_the_call () =
  (* Same argument the chat surfaces already show for a tool call, so the
     prompt and the row above it agree on what the call is. *)
  check string "a file the call would change" "Run Edit on lib/a.ml?"
    (Policy.question_for ~tool_name:"Edit"
       ~input:(`Assoc [ "file_path", `String "lib/a.ml" ]));
  check string "a command it would run" "Run Execute on rm -rf build?"
    (Policy.question_for ~tool_name:"Execute"
       ~input:(`Assoc [ "command", `String "rm -rf build" ]));
  check string "and a call with no argument to name is still asked"
    "Run Execute?"
    (Policy.question_for ~tool_name:"Execute" ~input:no_input)

let () =
  run "keeper_tool_approval_policy"
    [ ( "the split"
      , [ test_case "over the real catalogue" `Quick
            test_the_split_over_the_real_catalogue
        ; test_case "reading is never asked about" `Quick
            test_reading_is_never_asked_about
        ; test_case "writing and running are asked about" `Quick
            test_writing_and_running_are_asked_about
        ] )
    ; ( "unknowns"
      , [ test_case "an unclassifiable tool is asked about" `Quick
            test_an_unclassifiable_tool_is_asked_about
        ; test_case "every group is classified" `Quick
            test_every_group_is_classified
        ] )
    ; ( "the question"
      , [ test_case "names the call" `Quick test_the_question_names_the_call ] )
    ]
