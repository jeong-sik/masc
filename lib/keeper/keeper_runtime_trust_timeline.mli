val json_member : string -> Yojson.Safe.t -> Yojson.Safe.t

val json_int_opt_member : string -> Yojson.Safe.t -> int option

val json_float_opt_member : string -> Yojson.Safe.t -> float option

val json_string_opt_member : string -> Yojson.Safe.t -> string option

val json_string_opt_value : Yojson.Safe.t -> string option

val json_bool_opt_member : string -> Yojson.Safe.t -> bool option

val json_string_list_member : string -> Yojson.Safe.t -> string list

val assoc_bool_default :
  string -> default:bool -> (string * Yojson.Safe.t) list -> bool

val assoc_string_opt : string -> (string * Yojson.Safe.t) list -> string option

val assoc_json_opt : string -> (string * Yojson.Safe.t) list -> Yojson.Safe.t option

val take : int -> 'a list -> 'a list

val goal_ids_of_json : Yojson.Safe.t -> string list

val keeper_turn_id_of_json : Yojson.Safe.t -> int option

val timeline_event_json :
  ?trace_id:string ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?goal_ids:string list ->
  ?next_human_action:string ->
  ?observed_at_unix:float ->
  ?observation_only:bool ->
  ts_unix:float ->
  kind:string ->
  title:string ->
  summary:string ->
  severity:string ->
  unit ->
  Yojson.Safe.t

val tool_call_timeline_event : Yojson.Safe.t -> Yojson.Safe.t option

val live_pending_approval_timeline_event :
  Yojson.Safe.t -> Yojson.Safe.t option

val approval_event_timeline_event : Yojson.Safe.t -> Yojson.Safe.t option

val decision_timeline_event : Yojson.Safe.t -> Yojson.Safe.t option

val transition_timeline_event : Yojson.Safe.t -> Yojson.Safe.t option

val receipt_timeline_event : Yojson.Safe.t -> Yojson.Safe.t option

val blocker_timeline_event :
  ?task_id:string ->
  ?goal_ids:string list ->
  ?trace_id:string ->
  ?observed_at_unix:float ->
  ts_unix:float ->
  runtime_blocker_fields:(string * Yojson.Safe.t) list ->
  next_human_action:string option ->
  ?observation_only:bool ->
  unit ->
  Yojson.Safe.t option

val latest_tool_call_json : keeper_name:string -> Yojson.Safe.t option

val pending_approval_json : base_path:string -> keeper_name:string -> Yojson.Safe.t

val sort_timeline_events : Yojson.Safe.t list -> Yojson.Safe.t list

val latest_causal_from_timeline : Yojson.Safe.t -> Yojson.Safe.t
