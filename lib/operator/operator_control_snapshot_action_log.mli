(** Operator action-log persistence and dashboard projection. *)

type action_result_status =
  | ActionOk
  | ActionError

val action_result_status_to_string : action_result_status -> string

type confirmation_state =
  | Preview
  | Immediate
  | Expired
  | Denied
  | Confirmed

val confirmation_state_to_string : confirmation_state -> string

type action_log_entry =
  { trace_id : string
  ; actor : string
  ; remote_session_id : string option
  ; remote_client_type : string
  ; action_type : string
  ; target_type : string
  ; target_id : string option
  ; delegated_tool : string
  ; confirmation_state : confirmation_state
  ; result_status : action_result_status
  ; latency_ms : int
  ; created_at : string
  }

val action_log_path : Coord.config -> string
val action_log_entry_to_yojson : action_log_entry -> Yojson.Safe.t
val append_action_log : Coord.config -> action_log_entry -> unit
val recent_actions_json : Coord.config -> Yojson.Safe.t
