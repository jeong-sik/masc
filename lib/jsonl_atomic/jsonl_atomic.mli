(** RFC-0107: in-process atomic JSONL append writer.

    A {!t} is an append writer for a single JSONL file. Multiple writers
    for the same path share a single [Eio.Mutex.t] via a per-path
    registry, so calls to {!append} from any fiber or domain are
    serialized against each other.

    Each {!append} call:
    - Serializes [record + "\n"] into a single string in memory.
    - Acquires the per-path Eio.Mutex (fiber + domain safe).
    - Writes the full string to the underlying append-mode sink. Eio's
      [Flow.copy_string] retries short writes internally, so the entire
      buffer is delivered before the mutex is released — no other writer
      can interleave bytes from a different record into the same line,
      regardless of record size (PIPE_BUF threshold is not relevant
      because the mutex spans the whole write).

    Cross-process race protection is out of scope (RFC-0107 §6). *)

type t
(** Opaque handle. *)

val open_writer :
  sw:Eio.Switch.t ->
  fs:[> Eio.Fs.dir_ty ] Eio.Resource.t * string ->
  path:string ->
  t
(** [open_writer ~sw ~fs ~path] returns a writer for [path]. The
    parent directory is created if missing. The underlying fd is owned
    by [sw] and is closed when [sw] ends (or earlier via {!close}).

    Calling [open_writer] twice for the same [path] returns two
    distinct handles that share the same per-path mutex — concurrent
    appends through either handle remain serialized. *)

val append : t -> Yojson.Safe.t -> (unit, [`Io of string]) result
(** [append t json] appends [json] as a single JSONL line. Returns
    [Error] on IO failure; never raises for IO. The closure of [t]
    after a previous {!close} returns [Error (`Io "writer closed")]. *)

val close : t -> unit
(** Idempotent. Marks the writer closed and releases the fd via the
    underlying Eio resource. Does not remove the mutex from the
    registry — a subsequent {!open_writer} for the same path will
    reuse the existing mutex so any handles still held by other code
    stay correctly serialized. *)
