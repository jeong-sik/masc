(** Shared persistence boundary for direct-operation attempts. Pending runtime
    retries cannot consume the original request's terminal assistant slot. *)
type settlement =
  | Runtime_deferred
  | Reply of string
  | Request_failed of string
val tool_delivery_key :
  operation_id:Keeper_chat_delivery_identity.Request_id.t ->
  resumed_from:Keeper_semantic_execution.gate_checkpoint option ->
  (Keeper_chat_delivery_identity.delivery_key, string) result
(** Same resolver for append ownership and post-append publication. *)

val committed_tool_events :
  operation_id:Keeper_chat_delivery_identity.Request_id.t ->
  resumed_from:Keeper_semantic_execution.gate_checkpoint option ->
  Keeper_chat_store.tool_call list ->
  (Keeper_chat_events.keeper_chat_event list, string) result
(** One commit event per call that has an execution identity, under the key
    {!persist} appended those rows with. Call it only after {!persist}
    succeeded for the same arguments. *)

val persist : base_dir:string -> keeper_name:string ->
  operation_id:Keeper_chat_delivery_identity.Request_id.t ->
  resumed_from:Keeper_semantic_execution.gate_checkpoint option -> settlement:settlement ->
  tool_calls:Keeper_chat_store.tool_call list ->
  ?surface:Surface_ref.t -> ?conversation_id:string ->
  ?blocks:Keeper_chat_store.chat_block list -> ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:Keeper_chat_store.stream_lifecycle_event list -> unit -> (unit, string) result
