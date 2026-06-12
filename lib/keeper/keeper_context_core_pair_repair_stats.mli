(** Tool-pair repair stats and metadata helpers for [Keeper_context_core]. *)

type tool_pair_repair_stats =
  { dropped_tool_uses : int
  ; dropped_tool_results : int
  ; dropped_tool_use_samples : (string * string) list
  ; dropped_tool_result_ids : string list
  }

val empty_tool_pair_repair_stats : tool_pair_repair_stats

val add_tool_pair_repair_stats :
  tool_pair_repair_stats -> tool_pair_repair_stats -> tool_pair_repair_stats

val tool_pair_repair_stats_changed : tool_pair_repair_stats -> bool
val pair_repair_metadata_key : string
val pair_repair_metadata_keys : string list

val with_pair_repair_metadata :
  ?tool_use_samples:(string * string) list ->
  ?tool_result_ids:string list ->
  kind:string -> count:int -> Agent_sdk.Types.message -> Agent_sdk.Types.message
