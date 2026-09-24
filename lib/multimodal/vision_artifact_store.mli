(** Content-addressed durable store for input images.
    RFC-keeper-vision-delegation-tool §2.5.

    Image bytes are written to a content-addressed file under a store directory;
    the handle is the content hash — a plain string that survives JSON and
    checkpoint round-trips. This keeps the bytes off the lossy {!Payload}
    [Lazy_payload] path ([Payload.of_json] rebuilds an empty closure): a
    checkpoint persists only the handle and the bytes are reloaded on demand.
    Content addressing is SHA-256 hashing over the raw bytes, written through
    [Fs_compat.save_file_atomic]. *)

type handle = private string
(** Opaque content hash (SHA-256 hex). Produced by {!store}; reconstruct a
    persisted handle string with {!of_string}. *)

val to_string : handle -> string
(** The on-disk / on-checkpoint string form of a handle. *)

val of_string : string -> handle
(** Re-wrap a handle string read back from a checkpoint. No I/O; integrity is
    verified later by {!load} (a wrong string fails closed there). *)

val frames_dir : dir:string -> string
(** The only frame subdirectory name used for storage and read fallback. *)

type prune_result =
  { deleted_count : int
  ; reclaimed_bytes : int
  ; remaining_count : int
  ; remaining_bytes : int
  }

val default_max_entries : int
(** Default limit on retained artifacts per vision store directory (500). *)

val default_max_bytes : int
(** Default limit on total retained bytes per vision store directory (20 MB). *)

val prune
  :  ?max_entries:int
  -> ?max_bytes:int
  -> dir:string
  -> unit
  -> (prune_result, string) result
(** [prune ?max_entries ?max_bytes ~dir ()] prunes canonical artifact files
    (64-char lowercase-hex SHA-256) under [dir], evicting oldest files first
    (by mtime) until both [max_entries] and [max_bytes] are satisfied.
    Non-canonical files and subdirectories are never removed. *)

val store
  :  auto_prune:bool
  -> ?max_entries:int
  -> ?max_bytes:int
  -> dir:string
  -> string
  -> (handle, string) result
(** [store ~auto_prune ?max_entries ?max_bytes ~dir bytes] writes [bytes] to a content-addressed file under [dir] and
    returns its handle. Idempotent: identical bytes map to the same handle and
    file. A re-store compares a bounded owned regular-file read, skipping the atomic write
    only on an exact match. Missing or different content is written again.
    When [auto_prune] is true and a new file is written, triggers
    a bounded prune pass.
    [Error msg] when the required directory creation or write fails. *)

type load_error =
  | Malformed_handle of string
  | Missing_artifact of string
  | Hash_mismatch of string
  | Read_failed of string

val load_error_to_string : load_error -> string

val load : dir:string -> handle -> (string, load_error) result
(** [load ~dir h] reads the bytes for [h]. Checks [dir] directly, falling back
    to [dir/frames] if present. [Error] (never a silent empty success)
    if: [h] is not a canonical 64-char lowercase-hex handle (rejected before any
    filesystem access, so a forged "../" handle cannot read outside [dir]); the
    file is absent; or the stored bytes do not hash back to [h] (corruption). *)
