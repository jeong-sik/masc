(** OAS transport environment helpers for keeper profile defaults. *)

val string_of_toml_value_for_env : Keeper_toml_loader.toml_value -> string option
val oas_env_key_prefix : string
val oas_env_allowed_prefixes : string list
val keeper_unified_max_tokens_oas_env_key : string
val legacy_keeper_unified_max_tokens_oas_env_key : string
val oas_env_allowed_exact_keys : string list
val oas_env_key_is_allowed : string -> bool
val extract_oas_env_from_doc : Keeper_toml_loader.toml_doc -> (string * string) list

val unified_max_tokens_override_of_oas_env
  :  ?keeper_name:string
  -> (string * string) list
  -> int option

val oas_env_truthy : string -> bool
val oas_env_has_non_empty : string -> (string * string) list -> bool
val effective_oas_env : (string * string) list -> (string * string) list
