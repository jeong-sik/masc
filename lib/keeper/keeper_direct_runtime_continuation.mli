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
  session_dir:string -> session_id:string -> dispatch_snapshot:Runtime.keeper_dispatch_snapshot ->
  Keeper_turn_driver.deferred_runtime_lane -> (unit, string) result

module For_testing : sig
  val validate_scope : operation_id:Keeper_chat_operation.Operation_id.t ->
    Agent_core.Checkpoint.t -> (unit, string) result

  (** When a deferred chat retry becomes claimable: [None] now, [Some t] at
      [t] (RFC-provider-path-rest §3.4). *)
  val retry_not_before : now:float -> Keeper_turn_driver.deferred_runtime_lane -> float option
  val restore_retry : keeper_name:string -> Keeper_semantic_execution.runtime_retry ->
    (Keeper_semantic_execution.runtime_retry, string) result
  val retry_wait : keeper_name:string -> dispatch_snapshot:Runtime.keeper_dispatch_snapshot ->
    lane:Keeper_turn_driver.deferred_runtime_lane -> Keeper_owner.runtime_retry_wait
end
