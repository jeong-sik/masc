val persist_response_content
  :  keeper_name:string
  -> trajectory_acc:Trajectory.accumulator option
  -> turn:int
  -> Agent_core.Types.content_block list
  -> unit
(** Append metadata for every reasoning block in [content] to the keeper's
    trajectory JSONL, stamped with [turn]. Hidden content and provider replay
    signatures never cross this writer boundary. *)
