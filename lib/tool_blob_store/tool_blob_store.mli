(** Content-addressed blob store for tool outputs.

    Backend: filesystem under [base_path/.masc/tool_blobs/<sha[0..1]>/<sha>].
    Two-character sharding bounds each directory to ~256 of the total set.
    Writes are atomic via [Fs_compat.save_file_atomic] (tempfile + rename).

    Concurrent writes of the same content are safe: same sha256 -> same path,
    last writer wins with byte-identical content. *)

type t

type invalid_sha256 =
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

val put : t -> bytes:string -> mime:string -> Tool_output.t
(** Store [bytes] under its sha256 digest.

    Returns [Tool_output.Stored {sha256; bytes; preview; mime}] where
    [preview] is the first ~200 sanitized chars of [bytes] (control bytes
    replaced with [?], whitespace collapsed to spaces).

    Idempotent: re-putting the same bytes atomically rewrites the same content
    address, repairing any corrupt prior bytes without a duplicate read/hash.

    @raises Sys_error if the blob write fails (disk full, EACCES, ...). Callers
    that must not lose bytes should catch this and fall back to the inline
    payload rather than emitting a marker for bytes that were never persisted. *)

val fetch : t -> sha256:string -> (string option, fetch_error) result
(** Validate and retrieve bytes by sha256. Returns [Ok None] only when the
    validated path is absent. The owned-file read validates the no-follow
    parent chain and [lstat]/[fstat] identity before and after descriptor I/O.
    Read and content-integrity failures remain typed. Cancellation propagates. *)

val list_all : t -> string list
(** List all sha256 hashes currently in the store. O(n) in store size.
    Mainly used by [gc] and tests. *)

val gc : t -> keep_set:string list -> int
(** Delete every artifact whose sha256 is NOT in [keep_set].
    Returns the number of artifacts deleted. Best-effort: unlink failures
    are silently skipped. *)
