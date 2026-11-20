module T = Masc_tui_types
module Chat_queue = Masc_tui_keeper_chat_queue
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Render_chat = Masc_tui_render_chat

let reset_message_file_changes (state : T.state) keeper_name =
  (* A late alpha response must not populate alpha after alpha -> beta ->
     alpha. Identity plus this generation is the cache authority. *)
  state.msg_file_changes_generation <- state.msg_file_changes_generation + 1;
  state.msg_file_changes <- None;
  state.msg_file_changes_keeper <- keeper_name;
  state.msg_file_changes_loading <- false;
  state.msg_file_changes_refresh_pending <- false;
  state.msg_file_changes_error <- None

(* [drain_queue] runs once the composer is aimed at [keeper_name]: a line the
   previous target's compose was holding ([composing_for_keeper]) is released
   by the retarget, and this is when it goes. Passed in because the drain is
   defined with the dispatch path, after this. *)
let forget_recall (state : T.state) =
  state.msg_command_menu <- Masc_tui_command.Menu_idle;
  state.msg_recall_walk <- None

let clear_keeper_history_projection (state : T.state) =
  T.retire_keeper_message_search state;
  state.msg_find_at <- None;
  state.msg_history_load_generation <- state.msg_history_load_generation + 1;
  state.msg_history_inflight <- None;
  state.msg_history_owed <- None;
  state.msg_copy_generation <- state.msg_copy_generation + 1;
  (* These readings belong to one conversation. Clear them at the shared
     target boundary before its replacement request can finish. *)
  T.set_keeper_chat_sources state T.empty_keeper_chat_sources;
  state.msg_loaded_keeper <- None;
  state.msg_loaded_error <- None;
  state.msg_loaded_dropped <- 0;
  state.msg_memory_error <- None;
  state.msg_memory_dropped <- 0;
  state.msg_older_cursor <- None;
  state.msg_older_exist <- false;
  state.msg_older_loading <- false;
  state.msg_older_error <- None

