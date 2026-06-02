(** Multimodal_keeper_bridge — typed hydration of raw artifact JSON.

    Cycle 27 / Tier W3 (B9 follow-up).

    {1 What this module is}

    A pure function [raw_artifact → Multimodal.Artifact.any] that
    takes a JSON-shaped representation of an artifact (as the
    keeper or any external producer might emit) and converts it
    into a typed multimodal artifact. The [kind_hint] field
    discriminates Code/Image/Audio/Doc; unknown hints yield
    [None].

    {1 Why this module}

    Tier B9 ({!Multimodal_hydrator}) provides a callback-based
    DAG builder. This module provides the {b other half}: an
    actual conversion from raw JSON to typed artifact. Together
    they form the keeper integration seam — the keeper's
    [keeper_artifact_hydrator] yields raw JSON via callback,
    [hydrate_one] converts each entry, and the caller stitches
    them into a [Workspace] via [hydrate_with_workspace].

    {1 RFC-0002 compliance}

    This module does NOT import [lib/keeper] — keeping the
    multimodal sub-library independent of the keeper. The
    keeper-side adapter (which calls [keeper_artifact_hydrator]
    and feeds [raw_artifact] values into [hydrate_batch]) lives
    in [lib/keeper] in a follow-up PR.

    {1 Scope of this PR}

    - {!raw_artifact}: input record carrying an opaque id, a
      [kind_hint] string, payload JSON, and metadata JSON.
    - {!hydrate_one}: single conversion with provenance hookup.
    - {!hydrate_batch}: bulk conversion, skipping unknown hints.
    - {!hydrate_with_workspace}: bulk + Workspace insertion. *)

type raw_artifact = {
  id : string;
      (** External id (UUID v7 string). If malformed, a fresh id
          is generated and the original recorded in metadata. *)
  kind_hint : string;
      (** ["code"], ["image"], ["audio"], ["doc"], or any other
          string. Unknown hints make the entry skip-eligible. *)
  payload_json : Yojson.Safe.t;
      (** Wrapped as a [Payload.Lazy_payload] in the produced
          artifact (lazy so callers do not pay serialization
          cost upfront). *)
  metadata : Yojson.Safe.t;
}

val parse_kind_hint : string -> Artifact.kind_tag option
(** Map [kind_hint] strings to {!Artifact.kind_tag}. Lowercase,
    exact match. *)

val hydrate_one :
  raw_artifact ->
  now:float ->
  created_by:string ->
  origin_artifact_ids:Shared_types.Artifact_id.t list ->
  Artifact.any option
(** Convert one raw_artifact. Returns [None] when [kind_hint]
    is unknown. The artifact's payload is wrapped lazily so
    consumers that never read the payload pay no overhead. *)

val hydrate_batch :
  raw_artifact list ->
  now:float ->
  created_by:string ->
  Artifact.any list
(** Bulk hydrate. Each entry's [origin_artifact_ids] is empty —
    callers that need provenance edges should use
    {!hydrate_with_workspace} or call {!hydrate_one} directly. *)

val hydrate_with_workspace :
  Workspace.t ->
  raw_artifact list ->
  now:float ->
  created_by:string ->
  Workspace.t * Artifact.any list
(** Hydrate a batch and insert each artifact into [ws]. The
    workspace is returned together with the list of artifacts
    actually inserted (skipping unknown hints). *)
