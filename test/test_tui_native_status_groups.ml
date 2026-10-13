(* The status clauses of a tool block's header: one per tool and provider
   report, with a count, not one per call. Grouping is on the typed values;
   the tests read groups and call the clause function rather than pin screen
   copy. *)
open Alcotest

module Transcript = Masc_tui_keeper_chat_transcript

let result_without_flag = { Runtime_native_tools.outcome = Result_received { is_error = None }; exit_code = None }
let result_not_error = { Runtime_native_tools.outcome = Result_received { is_error = Some false }; exit_code = None }
let result_error = { Runtime_native_tools.outcome = Result_received { is_error = Some true }; exit_code = None }

let ended ?completion name =
  Transcript.make_tool_activity ?native_completion:completion ~call_id:None ~tool_name:name ~args:""
    ~outcome:
      (match completion with
       | Some completion when
           (match completion.Runtime_native_tools.outcome with
            | Result_received { is_error = Some true } -> true
            | End_observed | Completion_unrecorded | Completion_reported | Error_reported
            | Decline_reported | Result_received _ | Unrecognized_status _ -> false) ->
           Transcript.Native_failed
       | Some _ | None -> Transcript.Native_ended)
    ~duration:None ()

let repeat count make = List.init count (fun _ -> make ())

let tool_of (group : Transcript.native_status_group) = group.status_tool
let calls_of (group : Transcript.native_status_group) = group.status_calls

let group_shape (group : Transcript.native_status_group) =
  group.status_tool, group.status_completion, group.status_calls

let shape_list =
  list (triple string (testable (fun fmt (completion : Runtime_native_tools.completion) ->
      Format.pp_print_string fmt (Transcript.native_completion_summary completion)) ( = )) int)

let tool_label name =
  match Transcript.group_native_statuses [ ended name ] with
  | [ group ] -> tool_of group
  | groups -> failf "expected one group, got %d" (List.length groups)

let test_no_activity_has_no_group () =
  check shape_list "empty" [] (List.map group_shape (Transcript.group_native_statuses []))

let test_one_call_reads_as_it_always_did () =
  match Transcript.group_native_statuses [ ended ~completion:result_without_flag "Execute" ] with
  | [ group ] ->
      check int "one call" 1 (calls_of group);
      check string "no count in the clause"
        (tool_label "Execute" ^ ": " ^ Transcript.native_completion_status result_without_flag)
        (Transcript.native_status_clause group)
  | groups -> failf "expected one group, got %d" (List.length groups)

let test_identical_calls_collapse_to_one_counted_clause () =
  let activities = repeat 13 (fun () -> ended ~completion:result_without_flag "Execute") in
  match Transcript.group_native_statuses activities with
  | [ group ] ->
      check int "count" 13 (calls_of group);
      check string "counted clause"
        (Printf.sprintf "%s x13: %s" (tool_label "Execute")
           (Transcript.native_completion_status result_without_flag))
        (Transcript.native_status_clause group)
  | groups -> failf "expected one group, got %d" (List.length groups)

let test_different_outcomes_stay_apart_in_order_of_first_appearance () =
  let shapes =
    Transcript.group_native_statuses
      [ ended ~completion:result_not_error "Execute"
      ; ended ~completion:result_without_flag "Execute"
      ; ended ~completion:result_not_error "Execute"
      ; ended ~completion:result_error "Execute"
      ; ended ~completion:result_without_flag "Execute" ]
    |> List.map group_shape
  in
  let execute = tool_label "Execute" in
  check shape_list "one group per distinct report"
    [ execute, result_not_error, 2; execute, result_without_flag, 2; execute, result_error, 1 ]
    shapes

let test_exit_code_is_part_of_the_key () =
  let with_exit code = { result_not_error with exit_code = code } in
  let shapes =
    Transcript.group_native_statuses
      [ ended ~completion:(with_exit (Some 0)) "Execute"
      ; ended ~completion:(with_exit (Some 1)) "Execute"
      ; ended ~completion:(with_exit None) "Execute"
      ; ended ~completion:(with_exit (Some 0)) "Execute" ]
    |> List.map group_shape
  in
  let execute = tool_label "Execute" in
  check shape_list "exit 0, exit 1 and no exit are three groups"
    [ execute, with_exit (Some 0), 2; execute, with_exit (Some 1), 1; execute, with_exit None, 1 ]
    shapes

let test_different_tools_stay_apart () =
  let shapes =
    Transcript.group_native_statuses
      [ ended ~completion:result_without_flag "Execute"
      ; ended ~completion:result_without_flag "Read"
      ; ended ~completion:result_without_flag "Execute"
      ; ended ~completion:result_without_flag "Search" ]
    |> List.map group_shape
  in
  check shape_list "first appearance order, counts per tool"
    [ tool_label "Execute", result_without_flag, 2
    ; tool_label "Read", result_without_flag, 1
    ; tool_label "Search", result_without_flag, 1 ]
    shapes

let test_an_ended_step_without_a_report_is_end_observed () =
  let shapes =
    Transcript.group_native_statuses [ ended "Read"; ended ~completion:Runtime_native_tools.end_observed "Read" ]
    |> List.map group_shape
  in
  check shape_list "same group" [ tool_label "Read", Runtime_native_tools.end_observed, 2 ] shapes

