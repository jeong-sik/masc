(** Core task-tool handlers extracted from [Tool_task]. *)

type context =
  { config : Workspace_core.config
  ; agent_name : string
  ; sw : Eio.Switch.t option
  }

type task_owner_hooks =
  { is_registered_agent_alias : Workspace_core.config -> string -> bool
  ; sync_current_task_binding : Workspace_core.config -> agent_name:string -> unit
  ; active_goal_phases_for_agent :
      Workspace_core.config -> agent_name:string -> string list
  }

val record_verdict_fn :
  (task_id:string ->
   req:Anti_rationalization.review_request ->
   result:Anti_rationalization.review_result ->
   unit ->
   unit)
    Atomic.t

val sse_broadcast_fn : (Yojson.Safe.t -> unit) Atomic.t
val get_few_shot_block_fn : (unit -> string) Atomic.t
val push_event_to_sessions_fn : (Yojson.Safe.t -> unit) Atomic.t

val set_task_owner_hooks : task_owner_hooks -> unit
val current_task_owner_hooks : unit -> task_owner_hooks

include module type of Tool_task_payloads
include module type of Tool_task_args
include module type of Tool_task_completion_review

val strict_release_requires_handoff : Masc_domain.task option -> bool

val completion_state_error :
  task_id:string ->
  agent_name:string ->
  task_opt:Masc_domain.task option ->
  Masc_domain.masc_error option

val result_to_response :
  tool_name:string ->
  start_time:float ->
  (string, Masc_domain.masc_error) result ->
  Tool_result.result

val log_task_transition_failed :
  agent_name:string -> Masc_domain.masc_error -> unit

val client_side_transition_gate_error :
  task_opt:Masc_domain.task option ->
  action:Masc_domain.task_action ->
  action_s:string ->
  Masc_domain.Task_error.t option

val sync_planning_current_task_with_owned_task : context -> unit
val sync_owner_current_task_binding : context -> unit
val review_completion_notes :
  completion_contract:string list option ->
  evaluator_runtime:string option ->
  ctx:context ->
  task_opt:Masc_domain.task option ->
  task_id:string ->
  notes:string ->
  evidence_refs:string list ->
  Masc_domain.configured_llm_completion_verdict option

val handle_add_task :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result

(** RFC-0267 Phase 2: [masc_task_set_goal] — assign an existing goalless task to
    a goal. Thin adapter over {!Task_goal_assignment.set_task_goal}. *)
val handle_set_goal :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result

val handle_batch_add_tasks :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result

val handle_claim :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result

val handle_claim_next :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result

val handle_release :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
