type tool_stream_occurrence =
  { stream_scope : int; provider_message_id : string option; block_index : int }
type text_response = Unobserved_scope of int option
type keeper_chat_event =
  | Tool_call_start of { occurrence : tool_stream_occurrence; tool_call_name : string; tool_call_id : string option }
  | Tool_call_admitted of { occurrence : tool_stream_occurrence; tool_call_name : string; provider_tool_name : string; tool_call_id : string option }
  | Tool_call_args of { occurrence : tool_stream_occurrence; delta : string; tool_call_id : string option }
  | Tool_call_args_snapshot of { occurrence : tool_stream_occurrence; snapshot : string; tool_call_id : string option }
  | Text_delta of { text : string; response : text_response }
  | Text_message_end | Agent_core_stream_connected | Agent_core_stream_ping
  | Run_started of unit | Batch_bound of unit | Text_message_start of unit
  | External_effect_completed of unit | Run_finished of unit | Event_error of unit
  | Reply_details of unit | Continuation_checkpoint of unit | Provider_retry_observed of unit
  | Agent_core_runtime_attempt_started of unit | Agent_core_stream_message_start of unit
  | Agent_core_stream_message_delta of unit | Agent_core_stream_message_stop of unit
  | Agent_core_content_block_start of unit | Agent_core_content_block_stop of unit
  | Model_content_activity of unit | Agent_core_thinking_delta of unit
  | Agent_core_thinking_snapshot of unit | Agent_core_thinking_signature_delta of unit
  | Agent_core_media_delta of unit | Agent_core_stream_protocol_error of unit
  | Tool_call_end of unit | Native_tool_start of unit | Native_tool_end of unit * unit
  | Native_tool_progress of unit * unit | Tool_approval_requested of unit
  | Tool_approval_settled of unit | Tool_result_ready of unit | Tool_transcript_committed of unit
  | Link_block of unit | Image_block of unit | Status_block of unit | Audio_block of unit
  | Tool_context_block of unit
