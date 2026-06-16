val snapshot_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

val summary_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

module For_testing : sig
  val clear_snapshot_cache : unit -> unit
end
