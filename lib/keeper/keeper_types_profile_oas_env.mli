(** OAS transport environment helpers for keeper profile defaults. *)

val string_of_toml_value_for_env : Keeper_toml_loader.toml_value -> string option
val oas_env_key_prefix : string
val keeper_unified_max_tokens_oas_env_key : string
val keeper_unified_max_tokens_toml_key : string
val oas_env_key_is_allowed : string -> bool
val extract_oas_env_from_doc : Keeper_toml_loader.toml_doc -> (string * string) list

val validate_unified_max_tokens_toml_value
  :  Keeper_toml_loader.toml_doc
  -> (unit, string) result

val parse_unified_max_tokens_override_of_oas_env
  :  (string * string) list
  -> (int option, string) result

val unified_max_tokens_override_of_oas_env
  :  ?keeper_name:string
  -> (string * string) list
  -> int option
