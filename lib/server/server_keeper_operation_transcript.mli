(** Shared persistence boundary for direct-operation attempts. Pending runtime
    retries cannot consume the original request's terminal assistant slot. *)
type settlement =
  | Runtime_deferred
  | Terminal of { content : string; kind : Keeper_chat_store.Row_kind.t }
val persist : base_dir:string -> keeper_name:string ->
  operation_id:Keeper_chat_delivery_identity.Request_id.t ->
  resumed_from:Keeper_semantic_execution.gate_checkpoint option -> settlement:settlement ->
  tool_calls:Keeper_chat_store.tool_call list ->
  ?surface:Surface_ref.t -> ?conversation_id:string ->
  ?blocks:Keeper_chat_store.chat_block list -> ?turn_ref:Ids.Turn_ref.t ->
  ?stream_lifecycle:Keeper_chat_store.stream_lifecycle_event list -> unit -> (unit, string) result
