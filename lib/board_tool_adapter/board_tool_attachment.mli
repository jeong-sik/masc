(** Typed input and stored wire format for Board post attachments.

    The post handler is the only writer of [meta.attachments]. The HTTP
    route and the MCP tool both enter through that handler. *)

type kind = Image | Video | Youtube | External_link

type source =
  | Https_url of string
  | Artifact_sha256 of string

type unresolved = { kind : kind; source : source }

type t =
  | Url of { kind : kind; url : string }
  | Artifact of { kind : kind; reference : Tool_output.artifact_ref }

type error =
  | Raw_meta_attachments
  | Attachments_not_array
  | Duplicate_attachments
  | Entry_not_object of int
  | Invalid_entry_fields of int
  | Invalid_kind of int
  | Invalid_url of int
  | Invalid_sha256 of int * Tool_output.invalid_sha256
  | Missing_artifact of int * string
  | Artifact_read_failed of int * string
  | Invalid_artifact_reference of int * Tool_output.make_error
  | Youtube_requires_url of int
  | Artifact_too_large of { index : int; bytes : int; maximum : int }

val error_to_string : error -> string
val parse_args : Yojson.Safe.t -> (unresolved list, error) result
(** Rejects a raw [meta.attachments] slot even when [attachments] is absent.
    Each new entry has exactly [kind] and one of [url] or [sha256]. A
    [youtube] entry must use [url]: a stored artifact is not a YouTube video.

    [kind] is how the reader shows the entry. For an artifact, the dashboard
    loads the bytes on request and then shows [image] as an image and [video]
    as a video (the element sniffs the format, since no media type is stored
    per hash); [external_link] stays a download. *)

val resolve :
  base_path:string ->
  max_artifact_bytes:int ->
  unresolved list ->
  (t list, error) result
(** Verifies artifact bytes in the existing Tool_blob_store before a post is
    written, reading at most [max_artifact_bytes] per artifact. Production
    passes {!Tool_blob_store.max_served_bytes}: the dashboard reads an
    attachment only through the HTTP artifact routes, so a larger artifact is
    refused with [Artifact_too_large] rather than stored as a card that never
    opens. Everything accepted is read whole and digest-checked, so a
    canonical result manifest is recognised exactly and keeps its MIME, and
    blob maintenance follows its child references. Blocking blob reads run in
    an Eio system thread. *)

val to_json : t -> Yojson.Safe.t
(** An artifact uses the canonical [_blob] wrapper so durable maintenance
    recognizes its reference. *)
