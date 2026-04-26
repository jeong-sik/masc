(** Content-addressed blob store for tool outputs.

    Backend: filesystem under [base_path/.masc/tool_blobs/<sha[0..1]>/<sha>].
    Two-character sharding bounds each directory to ~256 of the total set.
    Writes are atomic via [Fs_compat.save_file_atomic] (tempfile + rename).

    Concurrent writes of the same content are safe: same sha256 -> same path,
    last writer wins with byte-identical content. *)

type t

(** Create a blob store rooted at [base_path/.masc/tool_blobs/].
    Directory creation is lazy (happens on first [put]). *)
val create : base_path:string -> t

(** Absolute path of the store root. Mainly for diagnostics/testing. *)
val root_dir : t -> string

(** Store [bytes] under its sha256 digest.

    Returns [Tool_output.Stored {sha256; bytes; preview; mime}] where
    [preview] is the first ~200 sanitized chars of [bytes] (control bytes
    replaced with [?], whitespace collapsed to spaces).

    Idempotent: re-putting the same bytes is a no-op (file already exists). *)
val put : t -> bytes:string -> mime:string -> Tool_output.t

(** Retrieve bytes by sha256. Returns [None] if not in store. *)
val fetch : t -> sha256:string -> string option

(** List all sha256 hashes currently in the store. O(n) in store size.
    Mainly used by [gc] and tests. *)
val list_all : t -> string list

(** Delete every artifact whose sha256 is NOT in [keep_set].
    Returns the number of artifacts deleted. Best-effort: unlink failures
    are silently skipped. *)
val gc : t -> keep_set:string list -> int
