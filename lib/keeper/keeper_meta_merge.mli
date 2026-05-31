(** Field-ownership merges for keeper_meta on CAS retry.

    Coord presence/cursor fields were removed; CAS retries now only need
    to carry the disk meta_version forward. *)

type t = latest:Keeper_meta_contract.keeper_meta -> caller:Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta

val caller_wins : t
(** Take every field from the caller except [meta_version], which
    follows the disk version. *)

val heartbeat_fields_from_disk : t
(** Transitional name for existing heartbeat retry call sites. With
    coord-owned fields removed, this is equivalent to {!caller_wins}. *)
