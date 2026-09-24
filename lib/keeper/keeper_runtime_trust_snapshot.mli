val snapshot_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

val summary_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

(** Trust fields for a row built without reading the Keeper, such as the
    dashboard row shown when a Keeper's row could not be built. The row needs
    attention. No receipt was read, so [operator_disposition] and
    [operator_disposition_reason] are [null]. The fields are the ones every
    trust projection writes, from the same serializer. *)
val unread_keeper_json :
  disposition:string ->
  disposition_reason:string ->
  attention_reason:string ->
  next_human_action:string ->
  Yojson.Safe.t

module For_testing : sig


  val snapshot_json_inner_with_pending_reader :
    read_pending:
      (base_path:string ->
      (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result) ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    Yojson.Safe.t
end
