(** RFC-0233 §2.2 — append one TurnRecord per keeper turn, at the same
    cadence as the execution receipt.

    Append failures never fail the turn: they log a WARN with the
    keeper/trace coordinates (the receipt path already guards turn
    integrity; this store is an observability surface). *)

val write :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:string ->
  absolute_turn:int ->
  runtime_profile:string ->
  model:string option ->
  finish_reason:string option ->
  sampling:Turn_record.sampling ->
  usage:Turn_record.usage ->
  execution_ids:Ids.Execution_id.t list ->
  blocks:Turn_record.prompt_block list ->
  unit ->
  unit
