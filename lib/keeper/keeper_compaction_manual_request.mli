module Operation = Keeper_compaction_operation
module Store = Keeper_compaction_operation_store
type request_status =
  | Created
  | Existing
type confirmation =
  { operation_id : Operation.Operation_id.t
  ; status : request_status
  ; source_checkpoint : Keeper_checkpoint_ref.t
  }
type error =
  | Keeper_meta_unavailable of string
  | Keeper_meta_identity_mismatch of
      { requested : Keeper_id.Keeper_name.t
      ; persisted : string
      }
  | Source_checkpoint_unavailable of
      Keeper_checkpoint_store.checkpoint_ref_load_error
  | Source_object_persist_failed of Keeper_compaction_object_store.put_error
  | Durable_source_unavailable of
      { operation_id : Operation.Operation_id.t
      ; error : Keeper_compaction_object_store.load_error
      }
  | Journal_read_failed of Store.read_error
  | Journal_append_failed of
      { attempted_operation_id : Operation.Operation_id.t
      ; error : Store.append_error
      }
  | Existing_operation_missing of
      { attempted_operation_id : Operation.Operation_id.t
      ; existing_operation_id : Operation.Operation_id.t
      }
  | Transaction_outcome_unresolved of
      { attempted_operation_id : Operation.Operation_id.t
      ; error : Store.transaction_error
      ; replay_error : Store.read_error option
      }
val request :
  config:Workspace.config ->
  keeper_name:Keeper_id.Keeper_name.t ->
  cause:Operation.Cause.t ->
  producer:Operation.producer_ref option ->
  (confirmation, error) result
