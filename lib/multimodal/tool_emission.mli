(** Tool-result → multimodal emission.

    Cycle 27 / Tier K3 — the next layer above {!Keeper_emitter}.

    {1 What this module is}

    A pure converter from a single tool-call result to (optionally)
    one [working_context] update with a new
    {!Multimodal_keeper_bridge.raw_artifact} entry, gated by an
    {b explicit} tag on the tool result.

    The contract: a tool wishing to register a multimodal artifact
    sets two reserved fields on its JSON output —

    {[
      {
        "__multimodal_kind": "code" | "image" | "audio" | "doc",
        "__multimodal_id": "<uuid v7 string>",
        "...rest of the tool's regular output..."
      }
    ]}

    No tag → the tool result is opaque to the multimodal pipeline.

    {1 Why explicit tagging instead of heuristics}

    Tool name regex (e.g. ["matches /image/i"]) silently drifts
    when tool surfaces are renamed and silently mis-classifies new
    tools that happen to match. The explicit-tag protocol is
    deterministic: a tool either opts in or it does not.

    Reference: [feedback_no-string-matching-classification.md].

    {1 Scope of this PR}

    - {!extract_kind_from_result}: lookup
      [__multimodal_kind] and parse via
      {!Multimodal_keeper_bridge.parse_kind_hint}. Returns [None]
      on missing key, malformed payload, or unknown kind.
    - {!emit_from_tool_result}: detector + emitter chain. When the
      result carries no tag, returns the [working_context]
      unchanged.
    - {!emit_from_tool_results}: bulk variant.

    The tag-emission contract on the tool side is left to
    follow-up PRs (tool surface adapters). *)

val multimodal_kind_key : string
(** ["__multimodal_kind"] — the reserved JSON key carrying the
    artifact kind hint. Exposed so tool authors can use the same
    constant. *)

val multimodal_id_key : string
(** ["__multimodal_id"] — the reserved JSON key carrying the
    artifact id. *)

val multimodal_metadata_key : string
(** ["__multimodal_metadata"] — optional reserved key. When
    present its [`Assoc] value is forwarded as the artifact's
    metadata; otherwise an empty assoc is used. *)

val extract_kind_from_result :
  Yojson.Safe.t -> Artifact.kind_tag option
(** [extract_kind_from_result result] reads
    [result[multimodal_kind_key]] and parses it via
    {!Multimodal_keeper_bridge.parse_kind_hint}. Returns [None]
    when the key is absent, the value is not a string, or the
    string is not one of [code]/[image]/[audio]/[doc]. *)

val extract_id_from_result : Yojson.Safe.t -> string option
(** [extract_id_from_result result] reads
    [result[multimodal_id_key]]. Returns [None] when the key is
    absent or the value is not a string. *)

val emit_from_tool_result :
  working_context:Yojson.Safe.t option ->
  result:Yojson.Safe.t ->
  Yojson.Safe.t option
(** [emit_from_tool_result ~working_context ~result] is the chain:

    + extract [__multimodal_kind] (else return [working_context]);
    + extract [__multimodal_id] (else return [working_context]);
    + read optional [__multimodal_metadata];
    + call {!Keeper_emitter.emit} with the tool result {b minus}
      the reserved keys as the payload.

    The reserved-key strip ensures the artifact's
    [payload_json] does not duplicate the kind/id/metadata
    already stored in dedicated [raw_artifact] fields. *)

val emit_from_tool_results :
  working_context:Yojson.Safe.t option ->
  Yojson.Safe.t list ->
  Yojson.Safe.t option
(** Bulk variant — folds {!emit_from_tool_result} over the list. *)
