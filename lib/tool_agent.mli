
(** Tool_agent - Agent management, metrics, and capability discovery handlers *)

type context = {
  config: Coord.config;
  agent_name: string;
}

(** Issue #8501: Variant SSOT for masc_agent_card.action.  Mirror in
    [Tool_schemas_agent.agent_card_action_enum_strings] (cycle-aware,
    sync regression test catches drift). *)

(** Issue #8501: Variant SSOT for masc_collaboration_graph.format.
    Mirror in [Tool_schemas_agent.collaboration_format_enum_strings]. *)

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

(** Handle masc_agent_card *)
