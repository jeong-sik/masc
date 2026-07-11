(** Content-addressed durable store for input images.
    RFC-keeper-vision-delegation-tool §2.5.

    Image bytes are written to a content-addressed file under a store directory;
    the handle is the content hash — a plain string that survives JSON and
    checkpoint round-trips. This keeps the bytes off the lossy {!Payload}
    [Lazy_payload] path ([Payload.of_json] rebuilds an empty closure): a
    checkpoint persists only the handle and the bytes are reloaded on demand.
    Mirrors the content-addressed typed durable-write pattern of
    [Review_artifact_store]. *)

type handle = private string
(** Opaque content hash (SHA-256 hex). Produced by the store entry points; reconstruct a
    persisted handle string with {!of_string}. *)

val to_string : handle -> string
(** The on-disk / on-checkpoint string form of a handle. *)

val of_string : string -> handle
(** Re-wrap a handle string read back from a checkpoint. No I/O; integrity is
    verified later by {!load} (a wrong string fails closed there). *)

val store_blocking : dir:string -> string -> (handle, string) result
(** [store_blocking ~dir bytes] writes [bytes] on the calling thread and
    returns its handle. Idempotent: identical bytes map to the same handle and
    file, so a re-store overwrites identical content. [Error msg] on I/O failure. *)

val store_eio : dir:string -> string -> (handle, string) result
(** Eio-safe counterpart of {!store_blocking}. Directory creation and the
    durable write run as one cancellation-protected system-thread job. *)

val load : dir:string -> handle -> (string, string) result
(** [load ~dir h] reads the bytes for [h]. [Error] (never a silent empty success)
    if: [h] is not a canonical 64-char lowercase-hex handle (rejected before any
    filesystem access, so a forged "../" handle cannot read outside [dir]); the
    file is absent; or the stored bytes do not hash back to [h] (corruption). *)
