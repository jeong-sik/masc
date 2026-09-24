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

val error_to_string : error -> string
val parse_args : Yojson.Safe.t -> (unresolved list, error) result
(** Rejects a raw [meta.attachments] slot even when [attachments] is absent.
    Each new entry has exactly [kind] and one of [url] or [sha256]. *)

val resolve : base_path:string -> unresolved list -> (t list, error) result
(** Verifies artifact bytes in the existing Tool_blob_store before a post is
    written. Blocking blob reads run in an Eio system thread. *)

val to_json : t -> Yojson.Safe.t
(** An artifact uses the canonical [_blob] wrapper so durable maintenance
    recognizes its reference. *)
