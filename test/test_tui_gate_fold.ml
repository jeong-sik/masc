(* A run of Gate rows folds back into the one approval it describes. The store
   keeps a row per phase; drawn one row per phase, a single approval took four
   lines of the conversation pane and repeated the tool name on each. *)

open Masc.Keeper_chat_store
open Alcotest
module Types = Masc_tui_types
module Gate_text = Masc_tui_gate_text
module Layout = Masc_tui_message_layout

let contains haystack needle =
  let hay = String.length haystack and need = String.length needle in
  let rec scan at =
    if at + need > hay then false
    else if String.sub haystack at need = needle then true
    else scan (at + 1)
  in
  need = 0 || scan 0
;;

let entry ?gate role text =
  { Types.me_role = role
  ; me_identity =
      Types.Session_row
        { request_id = ""; turn_phase = Types.Turn_output; operation_seq = 0 }
  ; me_turn_phase = Types.Turn_output
  ; me_turn_sequence = None
  ; me_operation_seq = 0
  ; me_text = text
  ; me_image = Masc_tui_image_preview.No_image
  ; me_memory_summary = None
  ; me_gate = gate
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_activity = None
  ; me_timestamp = ""
  ; me_keeper_name = "k"
  ; me_request_id = ""
  ; me_at = 0.
  }

let step ?(approval = "appr_1") ?(tool = "Execute") ?(summary = None) phase =
  entry
    ~gate:
      { Types.gs_approval_id = approval
      ; gs_phase = phase
      ; gs_tool = Some tool
      ; gs_summary = summary
      }
    Types.Message_status
    (Gate_text.lifecycle_line ~phase ~tool:(Some tool) ~summary)

let said text = entry Types.Message_keeper text
let rows entries = List.map (fun e -> (e, ())) entries
let describe folded = List.map (fun (e, _) -> e.Types.me_text) folded
let fold entries = describe (Types.project_gate_history ~visibility:Types.Tools_compact (rows entries))

let test_one_approval_is_one_row () =
  check (list string) "the whole run says where the effect ended up"
    [ "미뤘던 호출 적용됨 · 턴 이어서 진행 · Execute · 4 steps · Ctrl-D" ]
    (fold
       [ step Approval_requested
       ; step Approval_resolved_approved
       ; step Approval_replay_applied
       ; step Approval_continuation_recorded
       ])

let test_the_summary_names_the_deferred_call () =
  (* Every step row of one approval carries the same summary, so the folded
     line says what was gated even though the request row itself is gone. *)
  let summary = Some "git reflog --date=iso | head -30" in
  check (list string) "the folded line keeps the call's own words"
    [ "미뤘던 호출 적용됨 · git reflog --date=iso | head -30 · 3 steps · Ctrl-D" ]
    (fold
       [ step ~tool:"tool_execute" ~summary Approval_requested
       ; step ~tool:"tool_execute" ~summary Approval_resolved_approved
       ; step ~tool:"tool_execute" ~summary Approval_replay_applied
       ])

let test_problems_remain_complete () =
  List.iter (fun phase ->
    let entries = [step Approval_requested; step Approval_resolved_approved;
      step phase; step Approval_continuation_recorded] in
    check (list string) "every problem phase remains visible"
      (describe (rows entries)) (fold entries))
    [Approval_replay_failed; Approval_replay_indeterminate;
     Approval_replay_applied_with_warning; Approval_resolved_rejected]

let test_corrections_keep_the_failure_history () =
  let entries = [step Approval_replay_failed; step Approval_replay_applied] in
  check (list string) "success cannot erase a preceding failure"
    (describe (rows entries)) (fold entries)

let test_unresolved_approval_remains_complete () =
  let entries = [step Approval_requested; said "verbatim answer";
    step Approval_resolved_approved; step Approval_continuation_recorded] in
  check (list string) "approval alone is not a successful effect"
    (describe (rows entries)) (fold entries)

let test_settled_steps_fold_across_prose () =
  let prose = said "Liveness: 그대로 보존\n\nnot a status, no substring rewrite" in
  let entries = rows [step Approval_requested; prose;
    step Approval_resolved_approved; step Approval_replay_applied] in
  let projected = Types.project_gate_history ~visibility:Types.Tools_compact entries in
  check (list string) "prose keeps its position before the settled outcome"
    [prose.me_text; "미뤘던 호출 적용됨 · Execute · 3 steps · Ctrl-D"]
    (describe projected);
  check bool "original prose record is untouched" true (fst (List.hd projected) == prose)

let test_full_restores_every_original_row () =
  let entries = rows [step Approval_requested; said "verbatim";
    step Approval_resolved_approved; step Approval_replay_applied] in
  let projected = Types.project_gate_history ~visibility:Types.Tools_full entries in
  check bool "Full returns raw timeline, including identity and clocks" true (projected == entries)

let test_identity_is_not_a_tool_name () =
  let entries = [step ~approval:"a" Approval_requested;
    step ~approval:"b" Approval_replay_applied] in
  check (list string) "matching tools cannot correlate different approvals"
    (describe (rows entries)) (fold entries);
  let entries = [step Approval_requested;
    { (step Approval_replay_applied) with me_keeper_name = "other" }] in
  check (list string) "keeper identity scopes approvals"
    (describe (rows entries)) (fold entries);
  let entries = [step ~approval:"" Approval_requested;
    step ~approval:"" Approval_replay_applied] in
  check (list string) "missing approval identity never folds"
    (describe (rows entries)) (fold entries)

let test_wait_after_success_is_not_settled () =
  let entries = [step Approval_replay_applied; step Approval_requested] in
  check (list string) "later unresolved phase remains visible"
    (describe (rows entries)) (fold entries)

