(** Cooperative direct-turn continuation from retained canonical checkpoint bytes.
    No provider retry is invented and the admitted input is not appended again. *)
type admission
val checkpoint : admission -> Agent_core.Checkpoint.t option
val official_client : admission -> Keeper_semantic_execution.official_client_checkpoint option
val official_client_original_turn : admission -> Keeper_semantic_execution.official_client_checkpoint option
(** Saved operation checkpoint before admission advances to the latest vendor turn. *)
val official_resume_message : operation_id:Keeper_chat_operation.Operation_id.t -> string
val load : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  session_dir:string -> session_id:string -> (admission option, string) result
val consume : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  admission -> (unit, string) result
val defer : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  session_dir:string -> session_id:string -> checkpoint:Agent_core.Checkpoint.t -> (unit, string) result

val defer_official : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  settled_session:Keeper_official_client_session_store.t -> frame:Keeper_repetition_snapshot.t -> (unit, string) result
module For_testing : sig
  val prepare_official_resume : observed:Keeper_semantic_execution.official_client_checkpoint ->
    expected:Keeper_official_client_session_store.t option -> (Keeper_semantic_execution.official_client_checkpoint, string) result
end
