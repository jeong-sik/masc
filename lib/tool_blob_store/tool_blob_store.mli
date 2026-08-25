(** Content-addressed blob store for tool outputs.

    Backend: filesystem under [base_path/.masc/tool_blobs/<sha[0..1]>/<sha>].
    Two-character sharding bounds each directory to ~256 of the total set.
    Writes are atomic via [Fs_compat.save_file_atomic] (tempfile + rename).

    Concurrent writes of the same content are safe: same sha256 -> same path,
    last writer wins with byte-identical content. *)

type t

type invalid_sha256 = Tool_output.invalid_sha256 =
  | Invalid_sha256_length of { actual : int }
  | Invalid_sha256_character of { index : int; found : char }

val validate_sha256 : string -> (unit, invalid_sha256) result
val invalid_sha256_to_string : invalid_sha256 -> string

type fetch_error =
  | Invalid_sha256 of invalid_sha256
  | Owned_read_failed of Fs_compat.owned_regular_file_read_error
  | Integrity_mismatch of {
      path : string;
      expected : string;
      actual : string;
    }

val fetch_error_to_string : fetch_error -> string

val create : base_path:string -> t
(** Create a blob store rooted at [base_path/.masc/tool_blobs/].
    Directory creation is lazy (happens on first [put]). *)

val root_dir : t -> string
(** Absolute path of the store root. Mainly for diagnostics/testing. *)

val preview_max : int
(** Hard ceiling on the preview length {!put} produces, in characters.

    Exported because a caller that must bound the size of a marker it has not
    stored yet has to build a saturating candidate, and the only alternative
    is to hardcode this number at that call site. A hardcoded copy would turn
    a later increase here into a silent underestimate at the caller — the
    marker would grow past the bound the caller measured against. Nothing
    outside this module may restate the value; {!Tool_output.make_artifact_ref}
    does not enforce it, so it is a property of {!put}, not of
    {!Tool_output.artifact_ref}. *)

val put : t -> bytes:string -> mime:string -> Tool_output.t
(** Store [bytes] under its sha256 digest.

    Returns [Tool_output.Stored {sha256; bytes; preview; mime}] where
    [preview] is the leading sanitized run of [bytes], at most
    {!preview_max} characters (control bytes replaced with [?], whitespace
    collapsed to spaces).

    Idempotent: re-putting the same bytes atomically rewrites the same content
    address, repairing any corrupt prior bytes without a duplicate read/hash.

    @raises Sys_error if the blob write fails (disk full, EACCES, ...). Callers
    must handle this at their typed boundary and must not emit a marker for
    bytes that were never persisted. A provider projection must not put an
    oversized payload back inline because that defeats externalization. *)

val put_durable : t -> bytes:string -> mime:string -> Tool_output.artifact_ref
(** Strict variant of {!put}. The payload and its parent directory must both
    fsync successfully before the typed content address is returned. Unlike
    {!put}, the return type cannot represent an inline payload. This is the
    producer boundary for a durable record that will outlive the current
    process and point back to the blob.

    Cancellation propagates. Other write or sync failures raise [Sys_error]
    without returning a reference. *)

val fetch : t -> sha256:string -> (string option, fetch_error) result
(** Validate and retrieve bytes by sha256. Returns [Ok None] only when the
    validated path is absent. The owned-file read validates the no-follow
    parent chain and [lstat]/[fstat] identity before and after descriptor I/O.
    Read and content-integrity failures remain typed. Cancellation propagates. *)

type range =
  { content : string
  ; total_bytes : int
  }

val fetch_range :
  t ->
  sha256:string ->
  offset:int ->
  max_bytes:int ->
  (range option, fetch_error) result
(** Read at most [max_bytes] from [offset]. The first uncached read performs a
    whole-file sha256 validation; later pages whose owned descriptor snapshot
    is unchanged use bounded range I/O. The validation cache is bounded, so an
    evicted or changed snapshot is revalidated before any bytes are returned,
    preserving {!fetch}'s content-address integrity without hashing the whole
    artifact on every page. Bounds and filesystem failures remain typed.
    Cancellation propagates. *)

val list_all : t -> string list
(** List all sha256 hashes currently in the store. O(n) in store size.
    Mainly used by tests. Offline retention is owned exclusively by
    {!Tool_blob_maintenance} under the BasePath process lease. *)

type list_error =
  { path : string
  ; reason : string
  }

val list_all_result : t -> (string list, list_error) result
(** Typed production listing. Directory read/stat failures never collapse to
    an empty store. *)

type delete_error =
  { sha256 : string
  ; path : string
  ; reason : string
  }

val delete : t -> sha256:string -> (bool, delete_error) result
(** Delete one exact blob. [Ok false] means it is already absent; filesystem
    failures remain typed and visible. Bulk retention/deletion is owned
    exclusively by offline {!Tool_blob_maintenance} under the BasePath process
    lease; callers must not synthesize a partial consumer keep-set. *)
