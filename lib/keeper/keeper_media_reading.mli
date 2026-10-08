(** H5 (task-2187) — attachment-bound readings of audio and documents for a
    text-only fallback candidate. Design: docs/KEEPER-MEDIA-FALLBACK-H5.md.

    When a failover lands on a runtime that cannot take an [Audio] or
    [Document] block, the per-attempt projection used to drop the block and say
    only that media was omitted. This module replaces such an inline block with
    a text block that names the attachment by the sha256 of its payload and
    carries either a reading or an explicit "unavailable" reason. The canonical
    history is never rewritten; only the dispatch view changes.

    A reading is stored per keeper under [base_path] keyed by
    (kind, source sha256, media type) and reused, after a restart too, while its
    reader version is unchanged. An unavailable result is never stored as a
    reading, so a later attempt retries it. A reader error, an absent reader, a
    reference source ([Url]/[File_id], which is not fetched) or an empty reading
    produces text that says so and contains nothing derived from the media. *)

type kind =
  | Audio
  | Document

type reader =
  kind:kind -> media_type:string -> bytes:string -> (string, string) result
(** [Error reason] is a closed, short reason; it is shown to the model. *)

val reader_version : string
(** Part of the stored record; bump when reading semantics change. *)

val production_reader : reader
(** Audio goes through {!Voice_bridge.transcribe_audio} (the configured STT
    endpoint chain) from a temporary file. Documents have no reader wired on
    the keeper turn path yet and answer [Error "no_document_reader"]. *)

val source_sha256 : string -> string
(** Lowercase hex sha256 of the decoded payload bytes. *)

val project_blocks :
  ?base_path:string ->
  keeper_name:string ->
  needs_projection:(kind -> bool) ->
  read:reader ->
  Agent_core.Types.content_block list ->
  Agent_core.Types.content_block list * (string * int) list
(** Replace every top-level [Audio]/[Document] block whose kind
    [needs_projection] returns [true] for. Returns the projected list and the
    count of blocks replaced per modality name (audio, document). Blocks of other kinds, and nested tool-result
    content, are returned unchanged. Within one call, one reader invocation
    serves repeated occurrences of the same payload. *)
