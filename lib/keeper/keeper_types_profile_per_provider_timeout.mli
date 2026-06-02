(** Per-provider timeout normalization helpers for keeper profile. *)

include module type of Keeper_types_profile_defaults

val normalize_per_provider_timeout_opt
  :  source:string
  -> float option
  -> float option

val per_provider_timeout_of_declared_float_opt
  :  source:string
  -> declared:bool
  -> float option
  -> per_provider_timeout_state * float option

val per_provider_timeout_of_toml
  :  source:string
  -> Keeper_toml_loader.toml_doc
  -> string
  -> per_provider_timeout_state * float option

val per_provider_timeout_of_json_field
  :  source:string
  -> field:string
  -> Yojson.Safe.t
  -> per_provider_timeout_state * float option

val normalize_per_provider_timeout_json_field
  :  source:string
  -> field:string
  -> Yojson.Safe.t
  -> float option
