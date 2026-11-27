type request_header = Workspace_verification_snapshot.request_header = {
  id : string;
  task_id : string;
  worker : string;
  created_at : float;
}

type evidence_read_failure = Workspace_verification_snapshot.evidence_read_failure =
  | Evidence_missing
  | Evidence_not_regular_file
  | Evidence_outside_worker_playground
  | Evidence_invalid_utf8
  | Evidence_symbolic_link
  | Evidence_changed_during_read
  | Evidence_read_error of string
  | Too_large of
      { cap : int
      ; at_least : int
      (** The source is over the ceiling a text artifact is read under. It was
          not read past [cap] + 1 bytes: [at_least] is the size the reader
          could name, the exact file size where the host could stat it and
          [cap] + 1 where a sandbox reader only returned the bytes it was
          asked for. *)
      }

type collaboration_kind = Board_source | Fusion_source | Task_source

type submitted_evidence_item = Workspace_verification_snapshot.submitted_evidence_item =
  | Evidence_collaboration of { reference : string; content : string; sha256 : string }
  | Evidence_note of string
  | Evidence_artifact of
      { reference : string
      ; content : string
      ; bytes : int
      (** Whole text up to the inline cap. There is no prefix-only state: a
          larger text is [Evidence_artifact_body]. *)
      }
  | Evidence_artifact_body of
      { reference : string
      ; blob : Tool_output.artifact_ref
      (** Text too large for the inline cap, stored whole in the
          content-addressed blob store at submission. The reference is what
          the sweep counts. *)
      }
  | Evidence_invalid_reference
  | Evidence_artifact_unreadable of
      { reference : string
      ; reason : evidence_read_failure
      }
  | Evidence_artifact_binary of
      { reference : string
      ; bytes : int
      ; sha256 : string
      ; format : string
      ; body : string option
      }

type evidence_access_failure = Workspace_verification_snapshot.evidence_access_failure =
  | Completion_authority_identity_missing
  | Request_not_found
  | Request_header_invalid of string
  | Evidence_snapshot_invalid of string
  | Request_load_error of string
  | Request_scope_mismatch

type submitted_evidence_access = Workspace_verification_snapshot.submitted_evidence_access =
  | Evidence_available of
      { request : request_header
      ; items : submitted_evidence_item list
      }
  | Evidence_unavailable of
      { request_id : string
      ; reason : evidence_access_failure
      }

val request_header_of_yojson :
  Yojson.Safe.t -> (request_header, string) result

val request_header_to_yojson : request_header -> Yojson.Safe.t

val submitted_evidence_access_to_yojson :
  submitted_evidence_access -> Yojson.Safe.t

val submitted_evidence_access_transport_to_yojson :
  submitted_evidence_access -> Yojson.Safe.t
