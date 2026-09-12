(** Direct-operation adapter over the Owner journal and retained exact checkpoint.
    Deferral retains immutable owned bytes before committing their reference.
    Resume preserves newer shared history only when the original input and
    effects remain its exact prefix, restores the original execution scope,
    and durably admits an explicit continuation if another scope intervened.
    Missing original bytes never authorize reconstruction or replay. *)
type admission
val checkpoint : admission -> Agent_core.Checkpoint.t
val lane : admission -> Keeper_turn_driver.deferred_runtime_lane
val load : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  session_dir:string -> session_id:string -> (admission option, string) result
val consume : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  admission -> (unit, string) result
val defer : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  session_dir:string -> session_id:string -> Keeper_turn_driver.deferred_runtime_lane -> (unit, string) result

module For_testing : sig
  val validate_scope : operation_id:Keeper_chat_operation.Operation_id.t ->
    Agent_core.Checkpoint.t -> (unit, string) result
end
