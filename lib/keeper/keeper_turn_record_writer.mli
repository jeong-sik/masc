(** RFC-0233 §2.2 — append one TurnRecord per keeper turn, at the same
    cadence as the execution receipt. A committed autonomous record emits
    [keeper_chat_appended] so an open dashboard transcript re-reads its
    authoritative history without waiting for a page reload. Direct turns
    already emit that invalidation from their chat-store append path.

    Append failures never fail the turn: they log a WARN with the
    keeper/trace coordinates (the receipt path already guards turn
    integrity; this store is an observability surface). *)

val context_window_of_turn
  :  turn_budget:int
  -> [ `Produced_result | `Errored ]
  -> int option
(** Which number goes in a TurnRecord's [context_window].

    [turn_budget] is the ceiling this turn's prompt was shaped to. Under
    #28765 that is the minimum effective budget across the lane's candidates,
    so it is not the same number as the window declared by whichever candidate
    ended up serving the turn. Passing the serving runtime's own window here
    makes the dashboard's ctx-fill denominator larger than the ceiling the turn
    actually ran under.

    [`Errored] gives [None]: the turn_record contract asks for absence on the
    error path rather than a number the inspector would render as a real
    ceiling. *)

val write :
  config:Workspace.config ->
  keeper_name:string ->
  agent_name:string ->
  turn_kind:Turn_record.turn_kind ->
  trace_id:string ->
  absolute_turn:int ->
  runtime_profile:string ->
  selected_model:string option ->
  finish_reason:string option ->
  context_window:int option ->
  price_input_per_million:float option ->
  price_output_per_million:float option ->
  request_latency_ms:int option ->
  ttfrc_ms:float option ->
  request_wire_observation:Turn_record.request_wire_observation option ->
  model_input_window:Turn_record.model_input_window option ->
  raw_trace_run_ref:Turn_record.raw_trace_run_ref option ->
  sampling:Turn_record.sampling ->
  usage:Turn_record.usage ->
  execution_ids:Ids.Execution_id.t list ->
  blocks:Turn_record.prompt_block list ->
  input_components:Turn_record.input_component list option ->
  tool_surface_ref:string option ->
  unit ->
  unit
