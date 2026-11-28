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

type original_reference = private
  { request_id : string; original_digest : string; execution_id : string }
val original_reference : Keeper_media_reading_original.t -> original_reference

type reading = private
  { reader : reader_identity; text : string; original : original_reference option }
val reading_of_original :
  original:Keeper_media_reading_original.t -> text:string ->
  (reading, reader_failure) result
(** Attribute nonempty interpreted text to its captured declaration and original.
    The producer must first validate the retained reply and its adapter result.
    This constructor records provenance, not execution or approval authority. *)
type dispatch_failure =
  | Dispatch_owner_failed of Keeper_media_reading_owner.error
  | Dispatch_progress_failed of Lane_addon_tool_request_owner.update_error
  | Dispatch_unconfirmed of string
type external_failure =
  | Declarations_unavailable
  | Declaration_ambiguous of string list
  | Declaration_changed of string
  | Reader_not_started
  | Original_failed of Keeper_media_reading_original.error
  | Owner_failed of Keeper_media_reading_owner.error
  | Queue_failed of Keeper_approval_queue_result.storage_error
  | Gate_failed of Keeper_gate.unavailable_reason
  | Approval_mismatch of Keeper_approval_queue_result.exact_request_lookup
  | Invalid_approval of string
  | Approval_rejected of string
  | Progress_failed of Lane_addon_tool_request_owner.update_error
  | Progress_unconfirmed of string
  | Endpoint_unavailable of string
  | Request_refused of Keeper_sandbox_remote.Stdio_request.refusal
  | Binding_refused of Keeper_sandbox_remote.Stdio_request.binding_error
  | Binding_changed
  | Transport_failed of dispatch_failure Keeper_sandbox_remote_stdio.failure
  | Mcp_failed of Agent_core.Error.t
  | Channel_unavailable of string
  | Catalog_failed of Keeper_media_markitdown.catalog_error
  | Conversion_failed of Keeper_media_markitdown.reply_error
  | Reply_capture_failed of string
val external_failure_to_string : external_failure -> string
(** A stable model-facing reason. Actual typed causes remain available to the
    owning producer; arbitrary remote and configuration payloads are not shown. *)
type failure =
  | Resolution_failed of resolution_failure
  | Invalid_source_reference of Agent_core.History.stored_error
  | Source_unavailable of Agent_core.History.media_error
  | Reader_failed of { reader : reader_identity; reason : reader_failure }
  | External_failed of external_failure

val failure_to_string : failure -> string
(** Model-facing reason, rendered only at the final projection boundary.
    Detailed transport/configuration failures remain typed and are not used
    as string control signals. *)

type pending_disposition =
  | Awaiting_approval of string
  | Awaiting_host_replay of string
  | Approval_consumed of string
  | Rejected_approval of { approval_id : string; reason : string }
  | Execution_pending
  | Request_not_sent
  | Outcome_unknown
  | Reconciliation_required
  | Ambiguous_approvals of string list
  | Known_approval_missing of
      { approval_id : string; matching_approval_ids : string list }
  | Known_approval_mismatch of
      { approval_id : string; matching_approval_ids : string list }
type pending_observation =
  { original : original_reference; disposition : pending_disposition }
type outcome =
  | Read of reading
  | Unavailable of failure
  | Pending of pending_observation * pending_observation list
(** Pending preserves every original and its own disposition. An empty pending
    state cannot be constructed; mixed unknown and approval waits stay visible. *)
type source_route = Use_builtin | Owned of outcome
type source_reader =
  kind:kind -> media_type:string -> Agent_core.History.stored -> source_route
type source_readers = { observe : source_reader; read : source_reader }
(** [observe] only reads retained owner evidence. [read] may admit a new request
    through Gate. Both inspect existing originals before selection or caches. *)
val outcome_to_json : outcome -> Yojson.Safe.t
(** Model-facing projection. Original identities and all pending approvals are
    retained; private source bytes and reply/transport artifacts are not exposed. *)

val store_dirname : string
(** Success-cache directory below the workspace's MASC root. A reading belongs
    to its original attachment and reader identity; it owns no execution or
    approval state. {!Keeper_media_reading_maintenance} removes a cached
    reading only after no durable consumer retains its original attachment. *)

type projector
val projector :
  ?base_path:string ->
  ?source_reader:source_reader ->
  media_store:Agent_core.History.media_store ->
  keeper_name:string ->
  resolve:resolver ->
  unit -> projector
(** A walk-owned mutable memo, used on its owning fiber. Reader selection is
    frozen for each (kind, media type) on its first use in the walk. Successful
    readings and failures are shared across consumers in that walk; another
    walk resolves again. No aggregate elapsed-time allowance is imposed. *)

val read_stored :
  ?source_reader:source_reader ->
  projector -> kind:kind -> media_type:string -> Agent_core.History.stored -> outcome
(** Observe the owned source before built-in selection or memo lookup. An
    explicit source reader overrides this projector's observation port for this
    call only; retained-host preparation supplies its admitted producer here.
    Only [Use_builtin] reaches the built-in reader and cache. A durable hit must match kind,
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
    with an attributed reading or explicit unavailable data. The non-PDF
    document formats ({!Runtime_agent.document_read_as_text}) are always
    selected. URL/file-id sources are not
    fetched. Tool identity, outcome, JSON and original text remain unchanged.
    Returns replaced counts by modality. *)

type prepared
type preparation_error =
  | Source_not_prepared of
      { kind : kind; media_type : string; source : Agent_core.History.stored }

val preparation_error_to_string : preparation_error -> string
(** Internal projection failure; this does not describe a reader invocation. *)

val prepare :
  ?source_reader:source_reader ->
  projector ->
  needs_projection:(kind -> bool) ->
  Agent_core.Types.content_block list list -> prepared
(** Prepare only the selected request bundle on its owning fiber. Each selected
    Stored Audio/Document identity (kind, media type, digest and byte length),
    including nested ToolResult media, reaches {!read_stored} once. The complete
    outcomes and modality decisions are immutable afterwards: pending approvals,
    unavailable readings and successes all remain the same during request
    reconstruction. Cancellation propagates. This value belongs to one request,
    not a later request or a new approval observation. URL/file-id sources are
    not fetched. *)

val project_prepared :
  prepared ->
  Agent_core.Types.content_block list ->
  ((Agent_core.Types.content_block list * (string * int) list), preparation_error) result
(** Pure projection using the prepared request's modality decisions and outcomes.
    Argument and result text may differ during prefix reconstruction; original
    media identities must still belong to the prepared bundle. An unprepared
    selected Stored source returns [Source_not_prepared], without reader
    selection, owner observation, storage access or a new effect. *)

val project_blocks :
  ?base_path:string ->
  media_store:Agent_core.History.media_store ->
  keeper_name:string ->
  needs_projection:(kind -> bool) ->
  resolve:resolver ->
  Agent_core.Types.content_block list ->
  Agent_core.Types.content_block list * (string * int) list
(** One call through a projector of its own. *)
