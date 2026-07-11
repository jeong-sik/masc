(** Response text finalization for keeper agent runs. *)

type finalized = {
  response_text : string;
}

(** [stop_reason_is_turn_budget_exhausted sr] is true when the turn ended due
    to the runtime turn budget being exhausted (vs a clean Complete or
    mutation-boundary stop). Used by finalize to tag budget-limited turns. *)
val stop_reason_is_turn_budget_exhausted : Runtime_agent.stop_reason -> bool

(** [true] only for typed control checkpoints that must not manufacture a
    chat reply. The checkpoint remains observable through its stop/event
    surfaces. *)
val stop_reason_suppresses_visible_response : Runtime_agent.stop_reason -> bool

val completion_contract_suppresses_visible_response :
  history_assistant_source:string ->
  Keeper_execution_receipt.completion_contract_result ->
  bool

val finalize :
  completion_contract_result:Keeper_execution_receipt.completion_contract_result ->
  stop_reason:Runtime_agent.stop_reason ->
  raw_response_text:string ->
  ?suppress_response_text:bool ->
  unit ->
  finalized
