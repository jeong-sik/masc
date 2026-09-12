(** Gate-specific direct continuation. Original ownership is checked against a
    retained exact snapshot; newer canonical history is preserved. *)
type admission
val checkpoint : admission -> Agent_core.Checkpoint.t option
val official_client : admission -> Keeper_semantic_execution.official_client_checkpoint option
val resolution : admission -> Keeper_event_queue.hitl_resolution
val source_reference : admission -> Keeper_checkpoint_ref.t option
val load : config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  operation_id:Keeper_chat_operation.Operation_id.t -> session_dir:string ->
  (admission option, string) result
val runtime_lane : admission -> Keeper_turn_driver.deferred_runtime_lane option
val suspend : ?official_client:(string * Keeper_repetition_snapshot.t) -> ?runtime_lane:Keeper_turn_driver.deferred_runtime_lane -> config:Workspace.config -> keeper_name:string ->
  operation_id:Keeper_chat_operation.Operation_id.t -> session_dir:string -> session_id:string ->
  approval_ids:string list -> unit -> (bool, string) result
val reconcile : config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> (unit, string) result
val discharge : config:Workspace.config -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  user_message:string -> checkpoint:Agent_core.Checkpoint.t -> admission -> (unit, string) result

(** A checkpoint-less Gate reconciliation is nonterminal but cannot supply a
    resume reference. The original request and obligations remain durable. *)
type pending = Bound_checkpoint of Keeper_checkpoint_ref.t | Bound_official_client of Keeper_semantic_execution.official_client_checkpoint | Checkpoint_reconciliation
val pending : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  (pending option, string) result

(** Called by the official adapter's post-write callback. The inputs are the
    prepared arguments passed to that adapter, not serialized wire bytes. The
    complete Gate message and stable replay identity must remain in those inputs. *)
val observe_native_input : ?blocks:Agent_core.Types.content_block list -> prepared:Keeper_gate_replay.model_message -> config:Workspace.config -> user_message:string -> admission -> transmitted:string -> (unit, string) result
(** Discharge only after transmitted input and a later native turn settled in the original session. *)
val complete_native : config:Workspace.config -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  admission -> (unit, string) result
(** After successful continuation, record completion for the existing spent-wake intake. *)
val record_completed : config:Workspace.config -> keeper_name:string -> admission ->
  (Keeper_approval_queue.continuation_projection_result, string) result
