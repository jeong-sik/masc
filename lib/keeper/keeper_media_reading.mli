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
    reader version is unchanged. {!Keeper_media_reading_maintenance} removes a
    stored reading once no durable record carries its attachment. An
    unavailable result is never stored as a reading, so a later turn retries
    it; within one lane walk it is not retried (see {!projector}). A reader
    error, an absent reader, a
    reference source ([Url]/[File_id], which is not fetched) or an empty reading
    produces text that says so and contains nothing derived from the media. *)

type kind =
  | Audio
  | Document

type reader =
  kind:kind ->
  media_type:string ->
  bytes:string ->
  (string, string) result
(** [Error reason] is a short unavailable reason shown to the model. Each
    reader owns its transport or subprocess resource limits; time spent on
    earlier attachments or provider calls never prevents a later read. *)

val reader_version : string
(** Part of the stored record; bump when reading semantics change. *)

val production_reader : base_path:string -> reader
(** Audio goes through {!Voice_bridge.transcribe_audio} (the configured STT
    endpoint chain) from a temporary file. The STT transport retains its
    configured per-call limits and cancellation handling.

    A PDF goes through {!Verification_pdf_inspection.extract_text}, whose
    subprocess limit belongs to that one document extraction. Other
    document types answer [Error "no_document_reader"]. *)

val store_dirname : string
(** Directory under the MASC dir that holds one sub-directory of stored
    readings per keeper. It is outside the durable-consumer trees
    {!Tool_blob_maintenance} scans. *)

type projector
(** The projection state of one lane walk. Every candidate and every message
    projected through one projector share its results, so an attachment is
    read at most once per walk, whether the reading succeeded or not. A new
    turn makes a new projector; an attachment that was unavailable is read
    again there. *)

val projector :
  ?base_path:string ->
  media_store:Agent_core.History.media_store ->
  keeper_name:string ->
  read:reader ->
  unit ->
  projector
(** Construct the memo shared by this walk's consumers. The walk owns no
    elapsed-time allowance for reads. *)

val read_stored :
  projector ->
  kind:kind ->
  media_type:string ->
  Agent_core.History.stored ->
  (string, string) result
(** Read one stored attachment through the projector's existing reader,
    successful-reading store. The result is raw
    reader text or an unavailable reason, with no source-attribution wrapper;
    each consumer names its own original in the text it presents.

    Calls through this function and {!project} share the same result for a
    (kind, media type, source digest) during this walk, including errors. Only
    successful nonempty readings are stored for another walk. An attachment
    without a reading reaches its reader regardless of earlier work. Empty reader
    output returns [Error "empty_reading"]. Cancellation propagates and is not
    memoized as an unavailable result. *)

val project :
  projector ->
  needs_projection:(kind -> bool) ->
  Agent_core.Types.content_block list ->
  Agent_core.Types.content_block list * (string * int) list
(** Replace every [Audio]/[Document] block whose kind
    [needs_projection] returns [true] for. Returns the projected list and the
    count of blocks replaced per modality name (audio, document), including
    nested tool-result blocks. Tool-result identity, outcome, JSON and original
    text are preserved; only the attached blocks are projected. Other block
    kinds are unchanged. A stored reading is reused without calling the
    reader. *)

val project_blocks :
  ?base_path:string ->
  media_store:Agent_core.History.media_store ->
  keeper_name:string ->
  needs_projection:(kind -> bool) ->
  read:reader ->
  Agent_core.Types.content_block list ->
  Agent_core.Types.content_block list * (string * int) list
(** {!project} through a projector of its own: one call is one walk. *)
