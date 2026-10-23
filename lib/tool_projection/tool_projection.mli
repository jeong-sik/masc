(** Model-facing projection of typed tool results to AGENT_CORE.

    Result-projection half of the former [Tool_bridge]: typed
    [Tool_result.result] values become [Agent_core.Types.tool_result] under a
    descriptor's [Tool_output.model_projection], with artifact-manifest
    persistence and the externalization budget. [Tool_bridge] re-exports this
    surface unchanged; mid-level libraries that cannot depend on the root
    masc library depend on this one directly. *)

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
  ?projection:Tool_output.artifact_projection ->
  base_path:string ->
  Tool_result.result ->
  (Tool_result.result, externalization_error) result
(** Persist and attach the canonical manifest for typed result data containing
    normalized artifact references. Producers call this inside their effect
    boundary, before returning the authoritative result. Results without
    artifact references pass through unchanged. Cancellation propagates.
    The default [Reference_only] presents the manifest marker. An explicit
    [Inline_with_reference] retains the result's content and structured data,
    together with the exact durable manifest reference, while the complete
    envelope fits the descriptor's typed projection ceiling. Larger envelopes
    use the existing manifest marker without further storage or re-execution.
    [Inline_with_structured_diagnostic] is an explicit producer declaration
    that the complete domain diagnostic is in structured data: failed inline
    envelopes carry canonical class/next move without repeating that data as
    message text. Opaque failure messages use [Inline_with_reference]. *)

val artifact_manifest_reference :
  Tool_result.result ->
  (Tool_output.artifact_ref * Tool_output.artifact_projection, string) result
(** Read the producer's typed manifest and presentation from result metadata.
    This performs no storage, projection or artifact fetch. *)

val artifact_result_envelope :
  reference:Tool_output.artifact_ref -> structured_content:Yojson.Safe.t ->
  ?content:string -> unit -> string
(** Canonical inline wire envelope shared by the result projection and its
    delivery observer. Does not project or fetch a referenced body. *)

val maybe_externalize :
  ?base_path:string ->
  ?stored_preview:string ->
  ?answer_fingerprint:string ->
  ?mime:string ->
  ?threshold_bytes:int ->
  string ->
  (string, externalization_error) result
(** [stored_preview] supplies immediate context on stored references without
    changing their exact payload bytes.
    Externalize when over threshold and a blob store is available;
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
  ?answer_reader:(string -> Yojson.Safe.t option) ->
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
    provider normally receives a generic projection error. A typed
    [Proven_post_effect] failure whose artifact manifest is unavailable instead
    remains an error carrying the applied-effect warning and normalized artifact
    retrieval handles within the caller’s typed projection ceiling. When the full
    envelope fits, [data] preserves the complete producer recovery descriptor.
    Otherwise [data_omitted] explicitly withholds raw producer data and
    [artifact_refs_omitted] counts handles that cannot fit, while retaining the
    applied/no-repeat warning and current-target recovery instruction. Oversized
    reference previews may be omitted without changing their blob identity. It
    never becomes success or retries manifest projection. A custom ceiling too
    small for the fixed envelope receives a bounded plain notice; the typed
    error remains non-recoverable. The producer owns the recovery payload;
    the bridge does not reconstruct domain fields.

    When typed result data contains normalized artifact references, the
    producer must first call {!attach_artifact_manifest}; the provider-facing
    content then becomes that durable manifest's marker by default. The
    producer's explicit [Inline_with_reference] presentation keeps a bounded
    result envelope and manifest reference inline. Projection performs
    no manifest I/O after the producer's effect boundary. This keeps the
    transcript itself as the authoritative root while preserving the original
    content and structured data inside the manifest. *)
