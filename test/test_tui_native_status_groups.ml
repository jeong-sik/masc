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
    [ execute, result_not_error, 2; execute, result_without_flag, 2
    ; execute, { result_error with outcome = Error_reported }, 1 ]
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

(* A later group may be the bigger one. Order is first appearance, not count. *)
let test_order_is_first_appearance_not_count () =
  let shapes =
    Transcript.group_native_statuses
      [ ended ~completion:result_not_error "Read"
      ; ended ~completion:result_not_error "Execute"
      ; ended ~completion:result_not_error "Execute"
      ; ended ~completion:result_not_error "Execute"
      ; ended ~completion:result_without_flag "Read" ]
    |> List.map group_shape
  in
  check shape_list "1, 3, 1 stays 1, 3, 1"
    [ tool_label "Read", result_not_error, 1
    ; tool_label "Execute", result_not_error, 3
    ; tool_label "Read", result_without_flag, 1 ]
    shapes

(* The key is the display name. [execute] and [Execute] are two wire names
   for one tool; the literal is stated here, not read back from the code. *)
let test_wire_names_with_one_display_name_share_a_group () =
  match
    Transcript.group_native_statuses
      [ ended ~completion:result_without_flag "execute"
      ; ended ~completion:result_without_flag "Execute" ]
  with
  | [ group ] ->
      check string "display name" "Execute" (tool_of group);
      check int "both calls" 2 (calls_of group)
  | groups -> failf "expected one group, got %d" (List.length groups)

let test_a_long_wire_name_keeps_the_display_name_of_the_clause () =
  match
    Transcript.group_native_statuses
      [ ended ~completion:result_without_flag "mcp_masc_execute"
      ; ended ~completion:result_without_flag "mcp_masc_execute" ]
  with
  | [ group ] ->
      check string "display name" "McpMascExecute" (tool_of group);
      check int "both calls" 2 (calls_of group)
  | groups -> failf "expected one group, got %d" (List.length groups)

(* Two typed reports that the header draws in the same words are one clause.
   Checked over every kind of report so a new one that reads like another
   cannot show up as two clauses with the same words. *)
let all_completions =
  let reports =
    [ Runtime_native_tools.End_observed; Completion_unrecorded; Completion_reported; Error_reported
    ; Decline_reported; Result_received { is_error = None }; Result_received { is_error = Some false }
    ; Result_received { is_error = Some true }; Unrecognized_status "alpha"; Unrecognized_status "beta" ]
  in
  List.concat_map
    (fun outcome ->
      List.map (fun exit_code -> { Runtime_native_tools.outcome; exit_code }) [ None; Some 0; Some 2 ])
    reports

let test_no_two_groups_draw_the_same_clause () =
  let clauses =
    Transcript.group_native_statuses (List.map (fun completion -> ended ~completion "Execute") all_completions)
    |> List.map Transcript.native_status_clause
  in
  check int "a clause is drawn once" (List.length clauses) (List.length (List.sort_uniq String.compare clauses))

let test_an_error_flag_and_an_error_report_share_a_clause () =
  match
    Transcript.group_native_statuses
      [ ended ~completion:result_error "Execute"
      ; ended ~completion:{ Runtime_native_tools.outcome = Error_reported; exit_code = None } "Execute"
      ; ended ~completion:result_error "Execute"
      ; ended ~completion:result_without_flag "Execute" ]
  with
  | [ errors; flagless ] ->
      check int "three error calls" 3 (calls_of errors);
      check int "one flagless call" 1 (calls_of flagless)
  | groups -> failf "expected two groups, got %d" (List.length groups)

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

(* Progress clauses *)
let progress ?output_bytes ?message ?provider_elapsed_seconds () =
  { Transcript.output_bytes; message; provider_elapsed_seconds; updated_at = 0.0; elapsed = None }

let reporting ?retry ?(outcome = Transcript.Native_running) name native_progress =
  Transcript.make_tool_activity ?native_progress ?native_retry:retry ~call_id:None ~tool_name:name ~args:""
    ~outcome ~duration:None ()

let progress_shape (group : Transcript.native_progress_group) = group.progress_tool, group.progress_calls

let progress_shape_list = list (pair string int)

