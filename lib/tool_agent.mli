open Base

(** Tool_agent - Agent management, metrics, and capability discovery handlers *)

type context = {
  config: Coord.config;
  agent_name: string;
}

(** Issue #8501: Variant SSOT for masc_agent_card.action.  Mirror in
    [Tool_schemas_agent.agent_card_action_enum_strings] (cycle-aware,
    sync regression test catches drift). *)
type agent_card_action = Get | Refresh
val agent_card_action_to_string : agent_card_action -> string
val agent_card_action_of_string_opt : string -> agent_card_action option
val all_agent_card_actions : agent_card_action list
val valid_agent_card_action_strings : string list

(** Issue #8501: Variant SSOT for masc_collaboration_graph.format.
    Mirror in [Tool_schemas_agent.collaboration_format_enum_strings]. *)
type collaboration_format = Text | Json
val collaboration_format_to_string : collaboration_format -> string
val collaboration_format_of_string_opt : string -> collaboration_format option
val all_collaboration_formats : collaboration_format list
val valid_collaboration_format_strings : string list

(** Dispatch handler. Returns Some (success, result) if handled, None otherwise *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> (bool * string) option

val schemas : Types.tool_schema list

(** Handle masc_agents *)
val handle_agents : context -> Yojson.Safe.t -> bool * string

(** Handle masc_register_capabilities *)
val handle_register_capabilities : context -> Yojson.Safe.t -> bool * string

(** Handle masc_agent_update *)
val handle_agent_update : context -> Yojson.Safe.t -> bool * string

(** Handle masc_get_metrics *)
val handle_get_metrics : context -> Yojson.Safe.t -> bool * string

(** Handle masc_agent_fitness *)
val handle_agent_fitness : context -> Yojson.Safe.t -> bool * string

(** Handle masc_collaboration_graph *)
val handle_collaboration_graph : context -> Yojson.Safe.t -> bool * string

(** Handle masc_agent_card *)
val handle_agent_card : context -> Yojson.Safe.t -> bool * string
