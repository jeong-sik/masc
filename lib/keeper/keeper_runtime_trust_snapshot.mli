val snapshot_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

val summary_json :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

(** The decision fields every trust projection writes, from one model:
    [disposition], [disposition_reason], [operator_disposition],
    [operator_disposition_reason], [needs_attention], [attention_reason] and
    [next_human_action]. The two operator fields are [null] when the model
    carries no receipt disposition. *)
val trust_model_json_fields :
  Keeper_runtime_trust_snapshot_core.t -> (string * Yojson.Safe.t) list

module For_testing : sig


  val snapshot_json_inner_with_pending_reader :
    read_pending:
      (base_path:string ->
      (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result) ->
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    Yojson.Safe.t
end
