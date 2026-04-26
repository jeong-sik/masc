(** Pre-flight validation for keeper autonomous operations.
    Checks GitHub auth, repo accessibility, and keeper identity
    before starting work. All checks are read-only. *)

val handle_keeper_preflight_check
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> args:Yojson.Safe.t
  -> string
