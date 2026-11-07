type t =
  | Closed
  | Reply of Keeper_chat_events.reply_details
  | Finished
  | Failed of string
  | Progress

let of_event (event : Keeper_chat_events.keeper_chat_event) =
  let open Keeper_chat_events in
  match event with
  | Reply_details details -> Reply details
  | Run_finished _ -> Finished
  | Event_error { message } -> Failed message
  | Run_started _
  | Batch_bound _
  | Text_message_start _
  | Text_delta _
  | Text_message_end
  | External_effect_completed _
  | Continuation_checkpoint _
  | Agent_core_stream_connected
  | Provider_retry_observed _
  | Agent_core_runtime_attempt_started _
  | Agent_core_stream_message_start _
  | Agent_core_stream_message_delta _
  | Agent_core_stream_message_stop _
  | Agent_core_stream_ping
  | Agent_core_content_block_start _
  | Agent_core_content_block_stop _
  | Model_content_activity _
  | (Agent_core_thinking_delta _ | Agent_core_thinking_snapshot _)
  | Agent_core_thinking_signature_delta _
  | Agent_core_media_delta _
  | Agent_core_stream_protocol_error _
  | Tool_call_start _ | Tool_call_admitted _
  | Tool_call_args _
  | Tool_call_args_snapshot _
  | Tool_call_end _
  | Native_tool_start _
  | Native_tool_end (_, _)
  | Native_tool_progress (_, _)
  | Tool_approval_requested _
  | Tool_approval_settled _
  | Tool_result_ready _
  | Tool_transcript_committed _
  | Link_block _
  | Image_block _
  | Status_block _
  | Audio_block _
  | Tool_context_block _ -> Progress

let read events =
  match Keeper_chat_events.subscribe events with
  | Keeper_chat_events.Closed -> Closed
  | Keeper_chat_events.Next event -> of_event event

let visible_text (details : Keeper_chat_events.reply_details) =
  match details.turn_outcome with
  | Keeper_turn_outcome.Visible_reply when String.trim details.reply <> "" -> Some details.reply
  | Keeper_turn_outcome.Visible_reply
  | Keeper_turn_outcome.Continuation_checkpoint
  | Keeper_turn_outcome.Terminal_effect_settled
  | Keeper_turn_outcome.Awaiting_gate_approval
  | Keeper_turn_outcome.No_visible_reply -> None
