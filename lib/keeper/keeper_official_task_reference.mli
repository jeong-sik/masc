(** Historical text of an already admitted operation. No attachments or tool
    calls are re-dispatched by this reference. *)
type t
val create : operation_id:Keeper_chat_operation.Operation_id.t -> message:string ->
  original_turn:Keeper_semantic_execution.official_client_checkpoint -> t
val message : current:Keeper_semantic_execution.official_client_checkpoint option ->
  t -> (Agent_core.Types.message, string) result
val is_reference : Agent_core.Types.message -> bool
(** Whether the message is the one {!message} builds: it carries this
    module's metadata marker. *)
val require_preserved : reference:Agent_core.Types.message option ->
  Agent_core.Types.message list -> (unit, string) result
