(** Cooperative direct-turn continuation from retained canonical checkpoint bytes.
    No provider retry is invented and the admitted input is not appended again. *)
type admission
val checkpoint : admission -> Agent_core.Checkpoint.t
val load : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  session_dir:string -> session_id:string -> (admission option, string) result
val consume : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  admission -> (unit, string) result
val defer : base_path:string -> keeper_name:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  session_dir:string -> session_id:string -> (unit, string) result
