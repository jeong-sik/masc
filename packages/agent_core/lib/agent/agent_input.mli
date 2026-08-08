(** Private user-input normalization for Agent run entry points. *)

val base_messages : Agent_types.t -> Types.message list
val trace_prompt_of_blocks : Types.content_block list -> string

val validate_user_input_blocks
  :  Types.content_block list
  -> (unit, Error.sdk_error) result

val append_user_input
  :  Agent_types.t
  -> Types.content_block list
  -> Types.content_block list

val resume_user_input
  :  Agent_types.t
  -> Types.content_block list
  -> (Types.content_block list, Error.sdk_error) result
