(** SSE → Stream_chunk adapter, RFC-0022 PR-3/4. *)

module SC = Cascade_attempt_liveness.Stream_chunk

let kind_of_sse_event (evt : Agent_sdk.Types.sse_event) : SC.kind option =
  match evt with
  | Agent_sdk.Types.ContentBlockDelta { delta; _ } ->
      (match delta with
       | Agent_sdk.Types.TextDelta _ -> Some SC.Answer_delta
       | Agent_sdk.Types.ThinkingDelta _ -> Some SC.Thinking_delta
       | Agent_sdk.Types.InputJsonDelta _ -> Some SC.Tool_call_arg_delta)
  | Agent_sdk.Types.ContentBlockStart { content_type; tool_name; _ }
    when content_type = "tool_use" ->
      let tool_name = Option.value tool_name ~default:"" in
      Some (SC.Tool_call_start { tool_name })
  | Agent_sdk.Types.ContentBlockStart { content_type; _ } ->
      Some (SC.Substrate_event { kind = "content_block_start:" ^ content_type })
  | Agent_sdk.Types.ContentBlockStop _ ->
      Some SC.Tool_call_complete
  | Agent_sdk.Types.MessageStart _ ->
      Some (SC.Substrate_event { kind = "message_start" })
  | Agent_sdk.Types.MessageDelta _ ->
      Some (SC.Substrate_event { kind = "message_delta" })
  | Agent_sdk.Types.MessageStop ->
      Some SC.Done
  | Agent_sdk.Types.Ping ->
      Some SC.Heartbeat
  | Agent_sdk.Types.SSEError _ ->
      None
