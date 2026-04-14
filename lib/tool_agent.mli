(** Tool_agent - Agent management, metrics, and capability discovery handlers *)

type context = {
  config: Room.config;
  agent_name: string;
}

(** Dispatch handler. Returns Some (success, result) if handled, None otherwise *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> (bool * string) option

val schemas : Types.tool_schema list

(** Handle masc_agents *)
val handle_agents : context -> Yojson.Safe.t -> bool * string

(** Handle masc_register_capabilities *)
val handle_register_capabilities : context -> Yojson.Safe.t -> bool * string

(** Handle masc_agent_update *)
val handle_agent_update : context -> Yojson.Safe.t -> bool * string

(** Handle masc_find_by_capability *)
val handle_find_by_capability : context -> Yojson.Safe.t -> bool * string

(** Handle masc_get_metrics *)
val handle_get_metrics : context -> Yojson.Safe.t -> bool * string

(** Handle masc_agent_fitness *)
val handle_agent_fitness : context -> Yojson.Safe.t -> bool * string

(** Handle masc_select_agent *)
val handle_select_agent : context -> Yojson.Safe.t -> bool * string

(** Handle masc_collaboration_graph *)
val handle_collaboration_graph : context -> Yojson.Safe.t -> bool * string

(** Handle masc_preferred_partner *)
val handle_preferred_partner : context -> Yojson.Safe.t -> bool * string

(** Handle masc_consolidate_learning *)
val handle_consolidate_learning : context -> Yojson.Safe.t -> bool * string

(** Handle masc_agent_card *)
val handle_agent_card : context -> Yojson.Safe.t -> bool * string

(** Handle masc_meta_cognition_snapshot *)
val handle_meta_cognition_snapshot : context -> Yojson.Safe.t -> bool * string