let open_message_for_keeper ?(return_to = T.Keeper_chat_return_detail)
    ?(remember_home_chat = true) (state : T.state) keeper_name ~drain_queue =
  T.retire_keeper_message_search state;
  state.keeper_navigation_open <- false;
  (* Save the placeholder and its spill together under this draft's owner. *)
  T.save_message_draft state;
  (* Re-entering the same Keeper is a fresh reading too: another process may
     have written files while this pane was elsewhere. Compact mode still
     performs no GET; it only invalidates this presentation cache. *)
  reset_message_file_changes state (Some keeper_name);
  (* Recall is a walk through one Keeper's messages. A Down on the new
     Keeper must not restore the previous Keeper's draft or image payload. *)
  forget_recall state;
  if state.msg_target_keeper_name <> Some keeper_name then begin
    state.msg_copy_generation <- state.msg_copy_generation + 1;
    (* A failed refresh after revisiting must retain the pages already read
       for this Keeper, including their exact paging cursor. *)
    T.restore_keeper_chat_page state keeper_name
  end;
  T.retarget_message state (Some keeper_name);
  if state.workspace_identity <> T.Workspace_identity_unread then
    state.msg_unconfirmed_workspace <- None;
  state.opening_notice <- None;
  (* Transfer draft ownership before starting the chat-visit effect, which can
     observe cancellation. The old Keeper's spill must never follow target. *)
  T.restore_message_draft state keeper_name;
  if remember_home_chat then (
    match Keeper_id.Keeper_name.of_string keeper_name with
    | Error reason ->
        Masc_tui_loader.add_event state "error"
          ("Could not remember chat target: " ^ reason)
    | Ok target ->
        if
          not
            (T.remember_local_chat_visit state
               ~sw:(Eio_context.get_switch_opt ())
               target)
        then
          Masc_tui_loader.report_action state "system"
            "Chat visit not saved to local Home: workspace is different or \
             unverified");
  state.msg_live <- T.live_for_keeper state keeper_name;
  state.msg_return <- return_to;
  state.keeper_message_focus <- T.Right_pane;
  T.select_keeper_name_with state.keepers state keeper_name;
  drain_queue ()

(* Leaving puts the draft away, and a line held only for that compose
   ([composing_for_keeper]) goes once the pane is gone: an idle keeper has no
   settle coming to send it, and the operator who left is not about to fold
   another line onto it. *)
let leave_keeper_message (state : T.state) ~drain_queue =
  state.keeper_navigation_open <- false;
  T.save_message_draft state;
  state.msg_history_inflight <- None;
  state.msg_history_owed <- None;
  let target_registered =
    match state.msg_target_keeper_name with
    | Some keeper_name -> T.keeper_available_for_new_message state keeper_name
    | None -> false
  in
  state.view <-
    (match (state.msg_return, target_registered) with
     | T.Keeper_chat_return_home, _ -> T.Overview
     | T.Keeper_chat_return_detail, true -> T.Keepers T.Keeper_detail
     | T.Keeper_chat_return_list, _ | T.Keeper_chat_return_detail, false ->
         T.Keepers T.Keeper_list);
  Option.iter (T.select_keeper_name state) state.msg_target_keeper_name;
  state.detail_scroll <- 0;
  if not target_registered then state.log_scroll <- 0;
  drain_queue ()

let clear_current_message_draft (state : T.state) =
  state.msg_command_menu <- Masc_tui_command.Menu_idle;
  Masc_tui_message_input.clear state.msg_input;
  Paste_spill.discard_recovered_paste_lock state;
  T.save_message_draft state

(* What this pane has of the operator's own lines for the keeper on screen,
   oldest first. The arrows walk it the way a shell walks its own history.
   That is why the wheel no longer arrives as the same key: one of the two had
   to be wrong while they shared it, and scrolling has the wheel and the page
   keys.

   Sent lines come from [msg_history], which is written when a line is
   dispatched. A line typed during a turn has not been dispatched, so it is
   not there -- it is in the queue, and it is the newest thing the operator
   typed. Walking only the sent ones stepped straight past it, which is how a
   queued line could be neither read back nor edited. *)
let own_typed_messages (state : T.state) =
  let target = Option.value ~default:"" state.msg_target_keeper_name in
  let sent =
    state.msg_history
    |> List.filter (fun (entry : T.msg_entry) ->
           (match entry.T.me_role with
            (* Asked of the type, not of the label. [String.equal label "you"]
               was false for the operator's own lines that came in on any
               surface but the dashboard -- those read "you · agent" --
               so the up-arrow recall silently skipped them. *)
            | T.Message_user (T.Sent_by_operator _) -> true
            | T.Message_user (T.Sent_by_other _) -> false
            | T.Message_keeper | T.Message_autonomous | T.Message_status
            | T.Message_local | T.Message_error | T.Message_tool
            | T.Message_skill _ | T.Message_thinking | T.Message_memory ->
                false)
           && String.equal entry.T.me_keeper_name target
           &&
           match
             Chat_queue.find state.msg_queued ~request_id:entry.T.me_request_id
           with
           | Some item
             when item.Chat_queue.intent = Chat_queue.Steer_after_interrupt
                  || item.Chat_queue.intent = Chat_queue.Steer_without_priority ->
               (* A steer is command intent, not ordinary chat text. Ctrl-P
                  edits the queued request; arrow recall skips its session row. *)
               false
           | Some _ | None -> true)
  in
  (* The queue is not walked here any more. A queued line enters the history
     when it is typed, not when it is dispatched, so it is already in [sent] --
     concatenating the queue would put the newest line in the walk twice. *)
  sent

let set_composer_text (state : T.state) text =
  state.msg_command_menu <- Masc_tui_command.Menu_idle;
  Masc_tui_message_input.clear state.msg_input;
  Masc_tui_message_input.insert state.msg_input text

let image_session_rows (state : T.state) =
  match state.msg_target_keeper_name with
  | None -> state.msg_history
  | Some keeper_name ->
      List.filter
        (fun (entry : T.msg_entry) ->
          String.equal entry.T.me_keeper_name keeper_name)
        state.msg_history

(* Image discovery includes queued messages and rows drawn by held turn logs.
   Those presentation filters must not remove an attachment from Ctrl-O. *)
let image_conversation_rows (state : T.state) =
  let loaded =
    match (state.msg_target_keeper_name, state.msg_loaded_keeper) with
    | Some keeper_name, Some loaded_keeper
      when String.equal keeper_name loaded_keeper ->
        state.msg_loaded
    | Some _, Some _ | Some _, None | None, _ -> []
  in
  T.chat_timeline ~loaded ~session:(image_session_rows state)
    ~queued_request_ids:[]
  |> T.chat_timeline_rows

(* Read the same selected execution sources as the renderer. Capture every
   current speech stretch, including ones with no preview yet: closing a fence
   can change a stretch in place. Thinking and superseded attempts never own
   the current conversation's preview. *)
let image_log_observations (state : T.state) =
  match state.msg_target_keeper_name with
  | None -> []
  | Some keeper_name ->
      T.selected_source_logs_for_keeper state keeper_name
      |> List.map (fun (log : T.turn_log) ->
             let items =
               Keeper_chat_transcript.drawn log.T.tl_transcript
               |> List.filter_map
                    (fun (item : Keeper_chat_transcript.drawn_item) ->
                      match
                        ( item.Keeper_chat_transcript.superseded
                        , item.Keeper_chat_transcript.drawn )
                      with
                      | ( None
                        , ( Keeper_chat_transcript.Drawn_text text
                          | Keeper_chat_transcript.Drawn_reply text ) ) ->
                          Some
                            ( item.Keeper_chat_transcript.origin
                            , Masc_tui_image_preview.in_message_previews ~text
                                ~attachments:[] )
                      | None, Keeper_chat_transcript.Drawn_media media ->
                          Some
                            ( item.Keeper_chat_transcript.origin
                            , Masc_tui_chat_media.images
                                [ Masc_tui_chat_media.of_generated media ] )
                      | Some _, _
                      | ( None
                        , ( Keeper_chat_transcript.Drawn_thinking _
                          | Keeper_chat_transcript.Drawn_skill _
                          | Keeper_chat_transcript.Drawn_tools _
                          | Keeper_chat_transcript.Drawn_status _
                          | Keeper_chat_transcript.Drawn_error _ ) ) ->
                          None)
             in
             (T.turn_log_execution_source log, items))

(* Source previews follow the pane's causal merge order, including held logs.
   The renderer's structural anchors recover the original producer data;
   labels, normalized bodies and rendered row positions are never identities. *)
let image_preview_candidates ~terminal_size (state : T.state) logs =
  let rows = image_conversation_rows state in
  match state.msg_target_keeper_name with
  | None -> []
  | Some keeper_name ->
      let _, cols = terminal_size () in
      let projection =
        Render_chat.keeper_message_projection state ~keeper_name ~chat_cols:cols
      in
      let projected =
        projection.Render_chat.tagged_entries
        |> List.filter_map (fun (tag, _) ->
               match Render_chat.search_anchor_of_tag tag with
               | Some (T.Search_history _ as anchor) -> (
                   (* The tagged row is the source-owned media remainder the
                      pane actually draws. Recovering the unfiltered history
                      row would put covered diagrams back into this catalog. *)
                   match Render_chat.message_of_tag tag with
                   | Some row -> (
                       match row.T.me_role with
                       | T.Message_thinking -> None
                       | T.Message_user _ | T.Message_keeper
                       | T.Message_autonomous | T.Message_status
                       | T.Message_local | T.Message_error | T.Message_tool
                       | T.Message_skill _ | T.Message_memory ->
                           Some (anchor, row.T.me_images))
                   | None -> None)
               | Some (T.Search_journal { source; origin; _ } as anchor) ->
                   Option.bind (List.assoc_opt source logs) (fun items ->
                       Option.map
                         (fun preview -> (anchor, preview))
                         (List.assoc_opt origin items))
               | Some (T.Search_child _ | T.Search_admission _) | None -> None)
      in
      (* Queued inputs are visible in the pending tail, outside tagged_entries.
         Keep their attachment actions while avoiding duplicate projected rows. *)
      let queued =
        rows
        |> List.filter_map (fun (row : T.msg_entry) ->
               match
                 ( Chat_queue.find state.msg_queued
                     ~request_id:row.T.me_request_id
                 , row.T.me_role )
               with
               | Some _, T.Message_user _ ->
                   let anchor = T.msg_anchor row in
                   if
                     List.exists
                       (fun (shown, _) ->
                         match shown with
                         | T.Search_history { row_anchor; _ } ->
                             row_anchor = anchor
                         | T.Search_child _ | T.Search_admission _
                         | T.Search_journal _ ->
                             false)
                       projected
                   then None
                   else
                     Some
                       ( T.Search_history
                           { row_anchor = anchor; reply_source = None }
                       , row.T.me_images )
               | ( Some _
                 , ( T.Message_keeper | T.Message_autonomous | T.Message_status
                   | T.Message_local | T.Message_error | T.Message_tool
                   | T.Message_skill _ | T.Message_thinking | T.Message_memory )
                 )
               | None, _ ->
                   None)
      in
      projected @ queued

(* History loading alone is not a new arrival. The staging observation travels
   with the draft and is invalidated by a workspace reconnect. *)
let note_attachment_staged (state : T.state) =
  state.msg_attachments_since <-
    Some
      { T.io_reading = state.workspace_read_authority
      ; io_keeper = state.msg_target_keeper_name
      ; io_history =
          (match List.rev (image_session_rows state) with
           | newest :: _ -> Some (T.msg_anchor newest)
           | [] -> None)
      ; io_logs = image_log_observations state
      }

let set_staged_media (state : T.state) ~attachments ~references ~since =
  Masc_tui_message_input.invalidate_revision state.msg_input;
  state.msg_attachments <- attachments;
  Masc_tui_message_input.invalidate_revision state.msg_input;
  state.msg_references <- references;
  state.msg_attachments_since <- since

(* The draft is put aside on the first step back and handed over on the way
   forward past the newest, so a walk through the history never costs what was
   already typed. *)
(* Land the walk on one line: its text into the composer, and whether that
   line is still waiting.

   Stepping onto a waiting line makes this an edit of it. The arrows copy, and
   a copy of a line that has not been sent yet would be sent twice -- the
   original from the queue and the copy from the composer. Recorded here and
   acted on at Enter, so the step itself stays what it always was: reversible,
   and costing nothing if the operator walks on past. *)
let recall_land (state : T.state) ~original entries at =
  let count = List.length entries in
  let entry = List.nth entries (count - 1 - at) in
  state.msg_recall_walk <-
    Some { T.krw_anchor = T.msg_anchor entry; krw_original = original };
  set_composer_text state entry.T.me_text;
  (match
     Chat_queue.find state.msg_queued ~request_id:entry.T.me_request_id
   with
   | Some item -> T.set_recall_edit state item
   | None -> T.clear_current_recall_edit state);
  (* A queued edit owns the complete request, not just its text. Never attach
     the draft's images to a different recalled line. *)
  let attachments, references =
    match T.current_recall_edit state with
    | Some item ->
        ( item.Chat_queue.request.Keeper_chat.attachments
        , item.Chat_queue.request.Keeper_chat.references )
    | None -> ([], [])
  in
  set_staged_media state ~attachments ~references ~since:None;
  if attachments <> [] then note_attachment_staged state

let recall_older (state : T.state) =
  let sent = own_typed_messages state in
  let count = List.length sent in
  if count > 0 then begin
    let at, original =
      match state.msg_recall_walk with
      | None ->
          (* A spill belongs to the draft being set aside, not to the
             recalled line that is about to replace the composer. *)
          let text =
            Paste_spill.materialise_spilled_paste state
              (Masc_tui_message_input.snapshot state.msg_input)
          in
          ( 0
          , ( text
            , state.msg_attachments
            , state.msg_references
            , state.msg_attachments_since ) )
      | Some walk ->
          ( (match T.recall_history_offset sent walk.T.krw_anchor with
             | Some at -> min (at + 1) (count - 1)
             | None -> 0)
          , walk.T.krw_original )
    in
    recall_land state ~original sent at
  end

let recall_newer (state : T.state) =
  match state.msg_recall_walk with
  | None -> ()
  | Some walk -> (
      let sent = own_typed_messages state in
      match T.recall_history_offset sent walk.T.krw_anchor with
      | Some at when at > 0 ->
          recall_land state ~original:walk.T.krw_original sent (at - 1)
      | Some _ | None ->
          (* Back at the operator's own draft: it is not an edit of anything. *)
          T.clear_current_recall_edit state;
          let text, attachments, references, since = walk.T.krw_original in
          forget_recall state;
          set_composer_text state text;
          set_staged_media state ~attachments ~references ~since)

let queued_edit_is_unchanged (state : T.state) (item : Chat_queue.item) =
  match
    Chat_queue.find state.msg_queued
      ~request_id:item.Chat_queue.request.Keeper_chat.request_id
  with
  | Some current ->
      current.Chat_queue.request = item.Chat_queue.request
      && current.Chat_queue.source = item.Chat_queue.source
  | None -> false

let composer_empty_for_queue_edit (state : T.state) =
  Option.is_none state.msg_recall_walk
  && Masc_tui_message_input.length state.msg_input = 0
  && state.msg_attachments = []
  && state.msg_references = []
  && Option.is_none state.msg_spill

let explain_queued_edit (state : T.state) =
  match T.current_recall_edit state with
  | Some item ->
      Masc_tui_loader.report_action state "system"
        (if Option.is_some state.msg_recall_walk then
           "Queued edit kept while browsing history."
         else if not (queued_edit_is_unchanged state item) then
           "Queued message changed or is gone · Ctrl-U: abandon (may send)"
         else if composer_empty_for_queue_edit state then
           "Ctrl-P: restore · Ctrl-U: abandon (may send)"
         else "Enter: replace · Ctrl-U: abandon (may send)")
  | None -> ()

(* A queued line is drawn in the conversation, so cancelling one or pulling it
   back into the composer has to take its row with it. The row is found by the
   request's own id and not by its text: two identical lines to one keeper are
   two requests, and dropping "the row that reads like this" would take
   whichever came first. *)
let forget_queued_history (state : T.state) (request : Keeper_chat.request) =
  state.keeper_interactive_waiting <-
    List.filter
      (fun (_, id, _) -> id <> request.Keeper_chat.request_id)
      state.keeper_interactive_waiting;
  state.msg_history <-
    List.filter
      (fun (entry : T.msg_entry) ->
        not
          (String.equal entry.T.me_request_id request.Keeper_chat.request_id
          &&
          match entry.T.me_role with
          | T.Message_user _ -> true
          | T.Message_keeper | T.Message_autonomous | T.Message_status
          | T.Message_local | T.Message_error | T.Message_tool
          | T.Message_skill _ | T.Message_thinking | T.Message_memory ->
              false))
      state.msg_history

let clear_staged_attachments (state : T.state) =
  set_staged_media state ~attachments:[] ~references:[] ~since:None

(* One unsent line leaves the local queue: its place there, the edit that was
   replacing it, and its row. Nothing was dispatched, so this is the whole
   cancel. [false] when the queue no longer holds it. Ctrl-K, /queue cancel ID
   and /queue clear all drop a line through here. *)
let drop_unsent_request (state : T.state) (request : Keeper_chat.request) =
  match
    Chat_queue.take state.msg_queued
      ~request_id:request.Keeper_chat.request_id
  with
  | None -> false
  | Some (_, rest) ->
      state.msg_queued <- rest;
      (match T.recall_edit_for_keeper state request.Keeper_chat.keeper_name with
       | Some editing
         when String.equal editing.Chat_queue.request.Keeper_chat.request_id
                request.Keeper_chat.request_id ->
           T.clear_recall_edit_for_keeper state request.Keeper_chat.keeper_name;
           if
             state.msg_target_keeper_name = Some request.Keeper_chat.keeper_name
           then clear_staged_attachments state
       | Some _ | None -> ());
      forget_queued_history state request;
      true

let load_queued_edit (state : T.state) (item : Chat_queue.item) =
  forget_recall state;
  let request = item.Chat_queue.request in
  T.set_recall_edit state item;
  set_staged_media state ~attachments:request.Keeper_chat.attachments
    ~references:request.Keeper_chat.references ~since:None;
  (* Recall makes this batch the current staged-image observation. *)
  if request.Keeper_chat.attachments <> [] then note_attachment_staged state;
  Masc_tui_message_input.clear state.msg_input;
  Masc_tui_message_input.insert state.msg_input request.Keeper_chat.message

(* Ctrl-P can restore an empty editor from its unchanged queued request. It
   cannot overwrite an edit or a draft saved beneath an active recall walk. *)
let edit_latest_queued_input (state : T.state) =
  match T.current_recall_edit state with
  | Some item ->
      if
        queued_edit_is_unchanged state item
        && composer_empty_for_queue_edit state
      then load_queued_edit state item
      else explain_queued_edit state
  | None -> (
      match
        Option.bind state.msg_target_keeper_name (fun keeper_name ->
            Chat_queue.take_newest_for_keeper state.msg_queued ~keeper_name)
      with
      | None -> ()
      | Some (item, _) ->
          if composer_empty_for_queue_edit state then
            load_queued_edit state item
          else
            Masc_tui_loader.report_action state "info"
              (if Option.is_some state.msg_recall_walk then
                 "Draft kept · leaving history may send queued input."
               else "Draft kept · sending or clearing it may send queued input."))

let move_recall (state : T.state) ~drain_queue move =
  if T.recall_navigation_blocked state then
    match T.current_recall_edit state with
    | Some item
      when queued_edit_is_unchanged state item
           && composer_empty_for_queue_edit state ->
        load_queued_edit state item
    | Some _ | None -> explain_queued_edit state
  else begin
    let was_editing = Option.is_some (T.current_recall_edit state) in
    move state;
    if was_editing && Option.is_none (T.current_recall_edit state) then
      drain_queue ()
  end

(* The chat pane's Enter: the draft goes to the keeper, the pane returns to
   the newest row, and a line held while the operator was composing may go
   too. Named because two things end a draft this way -- the Enter key on this
   surface, and a voice capture that ends the sentence itself
   ([voice.stt].send_on_stop) -- and they have to be the same answer. *)
let submit_chat_draft (state : T.state)
    ~(submit_message : Masc_tui_message_input.snapshot -> unit)
    ~(drain_queue : unit -> unit) =
  let snapshot = Masc_tui_message_input.snapshot state.msg_input in
  let text = Masc_tui_message_input.snapshot_text snapshot in
  if Paste_spill.recovered_paste_send_locked state then
    Masc_tui_loader.report_action state "system"
      "Recovered draft protected; press Ctrl-G to enable Enter"
  else if String.trim text <> "" then begin
    (* Back to the newest row: the turn that is about to start is drawn
       there, and staying scrolled back would hide the send. *)
    T.set_msg_scroll state 0;
    forget_recall state;
    submit_message snapshot;
    (* The composer is empty after a submit, so a line held only because the
       operator was mid-compose ([composing_for_keeper]) can dispatch now. When
       the submit folded onto that held line, this is what sends the merge. *)
    drain_queue ()
  end
