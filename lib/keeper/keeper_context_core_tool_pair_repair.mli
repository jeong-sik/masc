val default_max_checkpoint_tool_result_chars : int
val tool_use_ids_of_message : Agent_sdk.Types.message -> string list
val tool_result_ids_of_message : Agent_sdk.Types.message -> string list
val has_tool_result_block : Agent_sdk.Types.message -> bool

val trim_messages_preserving_pairs :
  Agent_sdk.Types.message list -> max_count:int -> Agent_sdk.Types.message list

val tool_result_text_of_block :
  tool_use_id:string -> content:string -> json:Yojson.Safe.t option -> string

val tool_use_text_of_block :
  tool_use_id:string -> tool_name:string -> input:Yojson.Safe.t -> string

type tool_pair_repair_stats =
  { downgraded_tool_uses : int
  ; downgraded_tool_results : int
  }

val empty_tool_pair_repair_stats : tool_pair_repair_stats
val add_tool_pair_repair_stats : tool_pair_repair_stats -> tool_pair_repair_stats -> tool_pair_repair_stats
val tool_pair_repair_stats_changed : tool_pair_repair_stats -> bool
val pair_repair_metadata_key : string
val repair_dangling_tool_use_messages_with_stats :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list * tool_pair_repair_stats
val repair_dangling_tool_use_messages : Agent_sdk.Types.message list -> Agent_sdk.Types.message list
val repair_orphan_tool_result_messages_with_stats :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list * tool_pair_repair_stats
val repair_orphan_tool_result_messages : Agent_sdk.Types.message list -> Agent_sdk.Types.message list
val repair_broken_tool_call_pairs_with_stats :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list * tool_pair_repair_stats
val repair_broken_tool_call_pairs : Agent_sdk.Types.message list -> Agent_sdk.Types.message list
