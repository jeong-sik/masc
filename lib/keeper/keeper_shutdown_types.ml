type interrupted_turn_outcome =
  | Continuation_required
  | Ambiguous_result of
      { committed_mutating_tools : string list
      ; event_bus_integrity_error : string option
      }

type interrupted_turn =
  { keeper_name : string
  ; trace_id : Keeper_id.Trace_id.t
  ; turn_id : int
  ; current_task_id : Keeper_id.Task_id.t option
  ; interrupted_at : float
  ; outcome : interrupted_turn_outcome
  }

type persisted_interrupted_turn =
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

let outcome_of_event_bus ~committed_mutating_tools ~event_bus_integrity_error =
  match committed_mutating_tools, event_bus_integrity_error with
  | [], None -> Continuation_required
  | tools, integrity_error ->
    Ambiguous_result
      { committed_mutating_tools = tools
      ; event_bus_integrity_error = integrity_error
      }
;;

let make_interrupted_turn
      ~keeper_name
      ~trace_id
      ~turn_id
      ~current_task_id
      ~interrupted_at
      ~committed_mutating_tools
      ~event_bus_integrity_error
  =
  { keeper_name
  ; trace_id
  ; turn_id
  ; current_task_id
  ; interrupted_at
  ; outcome =
      outcome_of_event_bus
        ~committed_mutating_tools
        ~event_bus_integrity_error
  }
;;

let persisted_interrupted_turn ~record ~path = { record; path }

let interrupted_turn_outcome_label = function
  | Continuation_required -> "continuation_required"
  | Ambiguous_result _ -> "ambiguous_result"
;;
