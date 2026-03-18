type agent_view = {
  self : World_projection.agent_state;
  visible_agents : World_projection.agent_state list;
  events_since : Engine_event.t list;
  round : int;
  phase : string;
  available_skills : string list;
}

val filter :
  agent_name:string ->
  after_seq:int ->
  event_limit:int ->
  available_skills:string list ->
  World_projection.world_state ->
  agent_view
