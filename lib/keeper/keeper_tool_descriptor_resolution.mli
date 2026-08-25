(** Shared descriptor lookup for tool names observed at runtime.

    This module is the projection boundary from model/MCP/internal tool strings
    back to [Keeper_tool_descriptor]. Keep receipt and tool-call evidence lookup
    here so descriptor route evidence does not grow parallel name-resolution
    rules. *)

val descriptor_for_tool_name : string -> Keeper_tool_descriptor.t option

val public_names_for_internal : string -> string list

val public_name_for_internal : string -> string option

val public_names_for_allowed_internal_names : string list -> string list

(** [is_public_mcp_surface_name name] answers the narrow diagnostic question
    "is this runtime-observed name the descriptor-backed public MCP surface
    name?" Keep per-turn keeper classification behind this projection instead
    of letting turn setup query the MCP catalog directly. *)
val capability_has : Tool_capability.kind -> string -> bool

val prepare_model_input_for_descriptor :
  tool_name:string ->
  Keeper_tool_descriptor.t ->
  input:Yojson.Safe.t ->
  (Yojson.Safe.t, Tool_result.result) result

val validated_descriptor_and_input_for_tool_call :
  tool_name:string ->
  input:Yojson.Safe.t ->
  ((Keeper_tool_descriptor.t * Yojson.Safe.t), Tool_result.result) result option

val readonly_for_tool_call : tool_name:string -> input:Yojson.Safe.t -> bool option

type runtime_decision_outcome =
  | Route_hit of { internal : string }
  | Already_internal of { canonical : string }
  | Miss
(** Typed runtime tool-name resolution over the descriptor-owned routes. *)

val runtime_decision : string -> runtime_decision_outcome
(** Resolve a runtime or model tool name without telemetry side effects. *)

val canonical_tool_name : string -> string
(** Pure canonical internal-name projection. Unknown names are unchanged. *)

