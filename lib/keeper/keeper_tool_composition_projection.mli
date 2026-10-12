(** Pure composition result and failure projection. *)
val tool_kind_field : Keeper_tool_descriptor.tool_kind -> string * Yojson.Safe.t
val with_tool_kind_field : Keeper_tool_descriptor.tool_kind -> Yojson.Safe.t -> Yojson.Safe.t
val node_observation_result : Keeper_tool_plan_executor.node_result -> Tool_result.result
val wire_outcome_of_result : Tool_result.result -> Tool_result.tool_call_outcome
val node_result_to_json : Keeper_tool_plan_executor.node_result -> Yojson.Safe.t
val failure_payload : tool_name:string -> tool_kind:Keeper_tool_descriptor.tool_kind -> cause:Yojson.Safe.t -> effect_disposition:string -> settled:Yojson.Safe.t list -> Yojson.Safe.t
val failure_data : tool_name:string -> tool_kind:Keeper_tool_descriptor.tool_kind -> Keeper_tool_plan_executor.failure -> Yojson.Safe.t

type composition_projection =
  | Terminal_cause of Keeper_terminal_effect_detail.composition_cause
  | Pre_effect_only of
      { expected : Agent_core.Tool_contract.completion
      ; actual : Agent_core.Tool_contract.completion
      }

val composition_cause : Keeper_tool_plan_executor.failure -> composition_projection
val failure_class : Keeper_tool_plan_executor.failure -> Tool_result.tool_failure_class
val evidence_nodes_of_execution : (Keeper_tool_plan_executor.node_result list, Keeper_tool_plan_executor.failure) result -> Yojson.Safe.t list
