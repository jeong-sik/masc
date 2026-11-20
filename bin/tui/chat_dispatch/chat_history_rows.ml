(** Reconciliation of session-authored chat rows against loaded server
    transcript history and row-to-display-entry decoding. *)

module T = Masc_tui_types
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_history = Masc_tui_keeper_chat_history
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript

(* Rows this session wrote that the transcript now carries. Dropped so the same
   turn is not drawn twice, once from each source.

   A returned page proves replacement only for the rows it carries. A refresh
   started before the latest turn persisted must keep that session's output.

   Errors used to be kept on sight for the opposite reason. Most are notices
   the server has no row for -- a blocked dispatch, a refused read -- and
   dropping those loses the only record of them. A failed turn is
   the overlap the server does record, so it showed twice, which was the price
   of not being able to tell the two apart.

   The transcript can say which it is. The server persists a failed turn under
   the operation it ran, and that operation is the id this session dispatched
   under, so a session error row goes exactly when the transcript arrives
   carrying one for its request. Until then it stays -- a persist the server
   could not finish never produces that row, and the session keeps the only
   record, which is what keeping every error row was protecting. *)
let forget_session_rows_the_transcript_holds (state : T.state) keeper_name rows ~fresh =
  let user_turns_the_transcript_holds =
    List.filter_map
      (fun (row : Keeper_chat_history.row) ->
        match row.Keeper_chat_history.kind with
        | Keeper_chat_history.Addressed_to_keeper _ -> row.Keeper_chat_history.turn_id
        | Keeper_chat_history.Said_by_keeper
        | Keeper_chat_history.Autonomous_reply
        | Keeper_chat_history.Delivery_failed _
        | Keeper_chat_history.Tool_calls _
        | Keeper_chat_history.Skill_activity _
        | Keeper_chat_history.Reasoning _
        | Keeper_chat_history.Gate_activity _
        | Keeper_chat_history.Memory_activity _
        | Keeper_chat_history.Fusion_conclusion _ ->
            None)
      rows
  in
  let failures_the_transcript_holds =
    List.filter_map
      (fun (row : Keeper_chat_history.row) ->
        match row.Keeper_chat_history.kind with
        | Keeper_chat_history.Delivery_failed { origin_request_id; _ } ->
            origin_request_id
        | Keeper_chat_history.Addressed_to_keeper _
        | Keeper_chat_history.Said_by_keeper
        | Keeper_chat_history.Autonomous_reply
        | Keeper_chat_history.Tool_calls _
        | Keeper_chat_history.Skill_activity _
        | Keeper_chat_history.Reasoning _
        | Keeper_chat_history.Gate_activity _
        | Keeper_chat_history.Memory_activity _
        | Keeper_chat_history.Fusion_conclusion _ -> None)
      rows
  in
  state.msg_history <-
    List.filter
      (fun (entry : T.msg_entry) ->
        (not (String.equal entry.me_keeper_name keeper_name))
        ||
        match entry.me_role with
        (* Neither is in the transcript a refresh brings back -- the gate rows
           because the refresh does not carry them, this one because it never
           went to the server at all -- so both are kept. *)
        | T.Message_status | T.Message_local -> true
        | T.Message_error ->
            String.equal entry.me_request_id ""
            || not
                 (List.exists
                    (String.equal entry.me_request_id)
                    failures_the_transcript_holds)
        | T.Message_user _ ->
            (* Queue membership is not proof that a row reached the server,
               and leaving the queue is not proof either: the next request can
               enter [msg_inflight] before a transcript refresh started for the
               previous turn comes back. Replace this session row only when
               the exact request id is in the snapshot being applied. *)
            not
              (List.exists (String.equal entry.me_request_id)
                 user_turns_the_transcript_holds)
        | T.Message_keeper | T.Message_autonomous | T.Message_tool | T.Message_skill _
        | T.Message_thinking | T.Message_memory ->
            not (T.transcript_replaces_session_output ~fresh entry))
      state.msg_history

