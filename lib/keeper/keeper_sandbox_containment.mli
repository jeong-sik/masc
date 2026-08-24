(** Objective host path containment shared by read and write leaves. *)

(** [check_read_target] verifies symlink-resolved containment in the keeper's
    effective read roots, including explicit roots outside the project base. *)
val check_read_target :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  target:string ->
  (unit, string) result

