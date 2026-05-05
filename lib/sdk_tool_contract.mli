(** Sdk_tool_contract — typed MASC SDK tool aliases over the
    canonical MCP operation set.

    Each {!type-sdk_tool_binding} declares a public-facing tool name
    (e.g. [masc_list_tasks]) plus the canonical MCP operation it
    routes to ([masc_tasks]) and the per-argument
    {!type-arg_source} mapping that translates SDK input JSON into
    canonical operation arguments. The runtime resolves SDK calls
    via {!resolve_requested_tool_call}.

    Internal helpers (the [Tool_schema_dsl] [string_prop] /
    [object_schema] re-binds, [task_item_schema] /
    [assoc_field] / [json_string], [dedupe_strings],
    [find_property] / [assoc_members] / [int_member],
    [schema_type] / [label_or_default],
    [validate_json_value] / [validate_input_json],
    [param_type_of_schema_opt] / [param_type_of_schema] /
    [tool_params_of_input_schema], and [build_operation_arguments])
    are hidden — callers consume the typed records, the lookup
    helpers, the canonical operation list, and the resolver entry
    points only. *)

(** {1 Typed binding} *)

type arg_source =
  | Input_field of string
      (** Take the value of [field_name] from the SDK input JSON. *)
  | Static of Yojson.Safe.t
      (** Inject a constant JSON value (typed in the binding). *)
  | Agent_name
      (** Inject the calling agent's name (sourced at resolve time). *)

type sdk_tool_binding = {
  sdk_name : string;
  canonical_operation : string;
  description : string;
  input_schema : Yojson.Safe.t;
  arg_bindings : (string * arg_source) list;
  discovery_hidden : bool;
}

(** {1 Catalog} *)

val sdk_bindings : sdk_tool_binding list
(** Canonical SDK alias table. The single source of truth for which
    SDK names exist and how they map to MCP operations. *)

val sdk_binding_by_name : string -> sdk_tool_binding option

val sdk_aliases_for_operation :
  string -> sdk_tool_binding list

val core_remote_operation_names : string list
(** Deduplicated union of [canonical_operation] values from
    {!sdk_bindings} plus the hand-written core operation list
    (masc_join / decision_create / etc.). Used by the dashboard
    capability inventory and the discovery wiring. *)

val sdk_tool_schemas : Masc_domain.tool_schema list
(** SDK-facing [Masc_domain.tool_schema] entries (excluding bindings
    flagged [discovery_hidden]). Consumed by the public MCP
    discovery endpoint. *)

(** {1 Resolver} *)

val resolve_requested_tool_call :
  agent_name:string ->
  requested_name:string ->
  arguments:Yojson.Safe.t ->
  (string * Yojson.Safe.t, string) result
(** Translate an SDK tool call into the canonical MCP operation:

    - When [requested_name] is not an SDK alias, returns
      [Ok (requested_name, arguments)] unchanged.
    - When it is an SDK alias, validates [arguments] against the
      binding's [input_schema] and projects them through
      [arg_bindings] into the canonical-operation argument shape.
    - [Error msg] surfaces schema validation failures verbatim. *)

(** {1 Schema introspection (used by tests + dashboard)} *)

val required_names : Yojson.Safe.t -> string list
(** Top-level [required] array as a string list (empty when missing). *)

val property_map : Yojson.Safe.t -> (string * Yojson.Safe.t) list
(** Top-level [properties] table as an assoc list (empty when
    missing). *)

val string_member : string -> Yojson.Safe.t -> string option
(** Lookup a top-level string field on a JSON object; [None] when
    absent or wrong type. *)

val param_type_of_schema_opt :
  Yojson.Safe.t -> Agent_sdk.Types.param_type option
(** Strict JSON-Schema [type] classifier: [Some param_type] only for
    documented vocabulary ([string] / [integer] / [number] /
    [boolean] / [array] / [object]); [None] for non-vocabulary
    values like [null] / typos / tuple variants (#8832). *)

val param_type_of_schema : Yojson.Safe.t -> Agent_sdk.Types.param_type
(** Permissive variant of {!param_type_of_schema_opt} that defaults
    unknown / missing types to [String]. *)

(** {1 Discovery payload} *)

val sdk_alias_json : sdk_tool_binding -> Yojson.Safe.t
(** Project a single binding to the dashboard alias descriptor
    ([name] / [description] / [canonicalOperationId] /
    [inputSchema] / [argumentMapping] / [staticArguments] /
    [injectAgentName]). *)
