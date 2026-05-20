(** Typed keeper_bash input projections (quote, render, validate). *)

val has_typed_bash_input_key : Yojson.Safe.t -> bool
val assoc_upsert : string -> Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
val shell_quote_for_policy : string -> string

val typed_stage_command_text : executable:string -> argv:string list -> string
val typed_input_command_text : Keeper_tool_bash_input.t -> string
val typed_input_has_env : Keeper_tool_bash_input.t -> bool

val typed_validation_error_text
  :  Keeper_tool_bash_input.validation_error
  -> string
