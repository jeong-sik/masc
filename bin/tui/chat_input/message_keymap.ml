module T = Masc_tui_types
module Chat_queue = Masc_tui_keeper_chat_queue
module Keeper_chat = Masc_tui_keeper_chat_projection
module Composer = Masc_tui_composer
module Render_chat = Masc_tui_render_chat

(* One page of the transcript. Measured from the terminal rather than fixed,
   so the jump is a screenful on every window; a page smaller than the pane
   would leave rows the reader has to catch with the arrow keys anyway. *)
let keeper_message_page_rows ~terminal_size (state : T.state) =
  let rows, cols = terminal_size () in
  (* The pane's fixed chrome is shared with [render_keeper_message];
     composer growth is already inside [keeper_message_status_rows]. Adding
     composer_max_rows here counted it twice, and every PgUp jumped four
     rows short of the screenful the comment promises. *)
  let status_frame =
    Render_chat.keeper_message_viewport_frame state ~now:(Unix.gettimeofday ())
      ~terminal_rows:rows ~terminal_cols:cols
  in
  let status_rows = T.keeper_message_status_rows ~status_frame state in
  (* PgUp creates the reading-back notice and PgDn removes it. Reserve that
     possible row on both sides of the transition: using only the rows drawn
     right now made a 46-row pane move 38 up, then only 37 down, leaving the
     operator one row behind the live edge. One stable reserved budget also
     leaves a single context row overlapping adjacent pages. *)
  let page_status_rows =
    T.keeper_message_support_status_rows state ~status_rows
  in
  max 1
    (Masc_tui_message_layout.message_history_height ~terminal_rows:rows
       ~status_rows:page_status_rows)

let keeper_message_input_supported ~terminal_size (state : T.state) =
  let rows, cols = terminal_size () in
  let status_frame =
    Render_chat.keeper_message_viewport_frame state ~now:(Unix.gettimeofday ())
      ~terminal_rows:rows ~terminal_cols:cols
  in
  let status_rows = T.keeper_message_status_rows ~status_frame state in
  Masc_tui_message_layout.message_viewport_supported ~terminal_rows:rows
    ~terminal_cols:
      (Masc_tui_roster_pane.content_cols
         ~hidden:(T.roster_pane_hidden state)
         ~cols)
    ~status_rows:(T.keeper_message_support_status_rows state ~status_rows)

(** Handle local editing keys for message mode. Network submission is injected
    so the input path never owns a blocking HTTP effect. *)
