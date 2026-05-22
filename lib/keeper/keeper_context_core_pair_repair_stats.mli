(** Tool-pair repair stats and metadata helpers. *)

type tool_pair_repair_stats =
  { downgraded_tool_uses : int
  ; downgraded_tool_results : int
  }

val empty_tool_pair_repair_stats : tool_pair_repair_stats
val add_tool_pair_repair_stats :
  tool_pair_repair_stats -> tool_pair_repair_stats -> tool_pair_repair_stats
val tool_pair_repair_stats_changed : tool_pair_repair_stats -> bool
val pair_repair_metadata_key : string
val pair_repair_metadata_keys : string list
val with_pair_repair_metadata :
  kind:string -> count:int -> Agent_sdk.Types.message -> Agent_sdk.Types.message
