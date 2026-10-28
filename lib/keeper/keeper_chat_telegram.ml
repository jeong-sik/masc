let deliver ~events ~load_blocks ~send =
  let open Result.Syntax in
  let rec loop terminal =
    match Keeper_chat_events.subscribe events with
    | Keeper_chat_events.Closed -> Error "Telegram event stream closed before terminal completion"
    | Keeper_chat_events.Next (Keeper_chat_events.Event_error {message}) -> Error message
    | Keeper_chat_events.Next (Keeper_chat_events.Reply_details details) -> loop (Some details)
    | Keeper_chat_events.Next (Keeper_chat_events.Run_finished _) ->
      (match terminal with
       | None -> Error "Telegram run completed without terminal reply details"
       | Some details -> match details.Keeper_chat_events.turn_outcome with
         | Keeper_turn_outcome.Visible_reply ->
           let* blocks = load_blocks details.turn_ref in
           let* messages = Keeper_telegram_render.render ~reply:details.reply ~blocks in
           send messages
         | Continuation_checkpoint ->
           let* messages = Keeper_telegram_render.render ~reply:"" ~blocks:(Some [Keeper_chat_blocks.Status {kind=Continuation_checkpoint}]) in
           send messages
         | Awaiting_gate_approval ->
           let* messages = Keeper_telegram_render.render ~reply:"" ~blocks:(Some [Keeper_chat_blocks.Status {kind=Awaiting_gate_approval}]) in
           send messages
         | Terminal_effect_settled | No_visible_reply -> Ok ())
                      | Keeper_chat_events.Next (Keeper_chat_events.Run_started _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Batch_bound _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Text_message_start _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Text_delta _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Text_message_end)
                      | Keeper_chat_events.Next (Keeper_chat_events.External_effect_completed _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Continuation_checkpoint _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_stream_connected)
                      | Keeper_chat_events.Next (Keeper_chat_events.Provider_retry_observed _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_runtime_attempt_started _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_stream_message_start _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_stream_message_delta _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_stream_message_stop _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_stream_ping)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_content_block_start _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_content_block_stop _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Model_content_activity _)
                      | Keeper_chat_events.Next ((Keeper_chat_events.Agent_core_thinking_delta _ | Keeper_chat_events.Agent_core_thinking_snapshot _))
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_thinking_signature_delta _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_media_delta _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Agent_core_stream_protocol_error _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Tool_call_start _ | Keeper_chat_events.Tool_call_admitted _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Tool_call_args _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Tool_call_args_snapshot _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Tool_call_end _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Native_tool_start _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Native_tool_end (_, _))
                      | Keeper_chat_events.Next (Keeper_chat_events.Native_tool_progress (_, _))
                      | Keeper_chat_events.Next (Keeper_chat_events.Tool_approval_requested _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Tool_approval_settled _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Tool_result_ready _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Tool_transcript_committed _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Link_block _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Image_block _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Status_block _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Audio_block _)
                      | Keeper_chat_events.Next (Keeper_chat_events.Tool_context_block _) -> loop terminal
  in loop None
