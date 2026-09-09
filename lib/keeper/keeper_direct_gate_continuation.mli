(** Gate-specific direct continuation. Original ownership is checked against a
    retained exact snapshot; newer canonical history is preserved. *)
type admission
val checkpoint : admission -> Agent_core.Checkpoint.t
val resolution : admission -> Keeper_event_queue.hitl_resolution
val source_reference : admission -> Keeper_checkpoint_ref.t
val load : config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  operation_id:Keeper_chat_operation.Operation_id.t -> session_dir:string ->
  (admission option, string) result
val runtime_lane : admission -> Keeper_turn_driver.deferred_runtime_lane option
val suspend : ?runtime_lane:Keeper_turn_driver.deferred_runtime_lane -> config:Workspace.config -> keeper_name:string ->
  operation_id:Keeper_chat_operation.Operation_id.t -> session_dir:string -> session_id:string ->
  approval_ids:string list -> unit -> (bool, string) result
val reconcile : config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> (unit, string) result
val discharge : config:Workspace.config -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  user_message:string -> checkpoint:Agent_core.Checkpoint.t -> admission -> (unit, string) result

(** A checkpoint-less Gate reconciliation is nonterminal but cannot supply a
    resume reference. The original request and obligations remain durable. *)
type pending = Bound_checkpoint of Keeper_checkpoint_ref.t | Checkpoint_reconciliation
val pending : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  (pending option, string) result
