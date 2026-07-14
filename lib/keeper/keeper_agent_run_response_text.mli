(** Response text finalization for keeper agent runs. *)

type finalized = {
  response_text : string;
}

(** [true] for typed control checkpoints and no-output execution observations
    that must not manufacture a chat reply. Their state remains observable
    through typed stop/event surfaces. *)
val stop_reason_suppresses_visible_response : Runtime_agent.stop_reason -> bool

val finalize :
  completion_contract_result:Keeper_execution_receipt.completion_contract_result ->
  stop_reason:Runtime_agent.stop_reason ->
  raw_response_text:string ->
  ?suppress_response_text:bool ->
  unit ->
  finalized
