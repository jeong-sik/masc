(** AGENT_CORE transport environment helpers for keeper profile defaults. *)

val string_of_toml_value_for_env : Keeper_toml_loader.toml_value -> string option
val agent_core_env_key_prefix : string
val agent_core_env_key_is_allowed : string -> bool
val extract_agent_core_env_from_doc : Keeper_toml_loader.toml_doc -> (string * string) list
