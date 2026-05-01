open Base

(** Tool_agent - Agent management, metrics, and capability discovery handlers *)

type context = {
  config: Coord.config;
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

(** Handle masc_get_metrics *)
val handle_get_metrics : context -> Yojson.Safe.t -> bool * string

(** Handle masc_agent_fitness *)
val handle_agent_fitness : context -> Yojson.Safe.t -> bool * string
