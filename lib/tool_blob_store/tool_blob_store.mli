(** Content-addressed blob store for tool outputs.

    Backend: filesystem under [base_path/.masc/tool_blobs/<sha[0..1]>/<sha>].
    Two-character sharding bounds each directory to ~256 of the total set.
    Writes use the typed Fs_compat durable-mutation entry points.

    Concurrent writes of the same content are safe: same sha256 -> same path,
    last writer wins with byte-identical content. *)

type t

exception Committed_not_durable of string
(** The blob entry was committed but the parent directory sync failed. Callers
    must not retry the write; they may fall back to the original inline bytes. *)

exception Durable_with_diagnostics of string
(** The blob is durable but descriptor cleanup emitted a diagnostic. *)

val create : base_path:string -> t
(** Create a blob store rooted at [base_path/.masc/tool_blobs/].
    Directory creation is lazy (happens on first [put]). *)

val root_dir : t -> string
(** Absolute path of the store root. Mainly for diagnostics/testing. *)

val put_blocking : t -> bytes:string -> mime:string -> Tool_output.t
(** Store [bytes] under its sha256 digest on the calling thread.

    Returns [Tool_output.Stored {sha256; bytes; preview; mime}] where
    [preview] is the first ~200 sanitized chars of [bytes] (control bytes
    replaced with [?], whitespace collapsed to spaces).

    Idempotent: re-putting the same bytes is a no-op (file already exists).

    @raises Sys_error if the blob write was not committed (disk full, EACCES,
    ...). @raises Committed_not_durable when the entry was committed but parent
    sync failed. @raises Durable_with_diagnostics after a durable write with a
    cleanup diagnostic. Callers
    that must not lose bytes should catch this and fall back to the inline
    payload rather than emitting a marker for bytes that were never persisted. *)

val put_eio : t -> bytes:string -> mime:string -> Tool_output.t
(** Eio-safe counterpart of {!put_blocking}. Directory inspection, creation,
    and the durable write run as one cancellation-protected system-thread job. *)

val fetch : t -> sha256:string -> string option
(** Retrieve bytes by sha256. Returns [None] if not in store. *)

val list_all : t -> string list
(** List all sha256 hashes currently in the store. O(n) in store size.
    Mainly used by [gc] and tests. *)

val gc : t -> keep_set:string list -> int
(** Delete every artifact whose sha256 is NOT in [keep_set].
    Returns the number of artifacts deleted. Best-effort: unlink failures
    are silently skipped. *)
