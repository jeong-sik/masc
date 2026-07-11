(** Persona JSON -> keeper profile defaults.

    This module owns the profile.json conversion boundary. Runtime assignment
    remains outside persona profiles. Persona prompt fields are loaded as
    defaults and may be overridden by keeper TOML overlays. *)

type load_error_kind =
  | Persona_read_error
  | Persona_parse_error

type load_error =
  { path : string
  ; kind : load_error_kind
  ; detail : string
  }

val load_from_dirs :
  persona_dirs:string list ->
  name:string ->
  (Keeper_types_profile_defaults.keeper_profile_defaults, load_error) result
