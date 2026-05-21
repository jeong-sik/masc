(** Keeper runtime identity field builders for operator control snapshots. *)

val non_empty_trimmed_string_opt : string -> string option
val keeper_runtime_identity_fields : Keeper_types.keeper_meta -> (string * Yojson.Safe.t) list

val degraded_keeper_runtime_identity_fields :
  Keeper_types.keeper_meta -> (string * Yojson.Safe.t) list
