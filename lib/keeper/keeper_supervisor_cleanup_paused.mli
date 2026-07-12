(** Submit stale paused metadata cleanup through the exact-owner durable
    lifecycle boundary without blocking the supervisor sweep. *)
val submit :
  'a Keeper_types_profile.context ->
  Keeper_meta_contract.keeper_meta ->
  unit

(** Record and surface a metadata read failure encountered while selecting a
    stale paused Keeper for cleanup. *)
val report_meta_read_failure : keeper_name:string -> string -> unit
