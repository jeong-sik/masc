(** Attachment-bound readings for a candidate that cannot receive the original
    audio or document. Canonical history is never rewritten. A walk shares one
    projector across history and retained host-result consumers. *)

type kind = Media_reading_kind.t = Audio | Document

type reader_identity = private { id : string; revision : string }
type identity_error = Empty_id | Empty_revision

val reader_identity :
  id:string -> revision:string -> (reader_identity, identity_error) result
(** A declared reader and the revision of its interpretation. Neither may be
    blank. This identifies the host's declaration, not authenticated remote
    code, account identity or executable bytes. *)

type reader_failure =
  | Temporary_file_failed
  | Temporary_write_failed
  | Stt_failed of Voice_bridge.transcription_error
  | Empty_transcript
  | Pdf_failed of Verification_pdf_inspection.error
  | Empty_extraction
  | Empty_reading

type reader
val reader :
  identity:reader_identity ->
  read:(bytes:string -> (string, reader_failure) result) -> reader
(** Bind identity and execution before reading a cache. The callback owns one
    reader's transport or subprocess limits. It must use the same declaration
    snapshot its identity names. Cancellation propagates. *)

type resolution_failure =
  | No_matching_reader
  | Stt_unavailable of Voice_bridge.transcription_error

type resolver =
  kind:kind -> media_type:string -> (reader, resolution_failure) result

val production_readers : base_path:string -> resolver
(** Resolves the current built-in STT or PDF reader. STT captures its endpoint
    and model declaration before cache lookup and executes that same snapshot.
    Its identity does not pin credential values, remote implementations or
    local executable/model file contents. Other document formats have no
    matching reader. This is not the external-service reader registry. *)

type reading = private { reader : reader_identity; text : string }
type failure =
  | Resolution_failed of resolution_failure
  | Invalid_source_reference of Agent_core.History.stored_error
  | Source_unavailable of Agent_core.History.media_error
  | Reader_failed of { reader : reader_identity; reason : reader_failure }

val failure_to_string : failure -> string
(** Model-facing reason, rendered only at the final projection boundary.
    Detailed transport/configuration failures remain typed and are not used
    as string control signals. *)

val store_dirname : string
(** Success-cache directory below the workspace's MASC root. A reading belongs
    to its original attachment and reader identity; it owns no execution or
    approval state. {!Keeper_media_reading_maintenance} removes a cached
    reading only after no durable consumer retains its original attachment. *)

type projector
val projector :
  ?base_path:string ->
  media_store:Agent_core.History.media_store ->
  keeper_name:string ->
  resolve:resolver ->
  unit -> projector
(** A walk-owned mutable memo, used on its owning fiber. Reader selection is
    frozen for each (kind, media type) on its first use in the walk. Successful
    readings and failures are shared across consumers in that walk; another
    walk resolves again. No aggregate elapsed-time allowance is imposed. *)

val read_stored :
  projector -> kind:kind -> media_type:string -> Agent_core.History.stored ->
  (reading, failure) result
(** Resolve the reader before cache lookup. A durable cache hit must match kind,
    media type, source digest/length and the selected reader's id/revision.
    Only nonempty successes are stored. A different reader or declaration
    cannot reuse the old reader's result. A failure is retried in a new walk;
    cancellation is neither caught nor memoized. *)

val project :
  projector ->
  needs_projection:(kind -> bool) ->
  Agent_core.Types.content_block list ->
  Agent_core.Types.content_block list * (string * int) list
(** Replace selected Audio/Document blocks, including nested ToolResult media,
    with an attributed reading or explicit unavailable data. URL/file-id
    sources are not fetched. Tool identity, outcome, JSON and original text
    remain unchanged. Returns replaced counts by modality. *)

val project_blocks :
  ?base_path:string ->
  media_store:Agent_core.History.media_store ->
  keeper_name:string ->
  needs_projection:(kind -> bool) ->
  resolve:resolver ->
  Agent_core.Types.content_block list ->
  Agent_core.Types.content_block list * (string * int) list
(** One call through a projector of its own. *)