let test_two_approvals_stay_two_rows () =
  check (list string) "back to back approvals do not merge"
    [ "미뤘던 호출 적용됨 · Execute · 2 steps · Ctrl-D"; "승인 거절 · Write" ]
    (fold
       [ step ~approval:"appr_1" Approval_resolved_approved
       ; step ~approval:"appr_1" Approval_replay_applied
       ; step ~approval:"appr_2" ~tool:"Write" Approval_resolved_rejected
       ])

let test_rows_that_are_not_gate_rows_are_untouched () =
  check (list string) "nothing else folds" [ "가"; "나" ] (fold [ said "가"; said "나" ])

(* The continuation says the turn resumed, which no outcome says. A run that
   holds only that fact -- the outcome rows are outside the loaded window --
   draws it as its whole line rather than folding to nothing. *)
let test_a_run_of_only_continuations_still_draws () =
  check (list string) "the continuation is the line"
    [ "턴 이어서 진행 · Execute" ]
    (fold [ step Approval_continuation_recorded ])

(* Cells, not bytes: a Korean status word is one cell wide per glyph and three
   bytes long, so a byte budget would fold a line that fits and leave one that
   does not. *)
let test_a_line_within_the_cap_comes_back_whole () =
  let line = "tool_execute \xc2\xb7 ls" in
  check string "unchanged" line ((Gate_text.fold_argument ~cap:40 line).Gate_text.fa_text)
;;

let test_a_long_argument_folds_and_says_how_much () =
  let argument = String.make 300 'x' in
  let line = "tool_execute \xc2\xb7 " ^ argument in
  let folded = (Gate_text.fold_argument ~cap:40 line).Gate_text.fa_text in
  check int "the fold fits the cap plus its tail" 40
    (Layout.display_width (Layout.take_cells folded 40));
  check bool "and names the cells it is holding" true
    (contains folded
       (Printf.sprintf "%d" (Layout.display_width line - 40)))
;;

(* Newlines are what made one argument eight rows. Flattened, the fold decides
   the height rather than the argument's own line breaks. *)
let test_newlines_are_flattened_before_the_cap_applies () =
  let line = "tool_execute \xc2\xb7 a\nb\nc" in
  let folded = (Gate_text.fold_argument ~cap:80 line).Gate_text.fa_text in
  check bool "no newline survives" false (String.contains folded '\n')
;;

(* Counted in cells so the count survives whatever width the pane wraps at.
   A count that changed with the pane would be describing the pane, not the
   text. *)
let test_the_held_count_does_not_depend_on_the_cap_being_a_row () =
  let line = "tool_execute \xc2\xb7 " ^ String.make 300 'x' in
  let held cap =
    Layout.display_width line - cap
  in
  List.iter
    (fun cap ->
      check bool
        (Printf.sprintf "cap %d names %d" cap (held cap))
        true
        (contains (Gate_text.fold_argument ~cap line).Gate_text.fa_text
           (Printf.sprintf "%d" (held cap))))
    [ 24; 40; 120 ]
;;

(* The caller decides whether a row can be pressed from this number, so it has
   to be zero exactly when nothing was folded. Comparing the text against the
   input instead would read the newline flattening as a fold. *)
let test_held_cells_is_zero_exactly_when_nothing_folded () =
  let short = "tool_execute \xc2\xb7 a\nb" in
  check int "a flattened line holds nothing" 0
    (Gate_text.fold_argument ~cap:80 short).Gate_text.fa_held_cells;
  let long = "tool_execute \xc2\xb7 " ^ String.make 300 'x' in
  check int "and a folded one holds the difference"
    (Layout.display_width long - 40)
    (Gate_text.fold_argument ~cap:40 long).Gate_text.fa_held_cells
;;

let () =
  run "tui_gate_fold"
    [ ( "fold"
      , [ test_case "one approval is one row" `Quick test_one_approval_is_one_row
        ; test_case "the summary names the deferred call" `Quick
            test_the_summary_names_the_deferred_call
        ; test_case "problems remain complete" `Quick test_problems_remain_complete
        ; test_case "corrections keep failure history" `Quick test_corrections_keep_the_failure_history
        ; test_case "unresolved approvals remain complete" `Quick test_unresolved_approval_remains_complete
        ; test_case "settled steps fold across prose" `Quick test_settled_steps_fold_across_prose
        ; test_case "Full restores every original row" `Quick test_full_restores_every_original_row
        ; test_case "identity is not a tool name" `Quick test_identity_is_not_a_tool_name
        ; test_case "wait after success is unresolved" `Quick test_wait_after_success_is_not_settled
        ; test_case "two approvals stay two rows" `Quick
            test_two_approvals_stay_two_rows
        ; test_case "rows that are not gate rows are untouched" `Quick
            test_rows_that_are_not_gate_rows_are_untouched
        ; test_case "a run of only continuations still draws" `Quick
            test_a_run_of_only_continuations_still_draws
        ] )
    ; ( "argument fold"
      , [ test_case "a line within the cap comes back whole" `Quick
            test_a_line_within_the_cap_comes_back_whole
        ; test_case "a long argument folds and says how much" `Quick
            test_a_long_argument_folds_and_says_how_much
        ; test_case "newlines are flattened before the cap applies" `Quick
            test_newlines_are_flattened_before_the_cap_applies
        ; test_case "the held count is in cells, not rows" `Quick
            test_the_held_count_does_not_depend_on_the_cap_being_a_row
        ; test_case "held cells is zero exactly when nothing folded" `Quick
            test_held_cells_is_zero_exactly_when_nothing_folded
        ] )
    ]
