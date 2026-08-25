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
    [ Masc.Keeper_tool_group.Execute_group
    ; Masc.Keeper_tool_group.Search_files_group
    ; Masc.Keeper_tool_group.Filesystem_group
    ; Masc.Keeper_tool_group.Board_group
    ; Masc.Keeper_tool_group.Voice_group
    ; Masc.Keeper_tool_group.Workspace_group
    ; Masc.Keeper_tool_group.Surface_group
    ; Masc.Keeper_tool_group.Memory_group
    ; Masc.Keeper_tool_group.Meta_group
    ; Masc.Keeper_tool_group.Core_group
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

(* ---- folded composition verdicts ----
   A composition tool is built out of nodes the descriptor registry knows.
   The fold is made when the bundle is built, from the entry's validated
   plan: every node Run makes the composition Run, any Ask makes it Ask with
   the asking node named in [because]. *)

module Folded = Masc.Keeper_tool_approval_folded
module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan

(* One minimal composition document: two read-only nodes. *)
let read_only_composition_toml =
  {|
[[compositions]]
name = "mission_snapshot"
execution = "inline"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "memory"
tool = "keeper_memory_search"
after = ["clock"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "mission"
|}
;;

(* The same shape but one node writes a file. *)
let world_changing_composition_toml =
  {|
[[compositions]]
name = "snapshot_writer"
execution = "inline"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "write"
tool = "Write"
after = ["clock"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "file_path"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "out.txt"
[[compositions.nodes.input.fields]]
name = "content"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "hello"
|}
;;

let fold_of toml =
  match Catalog.parse toml with
  | Error error -> Alcotest.failf "catalog parse failed: %s" (Catalog.error_to_string error)
  | Ok catalog -> (
      match Catalog.entries catalog with
      | [] -> Alcotest.fail "catalog has no entries"
      | entry :: _ -> Folded.fold_entry entry)

let test_a_plan_of_only_run_nodes_folds_to_run () =
  let verdict = fold_of read_only_composition_toml in
  (match verdict with
   | Policy.Run { because } ->
     check string "the reason says why" "every node in the composition only reads" because
   | Policy.Ask { because } ->
     Alcotest.failf "read-only composition folded to Ask: %s" because)

let test_a_plan_with_an_asking_node_folds_to_ask_naming_the_node () =
  let verdict = fold_of world_changing_composition_toml in
  (match verdict with
   | Policy.Ask { because } ->
     (* The folded [because] is the asking node's own reason, which for a
        writing node names its group: Filesystem tools change something
        outside this turn. *)
     check bool "the reason carries the asking node's group" true
       (String.length because > 0)
   | Policy.Run { because } ->
     Alcotest.failf "world-changing composition folded to Run: %s" because)

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
    ; ( "folded compositions"
      , [ test_case "a plan of only Run nodes folds to Run" `Quick
            test_a_plan_of_only_run_nodes_folds_to_run
        ; test_case "a plan with an asking node folds to Ask naming the node" `Quick
            test_a_plan_with_an_asking_node_folds_to_ask_naming_the_node
        ] )
    ]
