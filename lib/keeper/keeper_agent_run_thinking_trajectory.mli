val persist_response_content
  :  keeper_name:string
  -> trajectory_acc:Trajectory.accumulator option
  -> oas_turn:int
  -> Agent_sdk.Types.content_block list
  -> unit
(** Append every [Thinking]/[ReasoningDetails]/[RedactedThinking] block in
    provider order, stamped with the accumulator's exact Keeper turn,
    [oas_turn], and its original block index. The OAS
    canonical block is persisted without flattening or truncation. *)
