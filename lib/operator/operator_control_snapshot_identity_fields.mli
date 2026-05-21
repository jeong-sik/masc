(** Keeper identity-field builders for operator control snapshots. *)

val non_empty_trimmed_string_opt : string -> string option
(** Trim a string and return [None] when it is empty. *)

val keeper_runtime_identity_fields :
  Keeper_types.keeper_meta -> (string * Yojson.Safe.t) list
(** Live identity fields with cascade canonicalization. *)

val degraded_keeper_runtime_identity_fields :
  Keeper_types.keeper_meta -> (string * Yojson.Safe.t) list
(** Fallback identity fields when live cascade resolution is unavailable. *)
