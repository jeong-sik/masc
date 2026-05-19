val default_max_checkpoint_text_blocks_per_message : int
val default_max_checkpoint_text_chars_per_message : int
val default_max_checkpoint_content_chars_total : int
val checkpoint_text_cap_marker : string
val default_max_checkpoint_tool_result_chars : int
val default_max_checkpoint_tool_results_per_message : int
val default_max_checkpoint_tool_result_total_chars : int

type checkpoint_sanitize_stats = {
  dropped_messages : int;
  dropped_blocks : int;
  dropped_chars : int;
  truncated_blocks : int;
  truncated_chars : int;
}

val empty_checkpoint_sanitize_stats : checkpoint_sanitize_stats
val checkpoint_sanitize_changed : checkpoint_sanitize_stats -> bool
val add_checkpoint_sanitize_stats : checkpoint_sanitize_stats -> checkpoint_sanitize_stats -> checkpoint_sanitize_stats
val truncate_checkpoint_text : max_chars:int -> string -> string * int
val find_substring_from : haystack:string -> needle:string -> start:int -> int option
val strip_world_state_segments : string -> string
val is_ephemeral_system_context_text : string -> bool
val sanitize_checkpoint_text_block : string -> string option * checkpoint_sanitize_stats
val sanitize_checkpoint_message : Agent_sdk.Types.message -> Agent_sdk.Types.message option * checkpoint_sanitize_stats
val checkpoint_content_chars_of_block : Agent_sdk.Types.content_block -> int
val checkpoint_content_chars_of_message : Agent_sdk.Types.message -> int
val cap_checkpoint_message_to_remaining_content :
  remaining:int ->
  Agent_sdk.Types.message ->
  Agent_sdk.Types.message option * int * checkpoint_sanitize_stats
val cap_checkpoint_messages_total_content :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list * checkpoint_sanitize_stats
val sanitize_checkpoint_messages :
  Agent_sdk.Types.message list -> Agent_sdk.Types.message list * checkpoint_sanitize_stats
val sanitize_oas_checkpoint :
  ?repair_orphans:bool ->
  Agent_sdk.Checkpoint.t ->
  Agent_sdk.Checkpoint.t * checkpoint_sanitize_stats
