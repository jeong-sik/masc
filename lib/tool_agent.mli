
(** Tool_agent - Agent metrics, fitness, and card handlers. *)

type context = {
  config: Workspace.config;
  agent_name: string;
}

(** Issue #8501: Variant SSOT for masc_agent_card.action.  Mirror in
    [Tool_schemas_agent.agent_card_action_enum_strings] (cycle-aware,
    sync regression test catches drift). *)
type agent_card_action =
  | Agent_card_get
  | Agent_card_refresh

val valid_agent_card_action_strings : string list

(** Dispatch handler. Returns Some Tool_result.result if handled, None otherwise *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option

(** JSON success result with [~data:json], consolidated here so sibling
    [Tool_*] modules share one construction path. *)
val json_ok :
  tool_name:string -> start_time:float -> Yojson.Safe.t -> Tool_result.result

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
