
(** OAS boundary adapter for tool results, schemas, and tool definitions.

    Converts between MASC {!Tool_result.result} and
    OAS [{!Agent_sdk.Types.tool_result}].

    Also converts MASC JSON schemas to OAS [{!Agent_sdk.Types.tool_param}] lists,
    and creates OAS [{!Agent_sdk.Tool.t}] from MASC handler functions.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + OAS Tool.t creation *)

(** {1 Tool Output Externalization}

    Tool outputs above [externalize_threshold_bytes ()] are stored in
    the content-addressed blob store ([Tool_blob_store]) and the OAS
    [content] field carries a blob marker
    ([Tool_output.encode_for_oas (Stored ...)]).

    Disabled when [MASC_BASE_PATH] is unset OR when [MASC_TOOL_EXTERNALIZE]
    is one of [0|false|no|off]. *)

val default_externalize_threshold_bytes : int
(** Compile-time default; overridable via [MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES]. *)

val externalize_threshold_bytes : unit -> int
(** Resolved threshold in bytes. *)

val maybe_externalize : ?mime:string -> string -> string
(** Externalize when over threshold and a blob store is available;
    pass through otherwise. Storage failures are logged and fall back to the
    original [msg], preserving every output byte. *)

(** {1 Result Conversion} *)

val to_oas_typed_result : Tool_result.result -> Agent_sdk.Types.tool_result
(** Convert a {!Tool_result.result} to OAS [tool_result].  [Completed] and
    [Deferred] project one-way to OAS [Ok]; [Deferred] carries an opaque MASC
    disposition marker in [_meta].  The adapter never parses that metadata
    back into MASC semantics.  [Failed] maps its typed [failure_class] directly
    to OAS [recoverable]/[error_class]. *)

(** {1 Schema Conversion} *)

val param_type_of_string : string -> Agent_sdk.Types.param_type
(** Map JSON Schema type string to OAS [param_type].
    Unknown types default to [String]. *)

val params_of_json_schema : Yojson.Safe.t -> Agent_sdk.Types.tool_param list
(** Extract OAS [tool_param list] from a MASC [input_schema] JSON object.
    Reads ["properties"] and ["required"] fields. *)

(** {1 OAS Tool.t Creation} *)

val oas_tool_of_masc :
  ?descriptor:Agent_sdk.Tool.descriptor ->
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  (Yojson.Safe.t -> Tool_result.result) ->
  Agent_sdk.Tool.t
(** Create an OAS [Tool.t] from a MASC tool name, description,
    JSON input schema, and typed handler function.

    The handler receives raw JSON args and returns a {!Tool_result.result}.
    Conversion to OAS [tool_result] is applied automatically.

    An owning adapter may pass an explicit [descriptor]. The generic bridge
    never infers mutation, permission, or concurrency semantics from a tool
    name or catalog read-only flag. Without a descriptor OAS uses its ordinary
    sequential default. *)
