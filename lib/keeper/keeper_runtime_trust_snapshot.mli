val snapshot_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

val summary_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

module For_testing : sig


  val snapshot_json_inner_with_pending_reader :
    read_pending:
      (base_path:string ->
      (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result) ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    Yojson.Safe.t
end
