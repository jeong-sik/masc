open Alcotest

module Policy = Masc.Keeper_tool_approval_policy
module Descriptor = Masc.Keeper_tool_descriptor

let asks ~tool_name ~input =
  match Policy.verdict_for ~identity_tool_index:Masc.Keeper_identity_tool_index.empty ~tool_name ~input with
  | Policy.Ask _ -> true
  | Policy.Run -> false

let because ~tool_name ~input =
  match
    Policy.verdict_for ~identity_tool_index:Masc.Keeper_identity_tool_index.empty ~tool_name ~input
  with
  | Policy.Ask { because } -> because
  | Policy.Run -> fail (tool_name ^ " ran; only an Ask carries a reason")

let no_input = `Assoc []

(* The catalogue itself, not a fixture. What matters is how the policy splits
   the tools a keeper actually has: a rule that reads well but puts Read on
   the asking side would make an operator stop reading the questions. *)
let test_the_split_over_the_real_catalogue () =
  let asked, ran =
    Descriptor.public_names ()
    |> List.partition (fun tool_name -> asks ~tool_name ~input:no_input)
  in
  check (slist string String.compare) "public tools requiring this chat approval hook"
    [] asked;
  (* This is the chat hook's split, not a proof that every Run is a read or
     already authorized by its executor. BrowserTabs/Read declare readonly;
     the other Browser descriptors declare ordered mutations without
     leaves_masc. Their handlers still validate lane, client and action
     context. Execute delegates to its execution Gate; Write/Edit delegate to
     their own resolved filesystem authorization. *)
  check (slist string String.compare) "public tools with no additional chat approval"
    [ "Execute"; "Edit"; "Write"; "Grep"; "Read"; "WebFetch"; "WebSearch"
    ; "BrowserTabs"; "BrowserRead"; "BrowserSession"; "BrowserGoto"
    ; "BrowserAct"; "BrowserInteract" ] ran

let test_reading_is_never_asked_about () =
  (* Reading to answer a question is the bulk of what a keeper does. *)
  check bool "reading a file" false
    (asks ~tool_name:"Read" ~input:(`Assoc [ "file_path", `String "a.ml" ]))

let test_writes_and_execute_delegate () =
  check bool "editing delegates to its resolved filesystem boundary" false
    (asks ~tool_name:"Edit" ~input:(`Assoc [ "file_path", `String "a.ml" ]));
  check bool "writing delegates to its resolved filesystem boundary" false
    (asks ~tool_name:"Write" ~input:(`Assoc [ "file_path", `String "a.ml" ]));
  check bool "running a program delegates to its execution Gate" false
    (asks ~tool_name:"Execute" ~input:(`Assoc [ "argv", `List [ `String "rm" ] ]))

let test_execute_delegates_whatever_its_input () =
  let cases =
    [ `Assoc [ "argv", `List [ `String "ls" ]; "cwd", `String "." ]
    ; `Assoc [ "argv", `List [ `String "rg"; `String "--pre=program"; `String "needle" ] ]
    ; `Assoc [ "command", `String "ls > listing.txt" ] ] in
  List.iter (fun input ->
      List.iter (fun tool_name ->
          check bool "one execution permission authority" false
            (asks ~tool_name ~input))
        [ "Execute"; "tool_execute" ]) cases

let test_an_unclassifiable_tool_is_asked_about () =
  (* An unknown tool is not a safe tool. If it ran unasked, "no descriptor"
     would be the quietest way past the gate. *)
  check bool "a tool no descriptor claims" true
    (asks ~tool_name:"not-a-real-tool" ~input:no_input);
  check string "and the reason names the gap"
    "no descriptor declares what this tool does"
    (because ~tool_name:"not-a-real-tool" ~input:no_input)

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


let test_no_direct_call_became_asked () =
  let asked_now =
    Descriptor.public_names ()
    |> List.filter (fun tool_name -> asks ~tool_name ~input:no_input)
  in
  check (slist string String.compare) "the asked set is unchanged"
    [] asked_now
;;

let test_an_in_process_write_runs () =
  List.iter
    (fun tool_name ->
       match
         Policy.verdict_for ~identity_tool_index:Masc.Keeper_identity_tool_index.empty
           ~tool_name
           ~input:no_input
       with
       | Policy.Run -> ()
       | Policy.Ask { because } ->
         failf "%s must run without asking, got Ask: %s" tool_name because)
    [ "keeper_memory_retract"; "keeper_memory_write" ]
;;

let test_internal_filesystem_name_delegates () =
  match Policy.verdict_for ~identity_tool_index:Masc.Keeper_identity_tool_index.empty
          ~tool_name:"tool_edit_file"
          ~input:(`Assoc [ "file_path", `String "lib/a.ml" ])
  with
  | Policy.Run -> ()
  | Policy.Ask { because } ->
    failf "tool_edit_file must reach its producer, got Ask: %s" because
;;

let () =
  run "keeper_tool_approval_policy"
    [ ( "the split"
      , [ test_case "over the real catalogue" `Quick
            test_the_split_over_the_real_catalogue
        ; test_case "reading is never asked about" `Quick
            test_reading_is_never_asked_about
        ; test_case "filesystem writes and Execute delegate" `Quick
            test_writes_and_execute_delegate
        ; test_case "Execute delegates whatever its input" `Quick
            test_execute_delegates_whatever_its_input
        ] )
    ; ( "unknowns"
      , [ test_case "an unclassifiable tool is asked about" `Quick
            test_an_unclassifiable_tool_is_asked_about
        ] )
    ; ( "in-process writes"
      , [ test_case "a write inside masc runs" `Quick
            test_an_in_process_write_runs
        ; test_case "internal filesystem alias delegates" `Quick
            test_internal_filesystem_name_delegates
        ; test_case "no direct call became asked" `Quick
            test_no_direct_call_became_asked
        ] )
    ; ( "the question"
      , [ test_case "names the call" `Quick test_the_question_names_the_call ] )
    ]
