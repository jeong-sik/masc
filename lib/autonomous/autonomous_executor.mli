(** Autonomous_executor — Tool_call → Multimodal artifact translator.

    Cycle 27 / Tier W1. Wire-in path that converts the keeper's
    turn-output Tool_calls into typed
    {!Multimodal.Artifact.any} values for accumulation in a
    {!Multimodal.Workspace}.

    {1 Why this module}

    The autonomous loop's [Executing] phase emits Tool_calls
    (pairs of tool name + JSON args). Without this translator,
    multimodal artifacts produced by tools like [code_write] or
    [image_generate] live in the keeper's raw turn log only —
    invisible to the workspace registry, the dashboard, and any
    downstream resilience/audit consumers.

    {1 Scope of this PR}

    - Heuristic classifier: tool-name prefix → {!Artifact.kind_tag}
      (e.g. [code_write] → [Tag_code]).
    - {!translate}: single tool_call → optional
      {!Multimodal.Artifact.any}.
    - {!accumulate}: bulk tool_calls into a workspace, returning
      the new workspace plus the artifacts inserted.

    {1 Deferred}

    - Real provenance edges from upstream tool_calls — {!translate}
      currently produces empty [origin_artifact_ids]. Tier W3
      (multimodal_keeper_bridge) adds provenance hydration.
    - Lazy / Streaming payload selection — currently always
      [Lazy_payload]. Future PR may select based on byte size
      or content-type. *)

type tool_call = {
  name : string;
  args : Yojson.Safe.t;
}

val classify_tool : string -> Multimodal.Artifact.kind_tag option
(** Heuristic prefix-based classification.
    [code_*]   → [Some Tag_code]
    [image_*]  → [Some Tag_image]
    [audio_*]  → [Some Tag_audio]
    [doc_*]    → [Some Tag_doc]
    Other → [None]. *)

val translate :
  tool_call ->
  now:float ->
  created_by:string ->
  Multimodal.Artifact.any option
(** Translate one tool_call into an artifact, if its name maps
    to a known multimodal kind. The artifact's payload field
    captures the [args] JSON as a [Lazy_payload]; metadata
    records the tool name. *)

val accumulate :
  Multimodal.Workspace.t ->
  tool_call list ->
  now:float ->
  created_by:string ->
  Multimodal.Workspace.t * Multimodal.Artifact.any list
(** Bulk: process tool_calls in order, inserting each translated
    artifact into the workspace. Returns the new workspace plus
    the list of artifacts that were translated and inserted
    (skipping non-multimodal tool_calls). *)
