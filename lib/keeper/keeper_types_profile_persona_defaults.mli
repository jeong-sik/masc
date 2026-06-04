(** Persona JSON -> keeper profile defaults.

    This module owns the profile.json conversion boundary. Runtime assignment
    remains outside persona profiles, and legacy inline self-model fields are
    ignored here. *)

val load : name:string -> Keeper_types_profile_defaults.keeper_profile_defaults