let locally_submitted_at (state : T.state) keeper_name request_id =
  List.find_map
    (fun (entry : T.msg_entry) ->
      match entry.me_role with
      | T.Message_user (T.Sent_by_operator _)
        when String.equal entry.me_keeper_name keeper_name
             && String.equal entry.me_request_id request_id ->
          entry.me_submitted_at
      (* [Sent_by_operator] is listed again because the arm above it is
         guarded: an operator row for another keeper or request falls through
         to here rather than matching that one. *)
      | T.Message_user (T.Sent_by_operator _ | T.Sent_by_other _)
      | T.Message_keeper | T.Message_autonomous
      | T.Message_status | T.Message_local | T.Message_error | T.Message_tool
      | T.Message_skill _ | T.Message_thinking
      | T.Message_memory -> None)
    (state.msg_history @ state.msg_loaded)
;;

let msg_entry_of_history_row (state : T.state) keeper_name ~operation_seq
    (row : Keeper_chat_history.row) =
  let gate =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Gate_activity { approval_id; phase; tool; summary } ->
        Some
          { T.gs_approval_id = approval_id
          ; gs_phase = phase
          ; gs_tool = tool
          ; gs_summary = summary
          }
    | Keeper_chat_history.Memory_activity _
    | Keeper_chat_history.Addressed_to_keeper _
    | Keeper_chat_history.Said_by_keeper
    | Keeper_chat_history.Autonomous_reply
    | Keeper_chat_history.Delivery_failed _
    | Keeper_chat_history.Tool_calls _
    | Keeper_chat_history.Skill_activity _
    | Keeper_chat_history.Reasoning _
    | Keeper_chat_history.Fusion_conclusion _ -> None
  in
  let memory_summary =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Memory_activity { summary; journal = _; pass = _ } -> summary
    | Keeper_chat_history.Gate_activity _
    | Keeper_chat_history.Addressed_to_keeper _
    | Keeper_chat_history.Said_by_keeper
    | Keeper_chat_history.Autonomous_reply
    | Keeper_chat_history.Delivery_failed _
    | Keeper_chat_history.Tool_calls _
    | Keeper_chat_history.Skill_activity _
    | Keeper_chat_history.Reasoning _
    | Keeper_chat_history.Fusion_conclusion _ ->
        None
  in
  let role, turn_phase, text, tool_block, skill_block =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Addressed_to_keeper { speaker; surface } ->
        (* The label is what the row draws; the speaker is what it is. Both
           come from the same decode, and only the label used to survive. *)
        let name, arrived_by =
          Keeper_chat_history.addressed_label_parts speaker surface
        in
        let author =
          match speaker with
          (* The operator's own name is never in doubt, but the door is: this
             row draws no arrival siding, so the surface is the only thing
             saying a line came in from a connector. Handed over apart, the
             column keeps it whenever it fits and drops it whole when it does
             not -- joined, the row kept neither. *)
          | Keeper_chat_history.Operator ->
              T.Sent_by_operator { surface = arrived_by }
          | Keeper_chat_history.Named _
          | Keeper_chat_history.Unresolved _ ->
              T.Sent_by_other { speaker = name; surface = arrived_by }
        in
        (T.Message_user author, T.Turn_input, row.Keeper_chat_history.text, None, [])
    | Keeper_chat_history.Said_by_keeper ->
        (T.Message_keeper, T.Turn_output, row.Keeper_chat_history.text, None, [])
    | Keeper_chat_history.Autonomous_reply ->
        (* The decoder no longer emits a blank autonomous reply, so there is
           nothing here to stand in for. *)
        (T.Message_autonomous, T.Turn_output, row.Keeper_chat_history.text, None, [])
    | Keeper_chat_history.Delivery_failed { recovered_at; _ } ->
        let text, recovered =
          match
            Keeper_chat_history.present_delivery_failure ?recovered_at row.Keeper_chat_history.text
          with
          | Some presented -> presented
          | None -> row.Keeper_chat_history.text, false
        in
        ( (if recovered then T.Message_status else T.Message_error)
        , T.Turn_output
        , text
        , None
        , [] )
    | Keeper_chat_history.Tool_calls block ->
        ( T.Message_tool
        , T.Turn_tool
        , String.concat "\n" (Keeper_chat_history.tool_rows block)
        , Some block
        , [] )
    | Keeper_chat_history.Skill_activity activities ->
        ( T.Message_skill (Keeper_chat_transcript.skill_block_state activities)
        , T.Turn_progress
        , String.concat "\n"
            (Keeper_chat_transcript.skill_rows
               ~ko:(state.ui_language = T.Lang_ko) ~full:false activities)
        , None
        , activities )
    | Keeper_chat_history.Reasoning lines ->
        (T.Message_thinking, T.Turn_progress, String.concat "\n" lines, None, [])
    | Keeper_chat_history.Gate_activity { approval_id = _; phase; tool; summary } ->
        (* Server-owned gate status, drawn from the phase rather than from
           the sentence the store composed. It is not Memory: putting it in
           that lane interleaved approvals with journal commits, and hiding
           the journal hid the gate with it. *)
        ( T.Message_status
        , T.Turn_progress
        , Masc_tui_gate_text.lifecycle_line_for
            ~ko:(state.ui_language = T.Lang_ko) ~phase ~tool ~summary
        , None
        , [] )
    | Keeper_chat_history.Memory_activity _ ->
        (T.Message_memory, T.Turn_progress, row.Keeper_chat_history.text, None, [])
    | Keeper_chat_history.Fusion_conclusion
        { fusion_run_id; fusion_board_post_id } ->
        (* A pointer row, not keeper speech: the conclusion text is the
           Said_by_keeper row it rides on, and this names the run whose
           panel/judge detail the Runs tab holds. Status, not Memory, so it
           keeps the Gate lane's non-journal slot. *)
        let pointer =
          match fusion_run_id with
          | Some run_id -> "run " ^ run_id
          | None -> "post " ^ fusion_board_post_id
        in
        ( T.Message_status
        , T.Turn_progress
        , Printf.sprintf
            (if state.ui_language = T.Lang_ko then "Fusion 합의 %s · 상세는 Runs 탭"
             else "Fusion deliberation %s · details in Runs tab")
            pointer
        , None
        , [] )
  in
  let submitted_at =
    match row.Keeper_chat_history.kind, row.Keeper_chat_history.turn_id with
    | Keeper_chat_history.Addressed_to_keeper _, Some request_id ->
        locally_submitted_at state keeper_name request_id
    | (Keeper_chat_history.Said_by_keeper
      | Keeper_chat_history.Autonomous_reply
      | Keeper_chat_history.Delivery_failed _
      | Keeper_chat_history.Tool_calls _
      | Keeper_chat_history.Skill_activity _
      | Keeper_chat_history.Reasoning _
      | Keeper_chat_history.Gate_activity _
      | Keeper_chat_history.Memory_activity _
      | Keeper_chat_history.Fusion_conclusion _), _
    | Keeper_chat_history.Addressed_to_keeper _, None -> None
  in
  (* Display metadata without pulling image bytes into every history page.
     The typed preview below is derived from the original text and refs. *)
  let text =
    Keeper_chat_history.text_with_attachments
      ~format_bytes:Masc_tui_context_inspector.format_bytes
      ~text:(Masc_tui_chat_media.append_text ~text row.Keeper_chat_history.media)
      ~notes:row.Keeper_chat_history.attachments
  in
  { T.me_role = role
  ; me_identity =
      (match row.Keeper_chat_history.structural_id with
       | Some id -> T.Persisted_row id
       | None ->
           T.Persisted_legacy_row
             { request_id = Option.value ~default:"" row.Keeper_chat_history.turn_id
             ; operation_seq
             })
  ; me_turn_phase = turn_phase
  ; me_turn_sequence = row.Keeper_chat_history.turn_sequence
  ; me_operation_seq = operation_seq
  ; me_text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text
  ; me_images = Masc_tui_image_preview.in_message_previews
      ~text:row.Keeper_chat_history.text
      ~attachments:(List.map (fun note -> note.Keeper_chat_history.att_image) row.Keeper_chat_history.attachments
        @ Masc_tui_chat_media.images row.Keeper_chat_history.media)
  ; me_media = row.Keeper_chat_history.media
  ; me_memory_summary =
      Option.map
        (Keeper_chat.terminal_safe_text ~preserve_newlines:false)
        memory_summary
  ; me_journal =
      (let safe = Keeper_chat.terminal_safe_text ~preserve_newlines:false in
       match row.Keeper_chat_history.kind with
       | Keeper_chat_history.Memory_activity { journal; summary = _; pass = _ } ->
           List.map
             (function
               | Masc_tui_message_layout.Journal_fact { sign; category; tone; claim } ->
                   Masc_tui_message_layout.Journal_fact
                     { sign; category = safe category; tone; claim = safe claim }
               | Masc_tui_message_layout.Journal_drop { memory_id; reason } ->
                   Masc_tui_message_layout.Journal_drop
                     { memory_id = safe memory_id; reason = safe reason })
             journal
       | Keeper_chat_history.Gate_activity _
       | Keeper_chat_history.Addressed_to_keeper _
       | Keeper_chat_history.Said_by_keeper
       | Keeper_chat_history.Autonomous_reply
       | Keeper_chat_history.Delivery_failed _
       | Keeper_chat_history.Tool_calls _
       | Keeper_chat_history.Skill_activity _
       | Keeper_chat_history.Reasoning _
       | Keeper_chat_history.Fusion_conclusion _ ->
           [])
  ; me_memory_pass =
      (match row.Keeper_chat_history.kind with
       | Keeper_chat_history.Memory_activity
           { pass = Masc_tui_message_layout.Pass_failed { kind }; summary = _; journal = _ } ->
           Masc_tui_message_layout.Pass_failed
             { kind = Keeper_chat.terminal_safe_text ~preserve_newlines:false kind }
       | Keeper_chat_history.Memory_activity
           { pass = (Masc_tui_message_layout.Pass_committed | Masc_tui_message_layout.No_pass) as pass
           ; summary = _
           ; journal = _
           } ->
           pass
       | Keeper_chat_history.Gate_activity _
       | Keeper_chat_history.Addressed_to_keeper _
       | Keeper_chat_history.Said_by_keeper
       | Keeper_chat_history.Autonomous_reply
       | Keeper_chat_history.Delivery_failed _
       | Keeper_chat_history.Tool_calls _
       | Keeper_chat_history.Skill_activity _
       | Keeper_chat_history.Reasoning _
       | Keeper_chat_history.Fusion_conclusion _ ->
           Masc_tui_message_layout.No_pass)
  ; me_gate = gate
  ; me_submitted_at = submitted_at
  ; me_tool_block = tool_block
  ; me_skill_block = skill_block
  ; me_keeper_name = keeper_name
  ; (* Direct rows retain their typed delivery key; autonomous rows retain the
       persisted turn_ref. Old rows and Memory journal entries carry neither,
       so the empty value continues to mean "no grouping authority". *)
    me_request_id = Option.value ~default:"" row.Keeper_chat_history.turn_id
  ; me_execution_source = row.Keeper_chat_history.execution_source
  ; me_at = row.Keeper_chat_history.at
  }

let msg_entries_of_history_rows (state : T.state) keeper_name rows =
  let next_by_request = Hashtbl.create 16 in
  List.map
    (fun (row : Keeper_chat_history.row) ->
      let request_id = Option.value ~default:"" row.Keeper_chat_history.turn_id in
      let operation_seq =
        Option.value ~default:0 (Hashtbl.find_opt next_by_request request_id)
      in
      Hashtbl.replace next_by_request request_id (operation_seq + 1);
      msg_entry_of_history_row state keeper_name ~operation_seq row)
    rows
;;
