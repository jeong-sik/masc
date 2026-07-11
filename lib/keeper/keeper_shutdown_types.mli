(** Typed state carried by one Keeper lane while an operator shutdown is in
    progress.  This module is pure: persistence and registry mutation live in
    their owning modules. *)

type interrupted_turn_outcome = private
  | Continuation_required
  | Ambiguous_result of
      { committed_mutating_tools : string list
      ; event_bus_integrity_error : string option
      }

type interrupted_turn = private
  { keeper_name : string
  ; trace_id : Keeper_id.Trace_id.t
  ; turn_id : int
  ; current_task_id : Keeper_id.Task_id.t option
  ; interrupted_at : float
  ; outcome : interrupted_turn_outcome
  }

type persisted_interrupted_turn = private
  { record : interrupted_turn
  ; path : string
  }

type turn_settlement =
  | No_interrupted_turn
  | Awaiting_interrupted_turn of { turn_id : int }
  | Interrupted_turn_persisted of persisted_interrupted_turn
  | Interrupted_turn_persist_failed of
      { record : interrupted_turn
      ; error : string
      }

type state =
  | Not_requested
  | Requested of turn_settlement

val outcome_of_event_bus :
  committed_mutating_tools:string list ->
  event_bus_integrity_error:string option ->
  interrupted_turn_outcome

val make_interrupted_turn :
  keeper_name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  turn_id:int ->
  current_task_id:Keeper_id.Task_id.t option ->
  interrupted_at:float ->
  committed_mutating_tools:string list ->
  event_bus_integrity_error:string option ->
  interrupted_turn

val persisted_interrupted_turn :
  record:interrupted_turn -> path:string -> persisted_interrupted_turn

val interrupted_turn_outcome_label : interrupted_turn_outcome -> string
