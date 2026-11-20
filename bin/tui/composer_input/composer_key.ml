module T = Masc_tui_types
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection

(* Apply one keystroke the composer claimed. Sending routes through the same
   chat surface the [c] key opens, so a message typed on the roster and one
   typed in the chat view take the identical dispatch path. *)
let handle_composer_key
    ~terminal_size
    ~wheel_notch_rows
    ~withdraw_resource_diagram_pending
    ~launch_keeper_history_load
    ~send_operator_text
    ~paste_clipboard_image
    ~open_named_image
    ~launch_keeper_chat_tool_details_load
    (state : T.state) ~base_path ~mailbox key =
  if state.T.view = T.Overview || state.T.workspace_identity <> T.Workspace_identity_match
     || Option.is_some (T.browser_lane_on_screen state)
  then false
  else
  match Composer_projection.classify_key state key with
  | Composer.Pass_to_surface -> false
  | Composer.Take_focus keeper_name ->
      Composer_focus.apply_take_focus state ~base_path ~mailbox keeper_name;
      true
  | Composer.Start_listening keeper_name ->
      (* Pressing it while continuous mode is on turns the mode off. That is
         the only way out: a mode that re-arms itself needs a key that stops
         it, and the key that started it is the one the operator will reach
         for. *)
      (match state.T.voice_continuous with
       | Some _ ->
           state.T.voice_continuous <- None;
           state.T.voice_floor <- None;
           T.set_last_action state (Some ("voice: continuous off", Unix.gettimeofday ()))
       | None ->
      (* One capture at a time: a second microphone would contend for the same
         input device and the two transcripts would race into one draft.

         The second press stops the running one, which is what the row has
         been telling the operator it does. It used to start another instead,
         leaving two recorders on one device with no way to end either. *)
      (match state.T.voice_capture with
       | Some _ ->
           T.request_voice_stop state Masc.Voice_bridge.Keep_what_was_heard;
           T.set_last_action state (Some ("voice: stopping", Unix.gettimeofday ()))
       | None -> Masc_tui_operator_actions.Voice_actions.launch_voice_capture state ~mailbox ~keeper:keeper_name));
      true
  | Composer.Toggle_continuous keeper_name ->
      (match state.T.voice_continuous with
       | Some _ ->
           state.T.voice_continuous <- None;
           state.T.voice_floor <- None;
           T.set_last_action state (Some ("voice: continuous off", Unix.gettimeofday ()))
       | None when Option.is_some state.T.voice_capture ->
           (* A manual or withdrawn capture still owns the microphone. The
              noise-floor probe must wait for its completion too. *)
           let notice =
             if state.T.voice_capture_withdrawn
             then "voice: discarding previous capture"
             else "voice: recording in progress" in
           T.set_last_action state (Some (notice, Unix.gettimeofday ()))
       | None ->
           (* Request one room probe in the asynchronous session, then reuse
              its floor between utterances. Turning the mode off drops it. *)
           state.T.voice_continuous <- Some keeper_name;
           state.T.voice_floor <- None;
           T.set_last_action state (Some ("voice: continuous on", Unix.gettimeofday ()));
           if state.T.voice_capture = None
           then Masc_tui_operator_actions.Voice_actions.launch_voice_capture ~calibrate:true state ~mailbox ~keeper:keeper_name);
      true
  | Composer.Release_focus ->
      (* A running capture is the innermost thing Esc can leave, so it goes
         first and the row keeps its focus. ^Y stops one and keeps what was
         said; this abandons it. *)
      (match state.T.voice_capture with
       | Some _ ->
           T.request_voice_stop state Masc.Voice_bridge.Discard;
           T.set_last_action state (Some ("voice: discarding", Unix.gettimeofday ()))
       | None ->
           T.save_message_draft state;
           state.T.composer_focused <- false;
           (* The row put away releases a line held for its compose
              ([composing_for_keeper]); it goes now, not at a settle an idle
              keeper never has. *)
           Masc_tui_chat_dispatch.Queue_steer.drain_queued_message state ~base_path ~mailbox);
      true
  | Composer.Send keeper_name ->
      withdraw_resource_diagram_pending ();
      if Masc_tui_chat_input.Paste_spill.recovered_paste_send_locked state then begin
        Masc_tui_loader.report_action state "system"
          "Recovered draft protected; press Ctrl-G to enable Enter";
        true
      end else begin
      state.T.composer_focused <- false;
      let snapshot = Masc_tui_message_input.snapshot state.T.msg_input in
      let text = Masc_tui_message_input.snapshot_text snapshot in
      (match Masc_tui_command.parse text with
       | Masc_tui_command.Say _ ->
           T.set_msg_scroll state 0;
           if state.T.view <> T.Keepers T.Keeper_message then begin
             match state.T.msg_target_keeper_name with
             | Some keeper_name ->
                 Masc_tui_chat_input.Message_draft_recall.reset_message_file_changes state (Some keeper_name);
                 launch_keeper_history_load ~keeper_name
             | None -> ()
           end;
           state.T.view <- T.Keepers T.Keeper_message
       | Masc_tui_command.Switch_keeper _ ->
           (* The switch handler owns the view change. *)
           T.set_msg_scroll state 0
       (* These answers are chat notices, including Memory status. Typed from
          the roster they would land in a pane the operator is not looking
          at, so the chat pane comes forward the way it does for a message. *)
       | Masc_tui_command.Queue _
       | Masc_tui_command.Memory_status
       | Masc_tui_command.Play_invites | Masc_tui_command.Play_link _
       | Masc_tui_command.Play_invite _
       | Masc_tui_command.Play_revoke _ | Masc_tui_command.Play_invalid _
       | Masc_tui_command.Listen | Masc_tui_command.Open_music_midi
       | Masc_tui_command.Open_images _ | Masc_tui_command.List_images | Masc_tui_command.Images_invalid_index
       | Masc_tui_command.Open_score _ | Masc_tui_command.Score_invalid_index
       | Masc_tui_command.Preset_list | Masc_tui_command.Preset_save _
       | Masc_tui_command.Preset_save_missing_name
       | Masc_tui_command.Preset_restore _
       | Masc_tui_command.Preset_restore_missing_name
       | Masc_tui_command.Preset_show _
       | Masc_tui_command.Preset_show_missing_name
       | Masc_tui_command.Preset_delete _
       | Masc_tui_command.Preset_delete_missing_name ->
           T.set_msg_scroll state 0;
           if state.T.view <> T.Keepers T.Keeper_message then begin
             match state.T.msg_target_keeper_name with
             | Some keeper_name ->
                 Masc_tui_chat_input.Message_draft_recall.reset_message_file_changes state (Some keeper_name);
                 launch_keeper_history_load ~keeper_name
             | None -> ()
           end;
           state.T.view <- T.Keepers T.Keeper_message
       | Masc_tui_command.Task_for_keeper _ | Masc_tui_command.Task_recover | Masc_tui_command.Task_inspect | Masc_tui_command.Task_missing_title
       | Masc_tui_command.Help | Masc_tui_command.Features
       | Masc_tui_command.Show_load_errors
       | Masc_tui_command.About | Masc_tui_command.Switch_keeper_missing_name
       | Masc_tui_command.Open_artifacts | Masc_tui_command.Open_music | Masc_tui_command.Music_invalid_arguments
        | Masc_tui_command.Open_diff
        | Masc_tui_command.Open_usage | Masc_tui_command.Open_changes
        | Masc_tui_command.Toggle_acting_pane
         | Masc_tui_command.Show_acting_pane_tab _
         | Masc_tui_command.Acting_pane_tab_unknown _
         | Masc_tui_command.Set_acting_pane_call_order _
         | Masc_tui_command.Acting_pane_call_order_unknown _
         | Masc_tui_command.Scroll_acting_pane _
         | Masc_tui_command.Acting_pane_scroll_unknown _
         | Masc_tui_command.Lane_addons _
         | Masc_tui_command.Account_login _
         | Masc_tui_command.Open_settings | Masc_tui_command.Open_metrics
         | Masc_tui_command.Open_link_preview _
         | Masc_tui_command.Open_links_list
         | Masc_tui_command.Set_embeds _
        | Masc_tui_command.Answer_tool_approval _
        | Masc_tui_command.Interrupt_turn
        | Masc_tui_command.Interrupt_keeper_turn _
         | Masc_tui_command.Run_next
         | Masc_tui_command.Reconcile_held
         | Masc_tui_command.Priority _
         | Masc_tui_command.Steer_turn _
       | Masc_tui_command.Steer_missing_message
       | Masc_tui_command.Set_thinking _
       | Masc_tui_command.Open_calls | Masc_tui_command.Set_tools _ | Masc_tui_command.Cycle_memory
       | Masc_tui_command.Open_fleet_memory
       (* [/find] moves the pane on purpose, so unlike every other command it
          must not be followed by the reset to the newest row above. *)
       | Masc_tui_command.Find_in_chat _ | Masc_tui_command.Find_next
       | Masc_tui_command.Copy_latest_reply
       | Masc_tui_command.Open_measurement _ | Masc_tui_command.Measurement_missing_sha
       | Masc_tui_command.Inspect_context
       | Masc_tui_command.View_image _ | Masc_tui_command.View_image_missing_path
       | Masc_tui_command.Attach_image _ | Masc_tui_command.Attach_image_missing_path
       | Masc_tui_command.Attach_image_ref _ | Masc_tui_command.Attach_image_ref_missing_value
       | Masc_tui_command.Unknown _ ->
           (* A command keeps the surface: the operator asked the TUI, not
              the keeper, and the answer lands in the session log. *)
           ());
      send_operator_text ~keeper_name snapshot;
      true
      end
  | Composer.Edit ->
      (* Annotated: [handle_message_key] takes labelled callbacks, and a
         missing one leaves a partial application that binds to [_handled]
         without a word. Saying the type here turns that into a build
         failure. *)
      let (_handled : bool) =
        Masc_tui_chat_input.Message_keymap.handle_message_key ~terminal_size ~wheel_notch_rows state
          ~submit_message:(fun _ -> ())
          ~load_older:(fun ~cursor:_ -> ())
          ~paste_image:paste_clipboard_image
          ~open_named_image
          ~inspect_context:(fun () ->
            match state.T.msg_target_keeper_name with
            | Some keeper_name ->
                Masc_tui_chat_dispatch.Chat_journals.open_context_inspector state ~mailbox ~keeper_name
            | None -> ())
          ~inspect_queue:(fun () ->
            match state.T.msg_target_keeper_name with
            | Some keeper_name ->
                Masc_tui_collab_queue.Keeper_queue.open_keeper_queue_panel state ~mailbox ~keeper_name
            | None -> ())
          ~load_preparation:(fun () -> Masc_tui_chat_dispatch.Chat_journals.launch_selected_preparation_operation_read state ~mailbox)
          ~load_tool_changes:(fun () ->
            match state.T.msg_target_keeper_name with
            | Some keeper_name ->
                launch_keeper_chat_tool_details_load ~keeper_name
            | None -> ())
          ~drain_queue:(fun () -> ())
          (* This call site replays one key to reach the paste handlers; a
             capture is not something a replay should start. *)
          ~start_voice:(fun () -> ())
          ~toggle_voice_continuous:(fun () -> ())
          key
      in
      true
