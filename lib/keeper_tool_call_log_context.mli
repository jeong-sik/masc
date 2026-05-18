(** Turn context helpers for keeper tool-call logging. *)

type turn_context =
  { agent_name : string option
  ; lane : string option
  ; tool_choice : string option
  ; thinking_enabled : bool option
  ; thinking_budget : int option
  ; prompt_fingerprint : string option
  ; trace_id : string option
  ; session_id : string option
  ; generation : int option
  ; turn : int option
  ; keeper_turn_id : int option
  ; task_id : string option
  ; goal_ids : string list option
  ; sandbox_profile : string option
  ; sandbox_root : string option
  ; allowed_paths : string list option
  ; network_mode : string option
  ; approval_mode : string option
  ; tool_surface_class : string option
  ; visible_tool_count : int option
  ; required_tools : string list option
  ; required_tool_candidates : string list option
  ; missing_required_tools : string list option
  ; cascade_profile : string option
  }

val set_turn_context :
  keeper_name:string ->
  ?agent_name:string ->
  ?lane:string ->
  ?tool_choice:string ->
  ?thinking_enabled:bool ->
  ?thinking_budget:int ->
  ?prompt_fingerprint:string ->
  ?trace_id:string ->
  ?session_id:string ->
  ?generation:int ->
  ?turn:int ->
  ?keeper_turn_id:int ->
  ?task_id:string ->
  ?goal_ids:string list ->
  ?sandbox_profile:string ->
  ?sandbox_root:string ->
  ?allowed_paths:string list ->
  ?network_mode:string ->
  ?approval_mode:string ->
  ?tool_surface_class:string ->
  ?visible_tool_count:int ->
  ?required_tools:string list ->
  ?required_tool_candidates:string list ->
  ?missing_required_tools:string list ->
  ?cascade_profile:string ->
  unit ->
  unit

val get_turn_context_record :
  keeper_name:string ->
  unit ->
  turn_context

val get_turn_context :
  keeper_name:string ->
  unit ->
  string option
  * string option
  * bool option
  * int option
  * string option
  * string option
  * string option
  * int option
  * int option
  * string option
  * string list option
  * string option
  * string option
  * string option

val optional_model : string option -> string option

val runtime_contract_json_for_call :
  keeper_name:string ->
  ?model:string ->
  unit ->
  Yojson.Safe.t

val action_radius_json_for_call :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  success:bool ->
  duration_ms:float ->
  ?error:string ->
  unit ->
  Yojson.Safe.t

val reset_for_testing : unit -> unit
