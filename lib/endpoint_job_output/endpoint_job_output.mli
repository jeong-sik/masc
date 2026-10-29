(** Durable capture of the original endpoint owner's byte stream.
    The trusted supervisor supplies that child's actual unique pipe source;
    this layer does not authenticate a peer or infer process/stream ownership
    from IDs. EOF is source EOF, never a current regular-file read boundary. *)
module P = Endpoint_job_protocol
module L = Endpoint_job_launch
module R = Endpoint_job_registry
type t
type error =
  | Invalid_storage | Storage_unavailable | Source_protocol_error
  | Offset_unavailable | Invalid_range | Interrupted | Capture_failed
  | Codec_error of P.codec_error
  | Registry_error of R.error
  | Publication_failed of Fs_compat.capability_write_error
  | Recovery_failed of string
val error_to_string : error -> string
type seal = private { byte_length : int64; sha256 : P.Sha256.t }
val start :
  sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> owner:L.t -> stream:P.stream ->
  source:_ Eio.Flow.source -> (t, error) result
(** Create an exclusive private spool under the owner's original storage and
    capture in a job-owned daemon fiber. [sw] must be that independent job's
    lifetime. The source remains borrowed until EOF or teardown; the caller
    must close its parent copies of child write ends after the original spawn.
    Chunks are appended and hashed without a total output-size/time limit.
    Only actual EOF, file sync and durable exclusive seal publication make
    Sealed visible. The original private storage and no-follow spool entry must
    still identify the held original file around sync and seal publication.
    A failed read/write/sync/publication or changed attachment leaves output unavailable.
    Normal job scope teardown cancels capture without waiting forever on its
    child; Interrupted remains observable and incomplete bytes are retained.
    Starting again never overwrites or adopts an existing spool. *)
val extent : t -> (P.extent, error) result
val await_sealed : t -> (seal, error) result
(** Cancelling this observer does not cancel capture or the child. *)
val reopen :
  sw:Eio.Switch.t -> storage:R.storage -> stream:P.stream -> (t, error) result
(** Reopen only an already sealed original stream through its verified original
    storage. Strictly validate its private seal, original admission and stream,
    atomically open no-follow, nonblocking regular seal/spool descriptors,
    verify the same single-link spool inode, and hash every byte before exposing
    Sealed. The verified spool and private seal plus each actual parent are
    fsynced, then their snapshots/source are revalidated before returning.
    Missing/corrupt/unsynced data never becomes an empty or growing result.
    Reads/hash run outside the registry lock; original authority and canonical
    attachments are revalidated afterward and around subsequent range reads.
    No capture, process, signal, publication or launch permission is created.
    [sw] owns this reader's descriptors and must cover result consumption;
    use a separate reader scope rather than the global registry lifetime. *)
val revalidate_sealed : t -> (seal, error) result
(** Revalidate a reopened original's held descriptors, canonical seal/spool
    snapshots and original source authority after the completed full-byte hash.
    This does not hash again or infer completion from EOF. Captures cannot turn
    a cached seal into this validation and return [Invalid_storage]. *)
val seal_unlaunched :
  sw:Eio.Switch.t -> proof:R.unlaunched ->
  stream:P.stream -> (t,error) result
(** Publish an actual empty immutable original stream and its canonical seal
    only from opaque no-callback authority. No pipe or potential payload writer
    exists for this proof; an empty preview or cancelled known ID cannot replace
    it. Reconcile exact existing bytes without overwrite, then reopen/hash/sync
    and revalidate the actual original files through the same sealed reader.
    Readiness of a complete terminal result remains a separate obligation. *)
type chunk = { data : string; extent : P.extent }
val read : t -> offset:int64 -> max_bytes:int -> (chunk, error) result
(** Read from the pinned original file descriptor within its observed prefix.
    May return less than requested capacity; reads use bounded transfer buffers
    while leaving all bytes retrievable. A growing extent is not completion. *)
module For_testing : sig
  type metadata_operation = Open_recovery | Publish of string
  type metadata_stage = Waiting | Acquired
  val start :
    after_chunk:(unit -> unit) ->
    on_metadata:(metadata_operation -> metadata_stage -> unit) ->
    sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> owner:L.t -> stream:P.stream ->
    source:_ Eio.Flow.source -> (t, error) result
  (** [after_chunk] runs after each actual file write and before further capture
      or EOF sealing. [on_metadata] observes an actual owner-lock acquisition;
      [Acquired] runs inside that lock before the specified Fs operation. *)
  val reopen :
    after_chunk:(unit -> unit) -> after_stat:(leaf:string -> unit) ->
    before_sync:(leaf:string -> Fs_compat.Owned_reader_for_testing.sync_stage -> unit) ->
    sw:Eio.Switch.t -> storage:R.storage ->
    stream:P.stream -> (t, error) result
  (** Interleave after hashing an actual original spool chunk, outside any
      registry lock. [after_stat] runs after the actual initial private leaf
      stat and before atomic opening. [before_sync] faults the real matched
      file/parent sync boundary in its worker; it must not perform Eio effects.
      No injected seal, bytes or authority. *)
end
