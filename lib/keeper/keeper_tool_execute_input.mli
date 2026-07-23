(** Typed Execute input projections (quote, render, validate). *)

val has_typed_execute_input_key : Yojson.Safe.t -> bool
val assoc_upsert : string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
val shell_quote_for_policy : string -> string

val typed_stage_command_text : string list -> string
val typed_input_command_text : Keeper_tool_execute_typed_input.execute_input -> string
val typed_input_has_env : Keeper_tool_execute_typed_input.execute_input -> bool
val typed_input_timeout_sec : Keeper_tool_execute_typed_input.execute_input -> float option

val typed_validation_error_text
  :  Keeper_tool_execute_typed_input.validation_error
  -> string
