(* A run of Gate rows folds back into the one approval it describes. The store
   keeps a row per phase; drawn one row per phase, a single approval took four
   lines of the conversation pane and repeated the tool name on each. *)

open Keeper_approval_lifecycle
open Alcotest
module Types = Masc_tui_types
module Gate_text = Masc_tui_gate_text
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
  ; me_images = []
  ; me_media = []
  ; me_memory_summary = None
  ; me_journal = []
  ; me_memory_pass = Masc_tui_message_layout.No_pass
  ; me_gate = gate
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_block = []
  ; me_timestamp = ""
  ; me_keeper_name = "k"
  ; me_request_id = ""
  ; me_execution_source = None
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
    [prose.me_text; "미뤘던 호출 적용됨 · Execute · 3 steps · Ctrl-D×2"]
    (describe projected);
  check bool "original prose record is untouched" true (fst (List.hd projected) == prose)

let test_full_restores_every_original_row () =
  let entries = rows [step Approval_requested; said "verbatim";
    step Approval_resolved_approved; step Approval_replay_applied] in
  let projected = Types.project_gate_history ~visibility:Types.Tools_full entries in
  check bool "Full returns raw timeline, including identity and clocks" true (projected == entries)

let test_results_keeps_gate_rows_folded () =
  let entries = rows [step Approval_requested; step Approval_resolved_approved;
    step Approval_replay_applied] in
  check (list string) "short results keep the compact Gate history"
    [ "미뤘던 호출 적용됨 · Execute · 3 steps · Ctrl-D" ]
    (describe (Types.project_gate_history ~visibility:Types.Tools_results entries));
  let opened = Types.toggle_tool_visibility Types.Tools_results in
  check string "Ctrl-D opens Gate detail from results" "full"
    (Types.tool_visibility_to_string opened);
  check bool "the opened Gate history restores its rows" true
    (Types.project_gate_history ~visibility:opened entries == entries)

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

let test_rows_that_are_not_gate_rows_are_untouched () =
  check (list string) "nothing else folds" [ "가"; "나" ] (fold [ said "가"; said "나" ])

let test_narrow_chat_notice_has_no_old_row_action () =
  let module Render = Masc_tui_render_chat in
  let module Actions = Masc_tui_chat_row_actions in
  let cache = Masc_tui_ansi.terminal_size_cache in
  let previous_size = Masc_tui_ansi.get_terminal_size () in
  let previous_reserved = !(Masc_tui_render_prim.acting_pane_reserved_cols) in
  let set_size size = ignore (Masc_tui_render_schedule.Terminal_size_cache.refresh
      cache ~probe:(fun () -> Some size)) in
  Fun.protect
    ~finally:(fun () -> set_size previous_size;
      Masc_tui_render_prim.acting_pane_reserved_cols := previous_reserved)
    (fun () ->
      Masc_tui_render_prim.acting_pane_reserved_cols := 0;
      let state = Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
      state.view <- Types.Keepers Types.Keeper_message;
      state.msg_target_keeper_name <- Some "k";
      state.msg_tool_visibility <- Types.Tools_compact;
      state.msg_history <- [step ~summary:(Some (String.make 300 'x')) Approval_requested];
      let scope = state.workspace_authority, state.workspace_read_authority in
      let has_action candidate =
        List.exists (fun row -> Actions.contains ~same_scope:Types.same_acting_pane_scope
          ~scope ~keeper:(Some "k") ~row candidate) (List.init 30 (fun i -> i + 1))
      in
      set_size (30, 100);
      ignore (Render.render_keeper_message state);
      check bool "the folded Gate row has an action" true (has_action (Render.chat_row_actions ()));
      set_size (30, 20);
      ignore (Render.render_keeper_message state);
      check bool "the narrow notice has no retained row action" false (has_action (Render.chat_row_actions ()));
      state.msg_tool_visibility <- Types.Tools_results;
      let rec first_supported height =
        if height > 30 then fail "no supported height for the Gate fixture";
        set_size (height, 100);
        let frame, _ = Render.render_keeper_message state in
        if List.exists (fun line -> contains line "Keeper chat needs a larger terminal")
             frame.Masc_tui_frame_presenter.lines
        then first_supported (height + 1)
        else height
      in
      let minimum = first_supported 11 in
      set_size (30, 100);
      ignore (Render.render_keeper_message state);
      check bool "the supported results view has a folded action" true
        (has_action (Render.chat_row_actions ()));
      state.keeper_calls_keeper <- Some "k";
      state.keeper_calls_error <- Some "test refresh failure";
      set_size (minimum, 100);
      let frame, _ = Render.render_keeper_message state in
      check bool "warning rows make an insufficient-height viewport show a notice" true
        (List.exists (fun line -> contains line "Keeper chat needs a larger terminal")
          frame.Masc_tui_frame_presenter.lines);
      check bool "the notice retires the previous Gate action" false
        (has_action (Render.chat_row_actions ())))

(* #32956: the turn that received the replay failed after the model answered.
   The run is not folded: the failed step stays its own row so it is seen. *)
let test_a_failed_continuation_keeps_the_run_open () =
  let entries =
    [ step Approval_requested
    ; step Approval_resolved_approved
    ; step Approval_replay_applied
    ; step Approval_continuation_failed
    ]
  in
  check (list string) "a failed continuation is not folded away"
    (describe (rows entries)) (fold entries)

let () =
  run "tui_gate_fold"
    [ ( "fold"
      , [ test_case "problems remain complete" `Quick test_problems_remain_complete
        ; test_case "corrections keep failure history" `Quick test_corrections_keep_the_failure_history
        ; test_case "unresolved approvals remain complete" `Quick test_unresolved_approval_remains_complete
        ; test_case "settled steps fold across prose" `Quick test_settled_steps_fold_across_prose
        ; test_case "Full restores every original row" `Quick test_full_restores_every_original_row
        ; test_case "results keeps Gate history folded" `Quick
            test_results_keeps_gate_rows_folded
        ; test_case "identity is not a tool name" `Quick test_identity_is_not_a_tool_name
        ; test_case "wait after success is unresolved" `Quick test_wait_after_success_is_not_settled
        ; test_case "rows that are not gate rows are untouched" `Quick
            test_rows_that_are_not_gate_rows_are_untouched
        ; test_case "narrow chat notice has no old row action" `Quick
            test_narrow_chat_notice_has_no_old_row_action
        ; test_case "a failed continuation keeps the run open" `Quick
            test_a_failed_continuation_keeps_the_run_open
        ] )
    ; ( "argument fold"
      , [] )
    ]