let test_identical_progress_collapses_to_one_counted_clause () =
  let activities = repeat 13 (fun () -> reporting "mcp_masc_execute" (Some (progress ~output_bytes:10 ()))) in
  match Transcript.group_native_progress activities with
  | [ group ] ->
      check string "tool" "McpMascExecute" group.progress_tool;
      check int "count" 13 group.progress_calls;
      check string "counted clause" "McpMascExecute x13: output arriving"
        (Transcript.native_progress_clause group)
  | groups -> failf "expected one group, got %d" (List.length groups)

let test_one_progress_call_reads_as_it_always_did () =
  match Transcript.group_native_progress [ reporting "Read" (Some (progress ~output_bytes:10 ())) ] with
  | [ group ] -> check string "no count" "Read: output arriving" (Transcript.native_progress_clause group)
  | groups -> failf "expected one group, got %d" (List.length groups)

let test_progress_without_a_report_belongs_to_no_group () =
  check progress_shape_list "none" []
    (List.map progress_shape (Transcript.group_native_progress [ reporting "Read" None; ended "Read" ]))

let test_a_message_on_each_call_keeps_the_clauses_apart () =
  let shapes =
    Transcript.group_native_progress
      [ reporting "Read" (Some (progress ~message:"first" ()))
      ; reporting "Read" (Some (progress ~message:"second" ()))
      ; reporting "Read" (Some (progress ~message:"first" ())) ]
    |> List.map progress_shape
  in
  check progress_shape_list "two messages" [ "Read", 2; "Read", 1 ] shapes

let test_progress_order_is_first_appearance_not_count () =
  let shapes =
    Transcript.group_native_progress
      [ reporting "Read" (Some (progress ~output_bytes:1 ()))
      ; reporting "Execute" (Some (progress ~output_bytes:1 ()))
      ; reporting "Execute" (Some (progress ~output_bytes:1 ()))
      ; reporting "Execute" (Some (progress ~output_bytes:1 ()))
      ; reporting "Read" (Some (progress ~provider_elapsed_seconds:3 ())) ]
    |> List.map progress_shape
  in
  check progress_shape_list "1, 3, 1" [ "Read", 1; "Execute", 3; "Read", 1 ] shapes

let test_running_and_ended_progress_are_two_clauses () =
  let shapes =
    Transcript.group_native_progress
      [ reporting "Read" (Some (progress ~output_bytes:1 ()))
      ; reporting ~outcome:Transcript.Native_ended "Read" (Some (progress ~output_bytes:1 ())) ]
    |> List.map Transcript.native_progress_clause
  in
  check (list string) "arriving against observed" [ "Read: output arriving"; "Read: output observed" ] shapes

let test_the_heartbeat_seconds_are_part_of_the_key () =
  let shapes =
    Transcript.group_native_progress
      [ reporting "Read" (Some (progress ~provider_elapsed_seconds:3 ()))
      ; reporting "Read" (Some (progress ~provider_elapsed_seconds:4 ()))
      ; reporting "Read" (Some (progress ~provider_elapsed_seconds:3 ())) ]
    |> List.map progress_shape
  in
  check progress_shape_list "3s twice, 4s once" [ "Read", 2; "Read", 1 ] shapes

let retry_note ?(agent_id = "a1") attempt =
  Runtime_native_tools.Retry_reported
    { agent = { agent_id; subagent_type = "worker" }; attempt; max_retries = 3; retry_delay_ms = 500
    ; error_status = Some 429; error_category = "rate_limit" }

let test_retry_notices_group_by_what_the_clause_draws () =
  let shapes =
    Transcript.group_native_progress
      [ reporting ~retry:(retry_note ~agent_id:"a1" 1) "Read" None
      ; reporting ~retry:(retry_note ~agent_id:"a2" 1) "Read" None
      ; reporting ~retry:(retry_note ~agent_id:"a1" 2) "Read" None ]
    |> List.map progress_shape
  in
  check progress_shape_list "the agent id is not drawn, the attempt is" [ "Read", 2; "Read", 1 ] shapes

(* A retry notice reads "last observed" once the step is no longer running,
   so the same notice on a running and an ended step is two clauses. *)
let test_a_running_and_an_ended_retry_notice_are_two_clauses () =
  let groups =
    Transcript.group_native_progress
      [ reporting ~retry:(retry_note 1) "Read" None
      ; reporting ~outcome:Transcript.Native_ended ~retry:(retry_note 1) "Read" None ]
  in
  check progress_shape_list "two groups" [ "Read", 1; "Read", 1 ] (List.map progress_shape groups);
  match List.map Transcript.native_progress_clause groups with
  | [ running; ended ] -> check bool "the clauses differ" false (String.equal running ended)
  | clauses -> failf "expected two clauses, got %d" (List.length clauses)