let handle_message_key ~terminal_size ~wheel_notch_rows (state : T.state)
    ~(submit_message : Masc_tui_message_input.snapshot -> unit)
    ~(load_older : cursor:string option -> unit) ~(paste_image : unit -> unit)
    ~(open_named_image : unit -> unit) ~(inspect_context : unit -> unit)
    ~(inspect_queue : unit -> unit) ~(load_tool_changes : unit -> unit)
    ~(load_preparation : unit -> unit) ~(drain_queue : unit -> unit)
    ~(start_voice : unit -> unit) ~(toggle_voice_continuous : unit -> unit)
    (key : string) : bool =
  (* y and n answer a held call, and only while one is held -- otherwise they
     are letters someone is typing. The prompt on screen is what makes them
     mean anything, so it is also what decides whether they are taken. *)
  (* Moving back and asking for what is behind it are the same act. They were
     three separate copies of the same four lines and [pageup] was missing its
     copy, so a page-at-a-time reader stopped at whatever the first load
     happened to bring in (#31089). Going back through here means the request
     cannot be forgotten again. *)
  let scroll_back rows =
    T.step_msg_scroll_up state rows;
    if state.msg_older_exist && not state.msg_older_loading then
      load_older ~cursor:state.msg_older_cursor
  in
  let apply_autocomplete direction =
    let text = Masc_tui_message_input.contents state.msg_input in
    let keeper_names =
      List.map
        (fun (keeper : Masc.Tui_decode.keeper) ->
          keeper.Masc.Tui_decode.k_name)
        state.keepers
    in
    match Masc_tui_command.autocomplete ~direction ~keeper_names text with
    | Some completed ->
        Message_draft_recall.forget_recall state;
        Masc_tui_message_input.clear state.msg_input;
        Masc_tui_message_input.insert state.msg_input completed;
        true
    | None -> true
  in
  let slash_navigable () =
    let keeper_names =
      List.map
        (fun (keeper : Masc.Tui_decode.keeper) ->
          keeper.Masc.Tui_decode.k_name)
        state.keepers
    in
    Masc_tui_command.is_slash_navigable ~keeper_names
      (Masc_tui_message_input.contents state.msg_input)
  in
  let command_menu =
    let rows, cols = terminal_size () in
    let status_frame =
      lazy
        (Render_chat.keeper_message_viewport_frame state
           ~now:(Unix.gettimeofday ()) ~terminal_rows:rows ~terminal_cols:cols)
    in
    T.keeper_message_command_window ~status_frame state ~terminal_rows:rows
      ~terminal_cols:cols
    |> Option.map fst
  in
  let accept_command_menu menu =
    let completed = Masc_tui_command.menu_accept menu in
    Message_draft_recall.forget_recall state;
    Masc_tui_message_input.clear state.msg_input;
    Masc_tui_message_input.insert state.msg_input completed;
    state.msg_command_menu <- Masc_tui_command.Menu_dismissed completed;
    true
  in
  match key with
  (* Esc cancels the innermost thing, and a running capture is inside
     everything else here: the operator is mid-utterance, not mid-turn. ^Y
     stops one and keeps what was said, which is the common case; this is the
     other one, and without it there is no way to abandon a recording that
     picked up something the operator did not mean to send. *)
  | "esc" when Option.is_some state.voice_capture ->
      T.request_voice_stop state Masc.Voice_bridge.Discard;
      T.set_last_action state (Some ("voice: discarding", Unix.gettimeofday ()));
      true
  | "esc" when Option.is_some (T.current_recall_edit state) ->
      Message_draft_recall.forget_recall state;
      T.clear_current_recall_edit state;
      Message_draft_recall.clear_staged_attachments state;
      Masc_tui_message_input.clear state.msg_input;
      Paste_spill.discard_recovered_paste_lock state;
      drain_queue ();
      true
  | "down"
    when state.view = T.Keepers T.Keeper_message
         && not (keeper_message_input_supported ~terminal_size state) ->
      if state.msg_scroll > 0 then T.step_msg_scroll_down state 1;
      true
  | ("up" | "down" | "shift-tab") when Option.is_some command_menu ->
      Option.iter
        (fun menu ->
          let direction =
            if String.equal key "down" then Masc_tui_command.Next
            else Masc_tui_command.Prev
          in
          state.msg_command_menu <-
            Masc_tui_command.menu_step ~direction
              ~draft:(Masc_tui_message_input.contents state.msg_input)
              menu)
        command_menu;
      true
  | ("\t" | "\r") when Option.is_some command_menu -> (
      match command_menu with
      | Some menu -> accept_command_menu menu
      | None -> false)
  (* A visible menu consumes Esc before interrupting a turn or leaving chat. *)
  | "esc" when Option.is_some command_menu ->
      state.msg_command_menu <-
        Masc_tui_command.Menu_dismissed
          (Masc_tui_message_input.contents state.msg_input);
      true
  | key
    when String.equal key Masc_tui_keys.chat_schedules_key
         && state.view = T.Keepers T.Keeper_message ->
      state.msg_schedules_expanded <- not state.msg_schedules_expanded;
      true
  | "\t" -> apply_autocomplete Masc_tui_command.Next
  | "shift-tab" -> apply_autocomplete Masc_tui_command.Prev
  (* Esc follows RFC §3.1/§3.4 everywhere: close the innermost UI (command menu,
     voice capture) or leave chat without interrupting a running turn. Active
     turn interruption is separated onto Ctrl-C in the event loop. *)
  | "esc" ->
      Message_draft_recall.leave_keeper_message state ~drain_queue;
      true
  (* Q / Ctrl-Q also leave the chat and let the turn run, like Esc.
     Visible Q leaves an active turn only with a wholly empty draft. In a
     transcript-only viewport it leaves without editing hidden input. Ctrl-Q
     (byte 17) leaves regardless of the draft or turn state. *)
  | k
    when state.view = T.Keepers T.Keeper_message
         && state.keeper_message_focus = T.Right_pane
         && Option.is_none (T.current_recall_edit state)
         && Option.is_none state.voice_capture
         && Masc_tui_keys.chat_quiet_leave
              ~input_supported:
                (keeper_message_input_supported ~terminal_size state)
              ~turn_active:(T.keeper_message_turn_active state)
              ~draft_empty:(T.keeper_message_draft_empty state)
              k ->
      (* The surface guard is the point of this arm, not decoration.
         [handle_message_key] has a second caller -- the composer row on every
         other surface -- and this arm leaves the chat pane by changing
         [state.view]. Without the guard, Ctrl-Q typed into the composer row on
         Overview moved the reader to the Keeper detail it would have returned
         to; measured on a pty against the merged binary. Esc settles the
         innermost thing first, so a recall being replaced or a capture in
         flight keeps the key too. *)
      Message_draft_recall.leave_keeper_message state ~drain_queue;
      true
  | "\r" ->
      Message_draft_recall.submit_chat_draft state ~submit_message ~drain_queue;
      true
  (* The same two keys the composer row binds, because this surface has its own
     editor and never reaches that row: [handle_composer_key] is skipped
     outright while the view is Keeper_message. An operator who learned ^Y on
     one surface would otherwise find it dead on the one they type into most. *)
  | k when String.equal k Composer.listen_key ->
      start_voice ();
      true
  | k when String.equal k Composer.continuous_key ->
      toggle_voice_continuous ();
      true
  | "\n" | "shift-enter" ->
      (* Ctrl-J, Shift+Enter with enhanced keys, or Return on a terminal that
         still translates it. A composer that cannot hold two lines makes an
         operator send two messages for one thought. *)
      Message_draft_recall.forget_recall state;
      Masc_tui_message_input.insert_char state.msg_input '\n';
      true
  | "up" when state.msg_scroll > 0 ->
      scroll_back 1;
      true
  | "down" when state.msg_scroll > 0 ->
      T.step_msg_scroll_down state 1;
      true
  | "down" when slash_navigable () -> apply_autocomplete Masc_tui_command.Next
  | "up" when slash_navigable () -> apply_autocomplete Masc_tui_command.Prev
  | "up" ->
      Message_draft_recall.move_recall state ~drain_queue
        Message_draft_recall.recall_older;
      true
  | "down" ->
      Message_draft_recall.move_recall state ~drain_queue
        Message_draft_recall.recall_newer;
      true
  | "wheel-up" ->
      (* A notch is worth more than a row. The wheel used to arrive as the arrow
         key and moved one row with it, so reading back through a keeper turn --
         hundreds of rows -- took hundreds of notches. Three is what a terminal
         reports per detent, so a notch here covers what a notch covers
         everywhere else. *)
      scroll_back wheel_notch_rows;
      true
  | "wheel-down" ->
      T.step_msg_scroll_down state wheel_notch_rows;
      true
  | "pageup" ->
      (* A keeper's turn is many rows, so one row per press walks back through a
         single message. A page is the unit the reader actually moves in. *)
      scroll_back (keeper_message_page_rows ~terminal_size state);
      true
  | "pagedown" ->
      T.step_msg_scroll_down state (keeper_message_page_rows ~terminal_size state);
      true
  | "home" when state.view = T.Keepers T.Keeper_message ->
      T.jump_msg_scroll_oldest state;
      if state.msg_older_exist && not state.msg_older_loading then
        load_older ~cursor:state.msg_older_cursor;
      true
  | "end" ->
      T.set_msg_scroll state 0;
      true
  | "left" ->
      Masc_tui_message_input.move_left state.msg_input;
      true
  | "right" ->
      Masc_tui_message_input.move_right state.msg_input;
      true
  | "\127" | "\b" ->
      Message_draft_recall.forget_recall state;
      Masc_tui_message_input.backspace state.msg_input;
      if Masc_tui_message_input.length state.msg_input = 0 then drain_queue ();
      true
  | "\x17" | "alt-backspace" ->
      Message_draft_recall.forget_recall state;
      Masc_tui_message_input.delete_word state.msg_input;
      if Masc_tui_message_input.length state.msg_input = 0 then drain_queue ();
      true
  | s ->
      let c = if String.length s = 1 then Some (Char.code s.[0]) else None in
      (* Both of these keys say what they did. The same two stances reached
         through [/reasoning] and [/tools] answer with a notice, and reached
         through the key they answered with nothing -- so on a turn that holds
         no reasoning block and no tool call, the press changed a stance and
         moved not one cell. That reads as a dead key, and pressing it again to
         check puts the stance back where it started. The header names a stance
         only when it is away from its default ([chat_visibility_summary]), so
         it cannot stand in for this: returning to the default is exactly the
         press that clears the label. *)
      if c = Some 18 then begin
        (* Ctrl-R cycles the presentation only; transcript bytes stay intact. *)
        let visibility =
          T.next_reasoning_visibility state.msg_reasoning_visibility
        in
        state.msg_reasoning_visibility <- visibility;
        T.set_last_action state
          (Some
             ( "reasoning " ^ T.reasoning_visibility_to_string visibility
             , Unix.gettimeofday () ));
        true
      end
      else if c = Some 4 then begin
        (* Ctrl-D walks summary, results, and full per-call detail without
           changing the typed calls. *)
        let visibility = T.toggle_tool_visibility state.msg_tool_visibility in
        state.msg_tool_visibility <- visibility;
        if visibility <> T.Tools_compact then load_tool_changes ();
        T.set_last_action state
          (Some
             ( "tool calls " ^ T.tool_visibility_to_string visibility
             , Unix.gettimeofday () ));
        true
      end
      else if c = Some (Char.code Masc_tui_keys.expand_turn_key.[0]) then begin
        (* Ctrl-S folds the turn dashboard back to its progress line. Folded is
           where it starts; this is the key that asks for the rest. Saying what
           it did matters more here than elsewhere -- the fold changes how many
           rows the block below the conversation takes, and a reader who does
           not see a row appear has no other way to tell the key landed. *)
        state.msg_turn_folded <- not state.msg_turn_folded;
        if not state.msg_turn_folded then load_preparation ();
        T.set_last_action state
          (Some
             ( (if state.msg_turn_folded then "turn folded"
                else "turn expanded")
             , Unix.gettimeofday () ));
        true
      end
      else if c = Some 6 then begin
        (* Ctrl-F starts with the clock-free gutter, then adds an inline clock,
           then gives full timestamp/request metadata a row of its own. *)
        state.msg_origin_display <-
          T.next_origin_display state.msg_origin_display;
        true
      end
      else if c = Some 21 then begin
        (* Ctrl-U: clear the composer. The pasted text goes with it -- clearing
           is the operator saying they do not want what is there, and a spill
           that outlived it would attach to the next message. An edit of a
           waiting line is abandoned the same way: the line stays queued and the
           next Enter is a new line, not a replacement. *)
        state.msg_spill <- None;
        Message_draft_recall.forget_recall state;
        Message_draft_recall.clear_staged_attachments state;
        if Option.is_some (T.current_recall_edit state) then begin
          T.clear_current_recall_edit state;
          drain_queue ()
        end;
        Masc_tui_message_input.clear state.msg_input;
        Paste_spill.discard_recovered_paste_lock state;
        (* Cleared composer: release any line held only for this keeper's compose
           ([composing_for_keeper]). *)
        drain_queue ();
        true
      end
      else if c = Some 5 then begin
        (* Ctrl-E: back to the newest row. Scrolling down one row at a time from
           far back is worse than a key that ends the trip. *)
        T.set_msg_scroll state 0;
        true
      end
      else if c = Some 14 then begin
        (* Ctrl-N walks the Librarian/Memory journal lane through summary,
           full, and hidden, same as /memory. Ctrl-M would read better for
           memory, but that byte is the carriage return. *)
        state.msg_memory_visibility <-
          T.next_memory_visibility state.msg_memory_visibility;
        true
      end
      else if c = Some 11 then begin
        (* Ctrl-K: drop the newest waiting line without sending it. The queue
           shows what waits in the order it will go; the newest is the one a
           mis-send just hit, and dropping it is local — nothing was
           dispatched. *)
        (match
           Option.bind state.msg_target_keeper_name (fun keeper_name ->
               Chat_queue.take_newest_for_keeper state.msg_queued ~keeper_name)
         with
         | None -> () (* nothing waits; consume quietly like Ctrl-U on empty *)
         | Some (item, _) ->
             let request = item.Chat_queue.request in
             if Message_draft_recall.drop_unsent_request state request then begin
               Masc_tui_loader.report_action state "info"
                 (Printf.sprintf "Cancelled queued message to %s"
                    (Keeper_chat.terminal_safe_text
                       request.Keeper_chat.keeper_name));
               drain_queue ()
             end);
        true
      end
      else if c = Some 16 then begin
        (* Ctrl-P: pull the newest waiting line back into the composer. That is
           the edit: fix it and Enter queues it again. *)
        Message_draft_recall.edit_latest_queued_input state;
        true
      end
      else if c = Some 22 then begin
        (* Ctrl-V: the clipboard's image, staged for the next message. The key
           reaches here only because [Masc_tui_termios.reclaim]
           turned off VLNEXT -- with the terminal's default the tty layer eats
           this byte and passes the next one through raw, so the composer would
           see the letter after Ctrl-V and never Ctrl-V itself. *)
        paste_image ();
        true
      end
      else if c = Some (Char.code Masc_tui_keys.context_inspector_key.[0]) then
        begin
          (* Ctrl-X: the breakdown behind the figure in the header. The header
             names this key beside the number, so the place that shows how full
             the context is is also the place that opens what filled it. *)
          inspect_context ();
          true
        end
      else if c = Some 15 then begin
        (* Ctrl-O: look at the picture this conversation last named -- or, when
           it named none, the newest image staged for the next message, drawn
           from the bytes the composer is already holding. The path is already
           on screen -- the point is not having to retype it into /image, which
           on a nested evidence path is most of the work. *)
        open_named_image ();
        true
      end
      else if c = Some 20 then begin
        (* Ctrl-T: inspect full queue modal without having to type /queue *)
        inspect_queue ();
        true
      end
      else if Masc_tui_message_layout.is_printable_utf8_scalar s then begin
        Message_draft_recall.forget_recall state;
        Masc_tui_message_input.insert state.msg_input s;
        true
      end
      else true (* Consume but ignore other control chars *)
