type tool_surface =
  { turn_lane : string
  ; tool_surface_class : string
  ; tool_requirement : string
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  ; required_tools : string list
  ; missing_required_tools : string list
  }

type cascade_rotation_attempt =
  { from_cascade : string
  ; to_cascade : string
  ; reason : string
  ; outcome : string
  ; error_kind : string option
  ; error_message : string option
  ; recorded_at : string
  }

type t =
  { keeper_name : string
  ; agent_name : string
  ; trace_id : string
  ; generation : int
  ; turn_count : int option
  ; current_task_id : string option
  ; goal_ids : string list
  ; outcome : string
  ; terminal_reason_code : string
  ; response_text_present : bool
  ; model_used : string option
  ; requested_tools : string list
  ; reported_tools : string list
  ; observed_tools : string list
  ; canonical_tools : string list
  ; unexpected_tools : string list
  ; tools_used : string list
  ; tool_contract_result : string
  ; tool_surface : tool_surface
  ; sandbox_kind : string
  ; sandbox_root : string option
  ; network_mode : string
  ; approval_profile : string option
  ; approval_profile_derived : bool
  ; cascade_name : string
  ; cascade_selected_model : string option
  ; cascade_attempt_count : int
  ; cascade_fallback_applied : bool
  ; cascade_outcome : string
  ; degraded_retry_applied : bool
  ; degraded_retry_cascade : string option
  ; fallback_reason : string option
  ; cascade_rotation_attempts : cascade_rotation_attempt list
  ; stop_reason : string option
  ; error_kind : string option
  ; error_message : string option
  ; started_at : string
  ; ended_at : string
  }

val stop_reason_to_string : Oas_worker.stop_reason -> string
val sandbox_kind_of_meta : Keeper_types.keeper_meta -> string
val to_json : t -> Yojson.Safe.t
val append : Coord.config -> t -> unit
val latest_json : Coord.config -> string -> Yojson.Safe.t option
val latest_json_by_keeper :
  Coord.config -> string list -> (string * Yojson.Safe.t) list