let test_progress_groups_draw_distinct_clauses () =
  let clauses =
    Transcript.group_native_progress
      [ reporting "Read" (Some (progress ~message:"m" ()))
      ; reporting "Read" (Some (progress ~message:"m" ~output_bytes:5 ()))
      ; reporting "Read" (Some (progress ~message:"m" ~provider_elapsed_seconds:5 ()))
      ; reporting "Read" (Some (progress ~output_bytes:5 ()))
      ; reporting "Read" (Some (progress ()))
      ; reporting ~retry:(retry_note 1) "Read" (Some (progress ())) ]
    |> List.map Transcript.native_progress_clause
  in
  check int "message with output or elapsed is the message clause" 4
    (List.length (List.sort_uniq String.compare clauses))

let running_block () =
  repeat 13 (fun () -> reporting "mcp_masc_execute" (Some (progress ~output_bytes:10 ())))

(* The expanded view also lists one row per call, so only the header and,
   in the compact view, the trouble row are summaries. *)
let test_headers_draw_one_progress_clause () =
  let activities = running_block () in
  List.iter
    (fun (mode, summary_of) ->
      let projection = Transcript.project_tool_block mode (Transcript.tool_block activities) in
      let summary = summary_of projection in
      check int "the clause is drawn once" 1
        (count_occurrences ~needle:"McpMascExecute x13: output arriving" summary);
      check int "no per-call repeat" 1 (count_occurrences ~needle:"output arriving" summary))
    [ Transcript.Compact
    , (fun projection ->
        String.concat "\n" (Option.to_list projection.Transcript.header @ projection.Transcript.details))
    ; Transcript.Full, (fun projection -> String.concat "\n" (Option.to_list projection.Transcript.header)) ]

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
        ; test_case "order is first appearance, not count" `Quick test_order_is_first_appearance_not_count
        ; test_case "wire names with one display name" `Quick test_wire_names_with_one_display_name_share_a_group
        ; test_case "long wire name" `Quick test_a_long_wire_name_keeps_the_display_name_of_the_clause
        ; test_case "no two groups draw the same clause" `Quick test_no_two_groups_draw_the_same_clause
        ; test_case "error flag and error report share a clause" `Quick
            test_an_error_flag_and_an_error_report_share_a_clause
        ; test_case "no report reads as end observed" `Quick test_an_ended_step_without_a_report_is_end_observed
        ; test_case "unrecognized words share a clause" `Quick test_unrecognized_status_words_share_a_clause
        ; test_case "steps not ended are ungrouped" `Quick test_steps_that_have_not_ended_belong_to_no_group ] )
    ; ( "views"
      , [ test_case "compact and full share the clauses" `Quick
            test_compact_and_full_headers_draw_the_shared_clauses
        ; test_case "compact trouble row groups" `Quick test_the_compact_trouble_row_groups_too
        ; test_case "one call has no header" `Quick test_a_single_call_block_draws_no_header
        ; test_case "headers draw one progress clause" `Quick test_headers_draw_one_progress_clause ] )
    ; ( "progress"
      , [ test_case "identical progress collapses" `Quick test_identical_progress_collapses_to_one_counted_clause
        ; test_case "one call unchanged" `Quick test_one_progress_call_reads_as_it_always_did
        ; test_case "no report, no group" `Quick test_progress_without_a_report_belongs_to_no_group
        ; test_case "messages keep clauses apart" `Quick test_a_message_on_each_call_keeps_the_clauses_apart
        ; test_case "order is first appearance, not count" `Quick test_progress_order_is_first_appearance_not_count
        ; test_case "running and ended apart" `Quick test_running_and_ended_progress_are_two_clauses
        ; test_case "heartbeat seconds in the key" `Quick test_the_heartbeat_seconds_are_part_of_the_key
        ; test_case "retry groups by drawn fields" `Quick test_retry_notices_group_by_what_the_clause_draws
        ; test_case "running and ended retry notice" `Quick
            test_a_running_and_an_ended_retry_notice_are_two_clauses
        ; test_case "distinct clauses" `Quick test_progress_groups_draw_distinct_clauses ] ) ]
