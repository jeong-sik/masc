(** Gate-specific direct continuation. Original ownership is checked against a
    retained exact snapshot; newer canonical history is preserved. *)
type admission
val checkpoint : admission -> Agent_core.Checkpoint.t
val resolution : admission -> Keeper_event_queue.hitl_resolution
val source_reference : admission -> Keeper_checkpoint_ref.t
val load : config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  operation_id:Keeper_chat_operation.Operation_id.t -> session_dir:string ->
  (admission option, string) result
val suspend : config:Workspace.config -> keeper_name:string ->
  operation_id:Keeper_chat_operation.Operation_id.t -> session_dir:string -> session_id:string ->
  approval_ids:string list -> (bool, string) result
val reconcile : config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> (unit, string) result
val discharge : config:Workspace.config -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  user_message:string -> checkpoint:Agent_core.Checkpoint.t -> admission -> (unit, string) result
