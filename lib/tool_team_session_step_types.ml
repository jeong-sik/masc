(** Tool_team_session_step types — type definitions for step handling. *)

(** Extracted handle_step logic for team session step operations.

    Contains the canonical write entrypoint for team sessions.
    Moved from tool_team_session.ml to reduce file size.

    Depends on parent module via [step_deps] record to avoid circular deps. *)

module Oas = Agent_sdk

(** Spawn specification parsed from MCP tool arguments. *)
type spawn_spec = {
  spawn_agent : string;
  spawn_prompt : string;
  spawn_model : string option;
  spawn_model_explicit : bool;
  spawn_role : string option;
  execution_scope : Team_session_types.execution_scope option;
  thinking_enabled : bool option;
  thinking_budget : int option;
  max_turns : int option;
  worker_class : Team_session_types.worker_class option;
  worker_size : Team_session_types.worker_size option;
  parent_actor : string option;
  capsule_mode : Team_session_types.capsule_mode option;
  runtime_pool : string option;
  lane_id : string option;
  control_domain : Team_session_types.control_domain option;
  supervisor_actor : string option;
  model_tier : Team_session_types.model_tier option;
  model_tier_explicit : bool;
  task_profile : Team_session_types.task_profile option;
  risk_level : Team_session_types.risk_level option;
  routing_confidence : float option;
  routing_reason : string option;
  spawn_selection_note : string option;
  spawn_timeout_seconds : int;
}

(** Prepared spawn with resolved runtime assignment. *)
type prepared_spawn = {
  worker_run_id : string;
  spec : spawn_spec;
  runtime_actor_name : string option;
  runtime_model_label : string;
  runtime_lease : Local_runtime_pool.lease option;
  assigned_runtime : string option;
}

(** OAS worker evidence payload for trace integration. *)
type oas_worker_evidence = {
  trace_ref : Oas.Raw_trace.run_ref option;
  trace_summary_json : Yojson.Safe.t option;
  trace_validation_json : Yojson.Safe.t option;
  worker_json : Yojson.Safe.t option;
  conformance_json : Yojson.Safe.t option;
  worker : Oas.Sessions.worker_run option;
  tool_call_traces_json : Yojson.Safe.t list;
  tool_input_preview : string option;
  tool_args_preview : string option;
  tool_output_preview : string option;
}

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

type result = bool * string

(** Dependency record — all functions from the parent module that handle_step needs.
    Avoids circular dependency between tool_team_session and this module. *)
type step_deps = {
  json_error : string -> string;
  json_ok : (string * Yojson.Safe.t) list -> string;
  get_valid_session_id : Yojson.Safe.t -> (string, string) Result.t;
  ensure_session_access : 'a. 'a context -> string -> (unit, string) Result.t;
  parse_step_spawn_specs : Yojson.Safe.t -> (spawn_spec list, string) Result.t;
  annotate_control_hierarchy_for_session :
    Team_session_types.session -> spawn_spec list -> spawn_spec list;
  parse_turn_kind :
    Yojson.Safe.t -> (Team_session_types.turn_kind, string) Result.t;
  parse_turn_kind_opt :
    Yojson.Safe.t -> (Team_session_types.turn_kind option, string) Result.t;
  parse_wait_mode : Yojson.Safe.t -> Team_session_types.wait_mode;
  int_opt_to_json : int option -> Yojson.Safe.t;
  float_opt_to_json : float option -> Yojson.Safe.t;
  truncate_for_event : ?max_len:int -> string -> string;
  make_worker_run_id : unit -> string;
  derived_local_runtime_actor : session_id:string -> prompt:string -> string;
  is_local_spawn_agent : string -> bool;
  effective_execution_scope_of_spec :
    spawn_spec -> Team_session_types.execution_scope option;
  worker_size_of_spec : spawn_spec -> Team_session_types.worker_size option;
  inferred_controller_level_of_spec :
    spawn_spec -> Team_session_types.controller_level option;
  planned_worker_of_spec :
    ?runtime_actor:string ->
    spawn_spec ->
    Team_session_types.planned_worker;
  register_planned_workers :
    Room.config ->
    string ->
    Team_session_types.planned_worker list ->
    (unit, string) Result.t;
  ensure_session_actor :
    Room.config -> string -> string -> (unit, string) Result.t;
  record_session_turn_json :
    config:Room.config ->
    session_id:string ->
    actor:string ->
    turn_kind:Team_session_types.turn_kind ->
    message:string option ->
    target_agent:string option ->
    task_title:string option ->
    task_description:string option ->
    task_priority:int ->
    (Yojson.Safe.t, string) Result.t;
  resolve_target_worker_name :
    Room.config -> Team_session_types.session -> string -> string option;
  session_has_turn_for_actor :
    Room.config -> string -> string -> bool;
  auto_note_message_of_spawn_output : string -> string option;
  reconcile_failed_spawn_actor :
    Room.config ->
    string ->
    string ->
    ([ `Retained | `Detached ], string) Result.t;
  extract_vote_id : string -> string option;
  oas_worker_evidence_payload :
    config:Room.config ->
    evidence_session_id:string ->
    oas_worker_evidence option;
  oas_trace_capability_to_string :
    Oas.Sessions.trace_capability -> string;
  oas_worker_status_to_json :
    Oas.Sessions.worker_status -> Yojson.Safe.t;
  worker_run_status_to_json :
    [ `Accepted | `Ready | `Running | `Completed | `Failed ] -> Yojson.Safe.t;
  raw_trace_run_ref_to_json : Oas.Raw_trace.run_ref -> Yojson.Safe.t;
  raw_trace_session_payloads :
    config:Room.config ->
    fallback_session_id:string ->
    Oas.Raw_trace.run_ref ->
    (Yojson.Safe.t * Yojson.Safe.t) option;
}
