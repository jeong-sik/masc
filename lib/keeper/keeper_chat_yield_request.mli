(** An autonomous turn yields to any claimable person-chat operation. A
    direct turn passes its claimed operation ID and yields only to an original
    chat admitted later, never to an older queued continuation. *)

type turn = Autonomous | Direct of Keeper_chat_operation.Operation_id.t

val request :
  turn:turn ->
  base_path:string ->
  keeper_name:string ->
  (Keeper_agent_run.autonomous_yield_request option, string) result
