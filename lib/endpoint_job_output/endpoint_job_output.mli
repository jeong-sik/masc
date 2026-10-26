(** Durable capture of the original endpoint owner's byte stream.
    The trusted supervisor supplies that child's actual unique pipe source;
    this layer does not authenticate a peer or infer process/stream ownership
    from IDs. EOF is source EOF, never a current regular-file read boundary. *)
module P = Endpoint_job_protocol
module L = Endpoint_job_launch
type t
type error =
  | Invalid_storage | Storage_unavailable | Source_protocol_error
  | Offset_unavailable | Invalid_range | Interrupted | Capture_failed
  | Codec_error of P.codec_error
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
    Sealed visible. A failed read/write/sync/publication leaves output unavailable.
    Normal job scope teardown cancels capture without waiting forever on its
    child; Interrupted remains observable and incomplete bytes are retained.
    Starting again never overwrites or adopts an existing spool. *)
val extent : t -> (P.extent, error) result
val await_sealed : t -> (seal, error) result
(** Cancelling this observer does not cancel capture or the child. *)
type chunk = { data : string; extent : P.extent }
val read : t -> offset:int64 -> max_bytes:int -> (chunk, error) result
(** Read from the pinned original file descriptor within its observed prefix.
    May return less than requested capacity; reads use bounded transfer buffers
    while leaving all bytes retrievable. A growing extent is not completion. *)
