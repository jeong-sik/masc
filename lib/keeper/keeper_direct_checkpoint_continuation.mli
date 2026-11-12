(** Cooperative direct-turn continuation from retained canonical checkpoint bytes.
    No provider retry is invented and the admitted input is not appended again. *)
type admission
val checkpoint : admission -> Agent_core.Checkpoint.t option
val official_client : admission -> Keeper_semantic_execution.official_client_checkpoint option
val official_client_original_turn : admission -> Keeper_semantic_execution.official_client_checkpoint option
(** Saved operation checkpoint before admission advances to the latest vendor turn. *)
val official_resume_message : operation_id:Keeper_chat_operation.Operation_id.t -> (string, string) result
val load : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  session_dir:string -> session_id:string -> (admission option, string) result
val consume : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  admission -> (unit, string) result
(** Core checkpoints are consumed at the prepared runtime-entry boundary.
    Official checkpoints enter durable preparation before guidance renders. *)
val defer : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  session_dir:string -> session_id:string -> checkpoint:Agent_core.Checkpoint.t ->
  receipt_wait:Keeper_semantic_execution.receipt_obligation option -> (unit, string) result
(** [receipt_wait] is the request the turn ended to wait for. The operation
    joins the owner record of that request in the same transaction that ends
    the turn. [None] is the plain cooperative yield. *)

val defer_official : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  settled_session:Keeper_official_client_session_store.t -> frame:Keeper_repetition_snapshot.t ->
  receipt_wait:Keeper_semantic_execution.receipt_obligation option -> (unit, string) result
module For_testing : sig
  val prepare_official_resume : observed:Keeper_semantic_execution.official_client_checkpoint ->
    expected:Keeper_official_client_session_store.t option -> (Keeper_semantic_execution.official_client_checkpoint, string) result
end

val wait_preparation : base_path:string -> keeper_name:string ->
  operation_id:Keeper_chat_operation.Operation_id.t -> execution_digest:string ->
  failure:Agent_core.Error.t -> admission -> (unit,string) result
