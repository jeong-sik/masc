(** Layer 2 of the Runtime TOML parser: the model tables. It reads each
    model's capabilities, thinking-control format, sampling bounds, reasoning
    effort and turn timeout. *)

open Runtime_toml_base

val exact_non_empty_string_opt_field :
  path:string ->
  Otoml.t ->
  string -> (string option, parse_error list) result

val legacy_model_capability_keys : string list

val legacy_model_keys : string list

val parse_models :
  Otoml.t ->
  (Runtime_schema.model_spec list, parse_error list) result
