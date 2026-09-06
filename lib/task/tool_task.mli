
(** Tool_task - Core task CRUD operations *)

type context = {
  config: Workspace_core.config;
  agent_name: string;
  sw: Eio.Switch.t option;
}

val handle_add_task :
  ?created_by:string ->
  tool_name:string ->
  start_time:float ->
  context ->
  Yojson.Safe.t ->
  Tool_result.result
val handle_batch_add_tasks :
  ?created_by:string ->
  tool_name:string ->
  start_time:float ->
  context ->
  Yojson.Safe.t ->
  Tool_result.result
val handle_claim : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_claim_next : tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_done :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val handle_transition :
  tool_name:string -> start_time:float -> context -> Yojson.Safe.t -> Tool_result.result
val task_history_events_json :
  Workspace_core.config -> task_id:string -> limit:int -> Yojson.Safe.t

val dispatch :
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option

(** Keeper-model dispatch exposes verification evidence through the
    keeper-scoped task-list projection. *)
val dispatch_for_keeper :
  created_by:string ->
  context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option

(** [build_claim_observation_payload ~now ~agent_name ~task_id ~scope_widened]
    builds the downstream collaboration-observation fragment for a successful
    [keeper_task_claim] write/readback result. [scope_widened] records whether
    the claim widened the agent's goal scope. MASC uses a central workspace
    store here, so CRDT-specific [logical_clock] and [convergence_delay_ms]
    are left null. *)
val build_claim_observation_payload :
  now:float ->
  agent_name:string ->
  task_id:string ->
  scope_widened:bool ->
  Yojson.Safe.t
