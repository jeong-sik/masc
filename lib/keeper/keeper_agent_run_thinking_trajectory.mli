val persist_response_content
  :  keeper_name:string
  -> trajectory_acc:Trajectory.accumulator option
  -> turn:int
  -> Agent_sdk.Types.content_block list
  -> unit
(** Append every [Thinking]/[RedactedThinking] block in [content] to the
    keeper's trajectory JSONL, stamped with [turn]. Call once per turn from the
    [after_turn] hook so no turn's reasoning is dropped. Text is persisted
    untruncated (see {!Trajectory.append_thinking}). *)
