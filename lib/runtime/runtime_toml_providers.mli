(** Layer 1 of the Runtime TOML parser: the provider tables. It reads each
    provider's credential, capabilities, headers, Antigravity CLI options and
    usage-read declaration. *)

open Runtime_toml_base

val positive_int_opt_field :
  path:string ->
  key:string ->
  Otoml.t -> (int option, parse_error list) result

val parse_providers :
  Otoml.t ->
  (Runtime_schema.provider list, parse_error list) result
