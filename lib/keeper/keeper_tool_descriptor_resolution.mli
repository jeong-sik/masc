(** Shared descriptor lookup for tool names observed at runtime.

    This module is the projection boundary from model/MCP/internal tool strings
    back to [Keeper_tool_descriptor]. Keep receipt and tool-call evidence lookup
    here so descriptor route evidence does not grow parallel name-resolution
    rules. *)

val descriptor_for_tool_name : string -> Keeper_tool_descriptor.t option

val canonical_internal_name_for_tool_name : string -> string option

val capability_sibling_names_for_tool_name : string -> string list
(** Every public, internal, and active model name owned by the resolved
    semantic capability. Unknown names return the empty list. Policy uses this
    projection so denying either side of a capability closes every sibling
    route. *)

val public_names_for_internal : string -> string list
(** Legacy-routable aliases for compatibility and denylist expansion. *)

val model_names_for_internal : string -> string list
(** Active model projection names for an internal route. *)

val public_model_names_for_internal_backend : string -> string list
(** Active public model projections for a backend-only internal route. Internal
    model projections deliberately return an empty list so valid Keeper tool
    calls are never rewritten to themselves. *)

val public_name_for_internal : string -> string option

val public_names_for_allowed_internal_names : string list -> string list

val model_names_for_allowed_internal_names : string list -> string list
(** Active model projections whose internal routes are in the supplied set. *)

(** [is_public_mcp_surface_name name] answers the narrow diagnostic question
    "is this runtime-observed name the descriptor-backed public MCP surface
    name?" Keep per-turn keeper classification behind this projection instead
    of letting turn setup query the MCP catalog directly. *)
val is_public_mcp_surface_name : string -> bool

val effect_domain_for_tool_name : string -> Tool_catalog.effect_domain option

val capability_has : Tool_capability.kind -> string -> bool

(** RFC-0331 — resolve a tool's typed {!Effect_class.t} from its declared
    registration. [Read_only] only when the tool declares itself read-only
    (via descriptor [readonly_hint] or [Tool_catalog] metadata); every
    unknown / undeclared tool is [Mutating] (fail-closed). The verifier
    consumes this instead of classifying free-text action descriptions. *)
val effect_class_for_tool_name : string -> Effect_class.t

val descriptor_and_input_for_tool_call :
  tool_name:string -> input:Yojson.Safe.t -> (Keeper_tool_descriptor.t * Yojson.Safe.t) option

val validate_public_input_for_tool_call :
  tool_name:string -> input:Yojson.Safe.t -> (Yojson.Safe.t, Tool_result.result) result option

val validated_descriptor_and_input_for_tool_call :
  tool_name:string ->
  input:Yojson.Safe.t ->
  ((Keeper_tool_descriptor.t * Yojson.Safe.t), Tool_result.result) result option

val readonly_for_tool_name : string -> bool option

val readonly_for_tool_call : tool_name:string -> input:Yojson.Safe.t -> bool option

val descriptors_for_tool_names : string list -> Keeper_tool_descriptor.t list
