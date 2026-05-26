
(** Tool_agent - Agent management, metrics, and capability discovery handlers *)

type context = {
  config: Coord.config;
  agent_name: string;
}

(** Issue #8501: Variant SSOT for masc_agent_card.action.  Mirror in
    [Tool_schemas_agent.agent_card_action_enum_strings] (cycle-aware,
    sync regression test catches drift). *)
type agent_card_action =
  | Agent_card_get
  | Agent_card_refresh

val agent_card_action_to_string : agent_card_action -> string
val valid_agent_card_action_strings : string list

(** Dispatch handler. Returns Some Tool_result.result if handled, None otherwise *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option

val schemas : Masc_domain.tool_schema list

(** Handle masc_agents *)
val handle_agents :
  ?tool_name:string -> ?start_time:float ->
  context -> Yojson.Safe.t -> Tool_result.result

(** Handle masc_agent_update *)
val handle_agent_update :
  ?tool_name:string -> ?start_time:float ->
  context -> Yojson.Safe.t -> Tool_result.result

(** Handle masc_get_metrics *)
val handle_get_metrics :
  ?tool_name:string -> ?start_time:float ->
  context -> Yojson.Safe.t -> Tool_result.result

(** Handle masc_agent_fitness *)
val handle_agent_fitness :
  ?tool_name:string -> ?start_time:float ->
  context -> Yojson.Safe.t -> Tool_result.result

(** Handle masc_agent_card *)
val handle_agent_card :
  ?tool_name:string -> ?start_time:float ->
  context -> Yojson.Safe.t -> Tool_result.result
