(** OAS boundary adapter for tool results, schemas, and tool definitions.

    Converts between MASC tool conventions [(bool * string)] and
    OAS typed [{!Agent_sdk.Types.tool_result}].

    Also converts MASC JSON schemas to OAS [{!Agent_sdk.Types.tool_param}] lists,
    and creates OAS [{!Agent_sdk.Tool.t}] from MASC handler functions.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + OAS Tool.t creation *)

(** {1 Tool Output Externalization}

    Tool outputs above [externalize_threshold_bytes ()] are stored in
    the content-addressed blob store ([Tool_blob_store]) and the OAS
    [content] field carries a sentinel marker
    ([Tool_output.encode_for_oas (Stored ...)]).

    Disabled when [MASC_BASE_PATH] is unset OR when [MASC_TOOL_EXTERNALIZE]
    is one of [0|false|no|off]. *)

(** Compile-time default; overridable via [MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES]. *)
val default_externalize_threshold_bytes : int

(** Resolved threshold in bytes. *)
val externalize_threshold_bytes : unit -> int

(** Externalize when over threshold and a blob store is available;
    pass through otherwise. Best-effort — storage failures fall back to
    the original [msg]. *)
val maybe_externalize : ?mime:string -> string -> string

(** {1 Result Conversion} *)

(** Convert MASC [(success, message)] to OAS [tool_result].
    [recoverable] defaults to [true] for error cases.
    Large [message] values are externalized via {!maybe_externalize}. *)
val to_oas_tool_result : ?recoverable:bool -> bool * string -> Agent_sdk.Types.tool_result

(** Convert OAS [tool_result] back to MASC [(success, message)]. *)
val of_oas_tool_result : Agent_sdk.Types.tool_result -> bool * string

(** {1 Schema Conversion} *)

(** Map JSON Schema type string to OAS [param_type].
    Unknown types default to [String]. *)
val param_type_of_string : string -> Agent_sdk.Types.param_type

(** Extract OAS [tool_param list] from a MASC [input_schema] JSON object.
    Reads ["properties"] and ["required"] fields. *)
val params_of_json_schema : Yojson.Safe.t -> Agent_sdk.Types.tool_param list

(** {1 OAS Tool.t Creation} *)

(** Create an OAS [Tool.t] from a MASC tool name, description,
    JSON input schema, and handler function.

    The handler receives raw JSON args and returns MASC [(bool * string)].
    Result conversion is applied automatically via {!to_oas_tool_result}. *)
val oas_tool_of_masc
  :  name:string
  -> description:string
  -> input_schema:Yojson.Safe.t
  -> (Yojson.Safe.t -> bool * string)
  -> Agent_sdk.Tool.t
