let notice (state : Masc_tui_types.state) ~key =
  let queued =
    List.fold_left
      (fun count (_, (held : Masc_tui_types.suspended_keeper_input)) ->
        count + Masc_tui_keeper_chat_queue.length held.ski_queue)
      (Masc_tui_keeper_chat_queue.length state.msg_queued)
      state.suspended_keeper_inputs
  in
  let waiting, sending =
    List.fold_left
      (fun (waiting, sending) (entry : Masc_tui_types.inflight) ->
        match entry.phase with
        | Masc_tui_types.Turn_preflight _ -> (waiting + 1, sending)
        | Masc_tui_types.Turn_streaming | Masc_tui_types.Turn_reconciling -> (waiting, sending + 1))
      (queued, 0) state.msg_inflight
  in
  let unconfirmed_save =
    List.exists
      (fun draft ->
        match Masc_tui_code_draft.phase draft with
        | Masc_tui_code_draft.Saving _
        | Masc_tui_code_draft.Needs_review (Masc_tui_code_draft.Uncertain _, _) -> true
        | Masc_tui_code_draft.Editable | Masc_tui_code_draft.Rejected _
        | Masc_tui_code_draft.Kept_back _
        | Masc_tui_code_draft.Needs_review (Masc_tui_code_draft.Conflict _, _) -> false)
      state.code_drafts
  in
  let chat_draft =
    not (Masc_tui_types.keeper_message_draft_empty state) || state.msg_drafts <> []
  in
  let loss =
    match chat_draft, state.code_drafts <> [] with
    | true, true -> "chat/Code/other drafts"
    | true, false -> "chat/other drafts"
    | false, true -> "Code/other drafts"
    | false, false -> "unsaved work"
  in
  let details = if waiting > 0 then Printf.sprintf " +%d unsent" waiting else "" in
  let pending =
    match sending > 0, unconfirmed_save with
    | true, true -> "; send/save may run"
    | true, false -> "; send may run"
    | false, true -> "; save may run"
    | false, false -> ""
  in
  Printf.sprintf "Quit loses %s%s%s; %s again" loss details pending key

let arm (state : Masc_tui_types.state) ~kind ~key =
  match Masc_tui_ansi.probe_terminal_size () with
  | Some (rows, cols) when rows > 0 && cols > 0 ->
      Masc_tui_loader.report_action state "system" (notice state ~key);
      state.quit_armed <-
        Option.map
          (fun ordinary ->
            { Masc_tui_types.qa_confirmation = Masc_tui_action_notice.arm_quit ~kind ~ordinary
            ; qa_composer_revision = Masc_tui_message_input.revision state.msg_input
            ; qa_attachments = state.msg_attachments
            ; qa_references = state.msg_references
            ; qa_drafts = state.msg_drafts
            ; qa_queue = state.msg_queued
            ; qa_suspended = state.suspended_keeper_inputs
            ; qa_inflight = Masc_tui_types.quit_inflight_snapshot state
            ; qa_code_drafts = state.code_drafts
            ; qa_target = state.msg_target_keeper_name
            ; qa_workspace = state.workspace_authority
            })
          (Masc_tui_action_notice.ordinary state.last_action)
  | None | Some (_, _) ->
      state.quit_armed <- None;
      Masc_tui_loader.report_action state "error"
        "Cannot confirm quit: terminal size unavailable; resize or reconnect"

let withdraw (state : Masc_tui_types.state) =
  (match state.quit_armed, Masc_tui_action_notice.ordinary state.last_action with
   | Some arm, Some ordinary
     when ordinary == Masc_tui_action_notice.quit_ordinary arm.qa_confirmation ->
       Masc_tui_types.set_last_action state None
   | (Some _ | None), (Some _ | None) -> ());
  state.quit_armed <- None