let test_unrecognized_status_words_share_a_clause () =
  let unrecognized word = { Runtime_native_tools.outcome = Unrecognized_status word; exit_code = None } in
  match
    Transcript.group_native_statuses
      [ ended ~completion:(unrecognized "alpha") "Read"; ended ~completion:(unrecognized "beta") "Read" ]
  with
  | [ group ] ->
      check int "both calls" 2 (calls_of group);
      check string "the clause is the generated wording, not the provider's word"
        (Printf.sprintf "%s x2: %s" (tool_label "Read")
           (Transcript.native_completion_status (unrecognized "")))
        (Transcript.native_status_clause group)
  | groups -> failf "expected one group, got %d" (List.length groups)

let test_steps_that_have_not_ended_belong_to_no_group () =
  let plain outcome =
    Transcript.make_tool_activity ~call_id:None ~tool_name:"Read" ~args:"" ~outcome ~duration:None ()
  in
  check shape_list "running, returned, failed"
    []
    (List.map group_shape
       (Transcript.group_native_statuses
          [ plain Transcript.Native_running; plain Transcript.Returned; plain Transcript.Failed
          ; plain Transcript.Started ]))

let count_occurrences ~needle haystack =
  let needle_length = String.length needle in
  let rec scan index total =
    if index + needle_length > String.length haystack then total
    else if String.sub haystack index needle_length = needle then scan (index + needle_length) (total + 1)
    else scan (index + 1) total
  in
  if needle_length = 0 then 0 else scan 0 0

let mixed_block () =
  repeat 13 (fun () -> ended ~completion:result_without_flag "Execute")
  @ [ ended ~completion:result_not_error "Read"; ended ~completion:result_not_error "Read"
    ; ended ~completion:result_without_flag "Search" ]

(* Both projections draw the header through the same clause function, so
   neither can keep drawing a clause per call while the other groups. *)
let test_compact_and_full_headers_draw_the_shared_clauses () =
  let activities = mixed_block () in
  let groups = Transcript.group_native_statuses activities in
  check int "three groups for sixteen calls" 3 (List.length groups);
  List.iter
    (fun mode ->
      let projection =
        Transcript.project_tool_block mode (Transcript.tool_block activities)
      in
      let header = match projection.Transcript.header with Some header -> header | None -> fail "no header" in
      List.iter
        (fun group ->
          let clause = Transcript.native_status_clause group in
          check int "each clause appears once in the header" 1 (count_occurrences ~needle:clause header))
        groups;
      check int "the status wording is drawn once per distinct report, not per call" 2
        (count_occurrences ~needle:(Transcript.native_completion_status result_without_flag) header))
    [ Transcript.Compact; Transcript.Full ]

(* A compact block of trouble calls gets a line of its own; that line goes
   through the same function. *)
let test_the_compact_trouble_row_groups_too () =
  let failing = { Runtime_native_tools.outcome = Error_reported; exit_code = None } in
  let activities =
    [ ended ~completion:result_without_flag "Read"; ended ~completion:result_without_flag "Read" ]
    @ [ Transcript.make_tool_activity ~call_id:None ~tool_name:"Execute" ~args:""
          ~outcome:Transcript.Native_failed ~native_completion:failing ~duration:None () ]
    @ [ Transcript.make_tool_activity ~call_id:None ~tool_name:"Execute" ~args:""
          ~outcome:Transcript.Native_failed ~native_completion:failing ~duration:None () ]
  in
  let projection = Transcript.project_tool_block Transcript.Compact (Transcript.tool_block activities) in
  let trouble = String.concat "\n" projection.Transcript.details in
  let failed_groups =
    Transcript.group_native_statuses
      (List.filter (fun (activity : Transcript.tool_activity) -> activity.outcome = Transcript.Native_failed)
         activities)
  in
  check int "one failed group" 1 (List.length failed_groups);
  List.iter
    (fun group ->
      check int "grouped clause once" 1
        (count_occurrences ~needle:(Transcript.native_status_clause group) trouble))
    failed_groups

let test_a_single_call_block_draws_no_header () =
  let projection =
    Transcript.project_tool_block Transcript.Compact
      (Transcript.tool_block [ ended ~completion:result_without_flag "Execute" ])
  in
  check (option string) "no header over one call" None projection.Transcript.header

let () =
  run "tui_native_status_groups"
    [ ( "grouping"
      , [ test_case "no activity" `Quick test_no_activity_has_no_group
        ; test_case "one call is unchanged" `Quick test_one_call_reads_as_it_always_did
        ; test_case "identical calls collapse" `Quick test_identical_calls_collapse_to_one_counted_clause
        ; test_case "different reports stay apart, in order" `Quick
            test_different_outcomes_stay_apart_in_order_of_first_appearance
        ; test_case "exit code is part of the key" `Quick test_exit_code_is_part_of_the_key
        ; test_case "different tools stay apart" `Quick test_different_tools_stay_apart
        ; test_case "no report reads as end observed" `Quick test_an_ended_step_without_a_report_is_end_observed
        ; test_case "unrecognized words share a clause" `Quick test_unrecognized_status_words_share_a_clause
        ; test_case "steps not ended are ungrouped" `Quick test_steps_that_have_not_ended_belong_to_no_group ] )
    ; ( "views"
      , [ test_case "compact and full share the clauses" `Quick
            test_compact_and_full_headers_draw_the_shared_clauses
        ; test_case "compact trouble row groups" `Quick test_the_compact_trouble_row_groups_too
        ; test_case "one call has no header" `Quick test_a_single_call_block_draws_no_header ] ) ]
