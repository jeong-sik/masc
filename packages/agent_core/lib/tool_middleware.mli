(** Tool call middleware — reusable strict validation primitives.

    Consumers (MCP servers, custom agent loops) use these to build their own
    tool dispatch pipelines without embedding [Agent.run].

    @since 0.101.0 *)

(** {1 Pre-hook action type}

    General-purpose middleware control flow for tool call pipelines.
    Consumers define pre-hooks as [name -> args -> pre_hook_action]. *)

type pre_hook_action =
  | Pass (** This hook has no opinion — continue to next hook or handler. *)
  | Reject of
      { is_error : bool
      ; message : string
      } (** Short-circuit with an error result.  The handler is never called. *)

(** {1 Validation convenience} *)

(** Validate [args] against [schema] without rewriting it. Returns [Pass] for
    an exact match and [Reject] with structured feedback for invalid input. *)
val validate_input
  :  tool_name:string
  -> schema:Types.tool_schema
  -> Yojson.Safe.t
  -> pre_hook_action

(** {1 Schema conversion}

    Convert JSON Schema objects to OAS typed parameter lists.
    Delegates to {!Mcp_schema.json_schema_to_params} for consumers
    that work with raw JSON schemas (e.g. MCP tool definitions). *)

(** Build a [Types.tool_schema] from a name and raw JSON Schema.
    Description defaults to [""].
    Extracts parameters via {!Mcp_schema.json_schema_to_params} and keeps the
    supplied schema as [input_schema], so the two views are derived from one
    source. Raises [Invalid_argument] when the schema cannot be converted. *)
val tool_schema_of_json
  :  name:string
  -> ?description:string
  -> Yojson.Safe.t
  -> Types.tool_schema

val tool_schema_of_json_result
  :  name:string
  -> ?description:string
  -> Yojson.Safe.t
  -> (Types.tool_schema, string) result

(** {1 Hook factory} *)

(** Create a validation pre-hook closure.

    The [lookup] function resolves tool names to schemas. Unknown tools are
    rejected explicitly. *)
val make_validation_hook
  :  lookup:(string -> Types.tool_schema option)
  -> name:string
  -> args:Yojson.Safe.t
  -> pre_hook_action
