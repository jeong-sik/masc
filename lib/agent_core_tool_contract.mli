(** Agent_core_tool_contract — typed MASC agent-core tool projections over the
    canonical MCP operation set.

    Each {!type-agent_core_tool_binding} declares an agent-core tool name
    plus the canonical MCP operation it routes to and the per-argument
    {!type-arg_source} mapping that translates agent-core input JSON into
    canonical operation arguments. The runtime resolves agent-core calls
    via {!resolve_requested_tool_call}.

    Internal helpers ([identity_arg_bindings], [projection_of_name] /
    the [*_projection] bindings, [dedupe_strings],
    [find_property] / [assoc_members] / [int_member],
    [schema_type] / [label_or_default],
    [validate_json_value] / [validate_input_json], and
    [build_operation_arguments]) are hidden — callers consume the
    typed records, the lookup helpers, the canonical operation list,
    and the resolver entry points only.

    The [masc_batch_add_tasks] / [masc_broadcast] / [masc_heartbeat]
    bindings read their deliberately narrower descriptions and input
    schemas from the [agent_core_projection] tables of the tools' own
    [config/tools/masc_*.toml] declarations (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2); a missing or
    undecodable projection refuses the boot. *)

(** {1 Typed binding} *)

type arg_source =
  | Input_field of string
      (** Take the value of [field_name] from agent core input JSON. *)
  | Static of Yojson.Safe.t
      (** Inject a constant JSON value (typed in the binding). *)
  | Agent_name
      (** Inject the calling agent's name (sourced at resolve time). *)

type agent_core_tool_binding = {
  name : string;
  canonical_operation : string;
  description : string;
  input_schema : Yojson.Safe.t;
  arg_bindings : (string * arg_source) list;
}

(** {1 Catalog} *)

val agent_core_bindings : agent_core_tool_binding list
(** Canonical agent-core projection table. The single source of truth for
    agent-core names that need argument projection before dispatch. *)

val agent_core_binding_by_name : string -> agent_core_tool_binding option

val agent_core_aliases_for_operation :
  string -> agent_core_tool_binding list

val core_remote_operation_names : string list
(** Deduplicated union of [canonical_operation] values from
    {!agent_core_bindings} plus the hand-written core operation list
    (masc_operator_action / etc.). Used by the dashboard
    capability inventory and the discovery wiring. *)

val agent_core_tool_schemas : Masc_domain.tool_schema list
(** agent-core [Masc_domain.tool_schema] entries consumed by the
    managed-agent MCP discovery endpoint. *)

(** {1 Resolver} *)

val resolve_requested_tool_call :
  agent_name:string ->
  requested_name:string ->
  arguments:Yojson.Safe.t ->
  (string * Yojson.Safe.t, string) result
(** Translate an agent-core tool call into the canonical MCP operation:

    - When [requested_name] is not an agent-core projection, returns
      [Ok (requested_name, arguments)] unchanged.
    - When it is an agent-core projection, validates [arguments] against the
      binding's [input_schema] and projects them through
      [arg_bindings] into the canonical-operation argument shape.
    - [Error msg] surfaces schema validation failures verbatim. *)

(** {1 Schema introspection} *)

val required_names : Yojson.Safe.t -> string list
(** Top-level [required] array as a string list (empty when missing). *)

val property_map : Yojson.Safe.t -> (string * Yojson.Safe.t) list
(** Top-level [properties] table as an assoc list (empty when
    missing). *)

val string_member : string -> Yojson.Safe.t -> string option
(** Lookup a top-level string field on a JSON object; [None] when
    absent or wrong type. *)

(** {1 Discovery payload} *)

val agent_core_alias_json : agent_core_tool_binding -> Yojson.Safe.t
(** Project a single binding to the dashboard agent-core tool descriptor
    ([name] / [description] / [canonicalOperationId] /
    [inputSchema] / [argumentMapping] / [staticArguments] /
    [injectAgentName]). *)
