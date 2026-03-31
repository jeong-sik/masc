(** OAS boundary adapter for tool results, schemas, and tool definitions.

    Converts between MASC tool conventions [(bool * string)] and
    OAS typed [{!Agent_sdk.Types.tool_result}].

    Also converts MASC JSON schemas to OAS [{!Agent_sdk.Types.tool_param}] lists,
    and creates OAS [{!Agent_sdk.Tool.t}] from MASC handler functions.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + OAS Tool.t creation *)

(** {1 Result Conversion} *)

val to_oas_tool_result :
  ?recoverable:bool -> bool * string -> Agent_sdk.Types.tool_result
(** Convert MASC [(success, message)] to OAS [tool_result].
    [recoverable] defaults to [true] for error cases. *)

val of_oas_tool_result : Agent_sdk.Types.tool_result -> bool * string
(** Convert OAS [tool_result] back to MASC [(success, message)]. *)

(** {1 Schema Conversion} *)

val param_type_of_string : string -> Agent_sdk.Types.param_type
(** Map JSON Schema type string to OAS [param_type].
    Unknown types default to [String]. *)

val params_of_json_schema : Yojson.Safe.t -> Agent_sdk.Types.tool_param list
(** Extract OAS [tool_param list] from a MASC [input_schema] JSON object.
    Reads ["properties"] and ["required"] fields. *)

(** {1 OAS Tool.t Creation} *)

val oas_tool_of_masc :
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  (Yojson.Safe.t -> bool * string) ->
  Agent_sdk.Tool.t
(** Create an OAS [Tool.t] from a MASC tool name, description,
    JSON input schema, and handler function.

    The handler receives raw JSON args and returns MASC [(bool * string)].
    Result conversion is applied automatically via {!to_oas_tool_result}. *)