(** Judge-transport projection of the snapshot. An inline artifact travels
    with its content, or with [content_omitted] and a [content_note] when the
    aggregate cap withholds it. A stored body travels as its size and content
    address with [content_omitted]. No text is ever sent as a prefix
    (#29615). {!submitted_evidence_access_to_yojson} is the persistence
    serializer. *)

val submitted_evidence_access_metadata_to_yojson :
  submitted_evidence_access -> Yojson.Safe.t

val evidence_read_failure_code : evidence_read_failure -> string
(** Stable bounded code for diagnostics and metadata. *)
val evidence_access_failure_to_string :
  request_id:string -> evidence_access_failure -> string
val evidence_read_failure_of_owned_read_failure :
  Fs_compat.owned_regular_file_read_failure -> evidence_read_failure

val verification_evidence_max_bytes : int
(** The inline cap for one text artifact. Content up to this size is written
    into the request record; a larger text is stored whole in the blob store
    and the record keeps its content address. Nothing is cut. Exposed so a
    test states the boundary against this value instead of copying the
    number. *)

val text_artifact_max_bytes : int
(** The ceiling on one text artifact. A text file over it is not read: the
    reader stops one byte past the ceiling and the item is unreadable with
    {!Too_large}. Known binary formats are not under this ceiling; the store
    adopts them whole. *)

val is_binary_artifact_path : string -> bool
(** Whether a reference names a format the store adopts as binary. *)

val project_root_of_base_path : string -> string
(** The project root a BasePath names, whether the caller passed the project
    root itself or its [.masc] directory. Exposed so a producer's ownership
    root is derived by this function everywhere rather than re-derived beside
    it. *)

(** The reference shapes this store can read, decided without touching the
    filesystem. *)
type reference_form =
  | Artifact_reference of string
  | Note_reference of string
  | Collaboration_reference of collaboration_kind * string
  | Unresolvable_reference

val classify_evidence_reference : string -> reference_form
(** Shared submission grammar. Collaboration sources are captured by the
    application submit boundary before calling the artifact/note snapshotter. *)

val note_reference_form : string
(** The accepted form for narrative evidence, spelled from the prefix this
    module matches on, so an error message naming it cannot drift from the
    classifier. The artifact form has no such caller: a message that has to
    name both uses {!resolvable_reference_forms}. *)

val resolvable_reference_forms : string list
(** The accepted forms, spelled for an error message that has to tell a caller
    what to write instead. *)

val valid_producer_relative_path : string -> bool
(** Whether the path of an [Artifact_reference] can be read at all: relative,
    non-empty, and without empty, [.] or [..] segments. The snapshotter turns
    a path that fails this into [Evidence_invalid_reference]; a caller that
    refuses an artifact reference before snapshotting asks the same question
    here instead of copying it. *)

type artifact_payload =
  | Text_payload of { content : string; bytes : int }
  | Binary_payload of
      { data : string; bytes : int; sha256 : string; format : string }

type artifact_read_result = (artifact_payload, evidence_read_failure) result
(** One artifact's read: text as its whole [(content, bytes)], or binary as
    raw bytes with their hash and format. A reader that cannot answer returns
    the typed failure instead. An injected reader bounds its own read by
    {!text_artifact_max_bytes} and answers [Too_large] past it. *)

type utf8_scan =
  | Utf8_valid
  | Utf8_incomplete_at of int
  | Utf8_invalid

val scan_utf8 : string -> utf8_scan
(** The text line every artifact read answers under. Exposed so an injected
    reader classifies its bytes with the same scan the store applies, rather
    than a second opinion ({#33816}). *)

val payload_of_complete_bytes : path:string -> string -> artifact_read_result
(** Classify a fully read artifact. Known binary formats are adopted whole
    regardless of size (the delivery ceiling, not the reader, bounds what the
    judge sees). Anything else must be valid UTF-8: text that is not is the
    typed [Evidence_invalid_utf8] failure, never a binary payload. *)

val image_media_type_of_binary_format : string -> string option
(** Whether a binary artifact's [format] is an image a runtime accepts as
    attached input, and as which media type. The format
    taxonomy stays with the store that produced it. *)

val persist_binary_body :
  base_path:string ->
  ?request_id:string ->
  ?index:int ->
  string ->
  string option
(** File a binary artifact's bytes as the evidence body and answer the
    masc-dir-relative path recorded on the item. [None] when
    no request id was given — the hash still stands, the body is simply not
    filed. Exposed so a test builds a filed item through the same filing the
    capture path uses. *)

type binary_body_identity_mismatch =
  { expected_bytes : int
  ; actual_bytes : int
  ; expected_sha256 : string
  ; actual_sha256 : string
  }

type read_binary_error =
  | Not_binary  (** the item is not a binary artifact *)
  | Body_not_filed
      (** the item was decoded from persistence, not captured, so no body
          was ever filed under a request *)
  | Body_unreadable of string  (** the filed body file cannot be read *)
  | Body_identity_mismatch of binary_body_identity_mismatch
      (** The complete filed bytes differ from the submitted size or SHA-256.
          Neither the judge nor the operator receives these bytes. *)
  | Over_delivery_ceiling of { bytes : int; ceiling : int }
      (** the filed body is [bytes] long and the judge delivery ceiling
          {!verification_evidence_max_bytes} is [ceiling] *)
(** Why {!read_binary_body_base64} did not deliver a body. Closed so a
    caller decides per case rather than reading a sentence. *)

val read_binary_body_base64 :
  base_path:string ->
  submitted_evidence_item ->
  (string, read_binary_error) result
(** The filed body of a binary artifact read back as base64 for an attached
    media block. One bounded owned-file read validates the no-follow path,
    regular descriptor and stable identity; complete bytes are checked against
    the submitted size and SHA-256 before encoding. [Error] names why it was not delivered — see
    {!read_binary_error}; in every case the judge then rests on the
    reference-and-hash line in the prompt. *)

val read_binary_body_for_operator_base64 :
  base_path:string -> submitted_evidence_item -> (string, read_binary_error) result
(** Read a retained download using its recorded file size as the read bound.
    The owned-file and size/digest checks are identical to the attachment
    reader, but the model's inline delivery ceiling does not cap an explicit
    operator download. A body larger than its recorded size is refused. *)

val snapshot_submitted_evidence_json :
  ?artifact_read:(worker:string -> relative:string -> artifact_read_result) ->
  ?request_id:string ->
  ?collaboration:submitted_evidence_item list ->
  base_path:string ->
  worker:string ->
  string list ->
  Yojson.Safe.t
(** Materialize submitted evidence once at the producer's submit boundary.
    The items for the references come first, then the [collaboration] items,
    already resolved by the caller.
    ["artifact:<relative-path>"] is rooted at the producer's declared sandbox;
    ["note:<text>"] preserves non-file evidence explicitly. A text artifact
    is captured whole: inline up to {!verification_evidence_max_bytes}, above
    that as a body in the blob store. A text file over
    {!text_artifact_max_bytes} is an unreadable item carrying [Too_large].
    Bare and absolute references are persisted as a payload-free typed
    invalid-reference item. *)


val submitted_evidence_identity_lines :
  Yojson.Safe.t -> (string list, string) result
(** Project a persisted [submitted_evidence] snapshot into one identity line
    per item, for surfaces that name evidence without reading its payload —
    artifacts project to their reference, notes to their prefixed text, and
    unreadable items carry the typed reason code and any saved read-error
    detail, including the attempted path. Payloads are served separately by the
    authority-scoped evidence route.

    This module writes the snapshot, so it owns the shape: a caller must not
    re-derive it. Returns [Error] on any item this module did not write and
    never partially projects a malformed array. *)

val submission_receipt :
  base_path:string -> request_id:string -> task_id:string -> worker:string ->
  (Yojson.Safe.t, evidence_access_failure) result
(** Capture diagnostics from one exact persisted submission. Verifies the
    request id, Task and producer; returns unreadable references only, never
    artifact contents. Internal submission adapters call
    this before notifying the verifier, then publish it only after commit.
    This does not reread the producer's files or decide submission acceptance.
    An unreadable item is listed with its reason, [Too_large] among them. *)

val inspect_submitted_evidence_for_authority :
  base_path:string ->
  request_id:string ->
  task_id:string ->
  task_worker:string ->
  authority:Masc_domain.completion_authority ->
  submitted_evidence_access
(** Read submitted evidence after a trusted boundary has produced a completion
    authority. The task id and producer must still match the durable request. *)
val inspect_submitted_evidence_for_operator :
  base_path:string -> request_id:string -> task_id:string -> operator_id:string ->
  submitted_evidence_access
(** A trusted CanAdmin boundary supplies the operator. Read the exact immutable
    request, including after Task settlement/archival; its id and Task must
    match. The recorded producer is not replaced by a current Task owner. *)
val verifications_dirname : string
(** Name of the directory under the masc directory that holds request
    records. The sweep scope scans it for the content addresses records hold. *)
val evidence_body_directory : string
(** Name of the directory under the masc directory that holds binary evidence
    bodies. They are files, not blob references. *)
val verifications_dir : string -> string
val request_path : string -> string -> string

val collaboration_reference : string -> (collaboration_kind * string) option
val submitted_evidence_item_fields :
  submitted_evidence_item -> (string * Yojson.Safe.t) list
(** The members of an item's JSON object, so a caller that adds a member does
    not take the object apart again. *)

val submitted_evidence_item_to_yojson : submitted_evidence_item -> Yojson.Safe.t
val submitted_evidence_item_of_yojson : Yojson.Safe.t -> (submitted_evidence_item, string) result

val submitted_evidence_item_metadata_to_yojson : submitted_evidence_item -> Yojson.Safe.t
