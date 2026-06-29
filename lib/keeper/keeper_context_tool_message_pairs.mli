(** Tool-use / tool-result block pair invariants for keeper messages. *)

val tool_use_ids_of_message : Agent_sdk.Types.message -> string list
val tool_result_ids_of_message : Agent_sdk.Types.message -> string list
val has_tool_result_block : Agent_sdk.Types.message -> bool
val has_tool_use_block : Agent_sdk.Types.message -> bool

(** Trim messages to at most [max_count] preserving ToolUse/ToolResult
    pairing.  Drops from the front; advances the drop boundary by 1
    when the next kept message would be an orphan [ToolResult]. *)
val trim_messages_preserving_pairs
  :  Agent_sdk.Types.message list
  -> max_count:int
  -> Agent_sdk.Types.message list
