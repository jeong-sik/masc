(** Worker_container — Worker state machine, meta serialization, checkpoint/turn-log persistence, and file path management. *)

type worker_container_state =
  | Worker_missing
  | Worker_pending
  | Worker_ready

type tool_profile =
  | Profile_session_min
  | Profile_session_dev

type shell_profile =
  | Shell_none
  | Shell_readonly
  | Shell_dev

type worker_container_meta = {
  version : int;
  worker_name : string;
  mcp_session_id : string;
  team_session_id : string option;
  workspace_path : string;
  role : string option;
  selection_note : string option;
  execution_scope : Team_session_types.execution_scope;
  thinking_enabled : bool option;
  max_turns_override : int option;
  timeout_seconds : int option;
  tool_profile : tool_profile;
  shell_profile : shell_profile;
  worker_class : Team_session_types.worker_class option;
  worker_size : Team_session_types.worker_size option;
  effective_model : string;
  effective_tier : Team_session_types.model_tier option;
  checkpoint_path : string;
  turn_log_path : string;
  last_run_at : float option;
}

val configured_backend : unit -> [> `Legacy | `Oas ]

val tool_profile_to_string : tool_profile -> string
val tool_profile_of_string : string -> tool_profile option
val shell_profile_to_string : shell_profile -> string
val shell_profile_of_string : string -> shell_profile option

val safe_worker_token : string -> string

val worker_container_root :
  base_path:string -> team_session_id:string option -> string

val worker_container_dir :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  string

val worker_meta_path :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  string

val worker_checkpoint_path :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  string

val worker_turn_log_path :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  string

val worker_raw_trace_path :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  string

val oas_trace_session_root : base_path:string -> string

val ensure_worker_container_dirs :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  unit

val stable_worker_session_id :
  ?team_session_id:string -> string -> string

val oas_worker_evidence_session_id : worker_run_id:string -> string

val evidence_session_id_of_worker_run : string option -> string option

val session_min_tool_names : string list

val execution_scope_or_default :
  Team_session_types.execution_scope option -> Team_session_types.execution_scope

val infer_model_tier_from_model_name :
  string -> Team_session_types.model_tier option

val worker_profiles_of_scope :
  Team_session_types.execution_scope -> tool_profile * shell_profile

val derive_effective_tier :
  Team_session_types.worker_size option ->
  string ->
  Team_session_types.model_tier option

val effective_worker_size :
  Team_session_types.worker_size option ->
  string ->
  Team_session_types.worker_size option

val worker_meta_to_yojson : worker_container_meta -> Yojson.Safe.t
val worker_meta_of_yojson : Yojson.Safe.t -> worker_container_meta option

val load_worker_meta :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  worker_container_meta option

val save_worker_meta :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  worker_container_meta ->
  (unit, string) result

val get_worker_container_state :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  worker_container_state

val load_worker_checkpoint :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  Agent_sdk.Checkpoint.t option

val save_worker_checkpoint :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  Agent_sdk.Checkpoint.t ->
  (unit, string) result

val append_worker_turn_log :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  Yojson.Safe.t ->
  (unit, string) result

val resolved_mcp_session_id :
  base_path:string ->
  team_session_id:string option ->
  worker_name:string ->
  string
