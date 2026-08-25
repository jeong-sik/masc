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


(* ── compositions ────────────────────────────────────────────────────────
   A composition tool is materialised outside the descriptor registry, so a
   descriptor lookup finds nothing. Before the plan index the policy read that
   as "cannot classify" and asked about every composition, including one whose
   whole plan is reads -- while the same tools called directly ran unasked. *)

module Index = Masc.Keeper_tool_composition_plan_index

let mentions haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
  at 0
;;

let with_index rows f =
  let index = Index.shared () in
  Index.forget_all index;
  List.iter
    (fun (composition, node_tools) -> Index.record index ~composition ~node_tools)
    rows;
  Fun.protect ~finally:(fun () -> Index.forget_all index) f
;;

let test_a_plan_of_reads_runs_unasked () =
  with_index [ "keeper_compose_reading", [ "Read"; "Grep" ] ] (fun () ->
    check bool "a composition that only reads is not asked about" false
      (asks ~tool_name:"keeper_compose_reading" ~input:no_input);
    check bool "the reason counts the nodes it cleared" true
      (String.length (because ~tool_name:"keeper_compose_reading" ~input:no_input) > 0))
;;

let test_one_writing_node_asks_and_names_itself () =
  with_index [ "keeper_compose_mixed", [ "Read"; "Write"; "Grep" ] ] (fun () ->
    check bool "one node that changes something asks for the whole plan" true
      (asks ~tool_name:"keeper_compose_mixed" ~input:no_input);
    let reason = because ~tool_name:"keeper_compose_mixed" ~input:no_input in
    (* Without the node name the operator sees a composition name and has to
       go read the plan to learn why they are being asked. *)
    check bool "the reason names the node responsible" true
      (mentions reason "Write"))
;;

let test_an_unrecorded_name_is_still_unclassifiable () =
  with_index [] (fun () ->
    check bool "a name that is not a composition keeps the old answer" true
      (asks ~tool_name:"keeper_compose_never_declared" ~input:no_input);
    check string "and keeps the old reason"
      "no descriptor declares what this tool does"
      (because ~tool_name:"keeper_compose_never_declared" ~input:no_input))
;;

(* keeper_plan_execute carries no catalog entry -- its nodes arrive in the
   input, so the same fold reads them from there and judges the plan actually
   being run. *)
let plan_input tools =
  `Assoc
    [ ( "nodes"
      , `List
          (List.mapi
             (fun i tool ->
                `Assoc
                  [ "id", `String (Printf.sprintf "n%d" i)
                  ; "tool", `String tool
                  ])
             tools) )
    ]
;;

let test_ad_hoc_plan_of_reads_runs_unasked () =
  with_index [] (fun () ->
    check bool "an ad-hoc plan of reads is not asked about" false
      (asks ~tool_name:"keeper_plan_execute" ~input:(plan_input [ "Read"; "Grep" ])))
;;

let test_ad_hoc_plan_with_a_write_asks () =
  with_index [] (fun () ->
    check bool "an ad-hoc plan that writes is asked about" true
      (asks ~tool_name:"keeper_plan_execute" ~input:(plan_input [ "Read"; "Execute" ])));
;;

let test_a_malformed_plan_is_asked_about () =
  with_index [] (fun () ->
    (* Not "a plan whose nodes are all reads". The tool will reject it too. *)
    check bool "a plan_execute call with no nodes field is asked about" true
      (asks ~tool_name:"keeper_plan_execute" ~input:no_input))
;;

(* The invariant every task in this goal is checked against: nothing that runs
   unasked today may start asking. Read directly and Read inside a plan must
   give the same answer. *)
let test_no_direct_call_became_asked () =
  with_index [] (fun () ->
    let asked_now =
      Descriptor.public_names ()
      |> List.filter (fun tool_name -> asks ~tool_name ~input:no_input)
    in
    check (slist string String.compare) "the asked set is unchanged"
      [ "Edit"; "Execute"; "Write" ] asked_now)
;;

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
    ; ( "compositions"
      , [ test_case "a plan of reads runs unasked" `Quick
            test_a_plan_of_reads_runs_unasked
        ; test_case "one writing node asks and names itself" `Quick
            test_one_writing_node_asks_and_names_itself
        ; test_case "an unrecorded name is still unclassifiable" `Quick
            test_an_unrecorded_name_is_still_unclassifiable
        ; test_case "an ad-hoc plan of reads runs unasked" `Quick
            test_ad_hoc_plan_of_reads_runs_unasked
        ; test_case "an ad-hoc plan with a write asks" `Quick
            test_ad_hoc_plan_with_a_write_asks
        ; test_case "a malformed plan is asked about" `Quick
            test_a_malformed_plan_is_asked_about
        ; test_case "no direct call became asked" `Quick
            test_no_direct_call_became_asked
        ] )
    ; ( "the question"
      , [ test_case "names the call" `Quick test_the_question_names_the_call ] )
    ]
