type agent_view = {
  self : Trpg_world_projection.agent_state;
  visible_agents : Trpg_world_projection.agent_state list;
  events_since : Trpg_engine_event.t list;
  round : int;
  phase : string;
  available_skills : string list;
}

val filter :
  agent_name:string ->
  after_seq:int ->
  event_limit:int ->
  available_skills:string list ->
  Trpg_world_projection.world_state ->
  agent_view
