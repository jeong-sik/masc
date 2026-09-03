
(** AGENT_CORE boundary adapter for tool results, schemas, and tool definitions.

    Converts between MASC {!Tool_result.result} and
    AGENT_CORE [{!Agent_core.Types.tool_result}].

    Also converts MASC JSON schemas to AGENT_CORE [{!Agent_core.Types.tool_param}] lists,
    and creates AGENT_CORE [{!Agent_core.Tool.t}] from MASC handler functions.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + AGENT_CORE Tool.t creation *)

(** {1 Tool Output Externalization}

    Tool outputs above [default_externalize_threshold_bytes] are stored in
    the content-addressed blob store ([Tool_blob_store]) and the AGENT_CORE
    [content] field carries a blob marker
    ([Tool_output.encode_for_agent_core (Stored ...)]). The marker remains the
    provider-bound representation; exact bytes are retrieved explicitly from
    the artifact store rather than re-inflated into later requests.
    Blob bytes and their parent directory are synced before the marker is
    returned, so a later durable checkpoint cannot get ahead of its artifact.

    Disabled unless the caller supplies [base_path]. Each model-visible tool
    descriptor owns its typed projection policy; the default uses MASC's
    canonical tool-output budget. *)

val default_externalize_threshold_bytes : int
(** Canonical MASC tool-output budget used by the default projection. *)

type projection_error_kind =
  | Artifact_storage_failure
  | Inline_budget_exceeded

type externalization_error =
  { kind : projection_error_kind
  ; message : string
  }

val attach_artifact_manifest :
  base_path:string ->
  Tool_result.result ->
  (Tool_result.result, externalization_error) result
(** Persist and attach the canonical manifest for typed result data containing
    normalized artifact references. Producers call this inside their effect
    boundary, before returning the authoritative result. Results without
    artifact references pass through unchanged. Cancellation propagates. *)

val maybe_externalize :
  ?base_path:string ->
  ?mime:string ->
  ?threshold_bytes:int ->
  string ->
  (string, externalization_error) result
(** Externalize when over threshold and a blob store is available;
    pass through otherwise. Storage failures remain typed instead of putting
    the oversized payload back on the provider wire. *)

(** {1 Result Conversion} *)

val failure_next_move : Tool_result.tool_failure_class -> string option
(** The one sentence the model reads after a failed tool result, keyed by the
    typed failure class: what changes the outcome next time (arguments, state,
    time, nothing). Read from the prompt registry
    ([config/prompts/tool_failure.<class>.md]); [None] when that asset is
    absent from every source, which is logged. *)

val to_agent_core_typed_result :
  ?base_path:string ->
  ?model_projection:Tool_output.model_projection ->
  ?on_externalization_error:(externalization_error -> unit) ->
  Tool_result.result ->
  Agent_core.Types.tool_result
(** Convert a {!Tool_result.result} to AGENT_CORE [tool_result].  [Completed] and
    [Deferred] project one-way to AGENT_CORE [Ok]; [Deferred] carries an opaque MASC
    disposition marker in [_meta].  The adapter never parses that metadata
    back into MASC semantics.  [Failed] appends [failure_class=<class> — <next move>] to the
    content the model reads (a [failure_class] / [next_move] pair inside the
    JSON envelope when explicit metadata is present) and maps its typed [failure_class] directly
    to AGENT_CORE [recoverable]/[error_class]. [on_externalization_error] lets an
    owning runtime keep its terminal state consistent when storage fails. The
    provider receives only a bounded generic error and no replay instruction.

    When typed result data contains normalized artifact references, the
    producer must first call {!attach_artifact_manifest}; the provider-facing
    content then becomes that durable manifest's marker. Projection performs
    no manifest I/O after the producer's effect boundary. This keeps the
    transcript itself as the authoritative root while preserving the original
    content and structured data inside the manifest. *)

(** {1 Schema Conversion} *)

val params_of_json_schema : Yojson.Safe.t -> Agent_core.Types.tool_param list
(** Convert a MASC [input_schema] with the AGENT_CORE schema-conversion SSOT.
    Raises [Invalid_argument] when a property type is missing, unsupported, or
    ambiguous; no local default or union-member selection is applied. *)

(** {1 AGENT_CORE Tool.t Creation} *)

val agent_core_tool_of_masc :
  ?descriptor:Agent_core.Tool.descriptor ->
  ?base_path:string ->
  ?model_projection:Tool_output.model_projection ->
  ?on_externalization_error:(externalization_error -> unit) ->
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  (Yojson.Safe.t -> Tool_result.result) ->
  Agent_core.Tool.t
(** Create an AGENT_CORE [Tool.t] from a MASC tool name, description,
    JSON input schema, and typed handler function.

    The handler receives raw JSON args and returns a {!Tool_result.result}.
    Conversion to AGENT_CORE [tool_result] is applied automatically.

    An owning adapter may pass an explicit [descriptor]. The generic bridge
    never infers mutation, permission, or concurrency semantics from a tool
    name or catalog read-only flag. Without a descriptor AGENT_CORE uses its ordinary
    sequential default. *)

val agent_core_tool_of_masc_with_execution_env :
  ?descriptor:Agent_core.Tool.descriptor ->
  ?base_path:string ->
  ?model_projection:(unit -> Tool_output.model_projection) ->
  ?on_externalization_error:(externalization_error -> unit) ->
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  (Agent_core.Tool.Execution_env.t -> Yojson.Safe.t -> Tool_result.result) ->
  Agent_core.Tool.t
(** Create an AGENT_CORE [Tool.t] whose handler also receives the exact AGENT_CORE execution
    environment. This is for correlation and observability; callers must not
    treat invocation metadata as authorization.

    [model_projection] is asked on each call rather than captured once. The
    tool bundle is built before the turn resolves a runtime, and a
    heterogeneous lane fallback can change the answer between attempts, so a
    projection fixed at build time would describe the wrong lane. This adapter
    does not know what a lane is; it only defers the question. *)
