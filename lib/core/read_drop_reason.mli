(** Closed sum type for the [reason] label of
    [Otel_metric_store.metric_persistence_read_drops].

    [Core.Safe_ops.report_persistence_read_drop] takes [t].

    @stability Evolving
    @since 0.193.2 *)

type t =
  | List_dir_error (** Directory enumeration failed (permission / I/O / missing). *)
  | Entry_load_error (** A specific file under a directory failed to load. *)
  | Invalid_payload (** Payload was loaded but failed schema / shape validation. *)
  | Json_syntax_error (** Payload was loaded but JSON parsing raised. *)
  | Lock_contention
  (** Read aborted because a writer held the lock past the
          configured deadline. *)
  | Schema_version_mismatch
  (** Payload version is not understood by the current reader. *)
  | Decompression_error (** Compressed payload (gzip/zstd) failed to decompress. *)
  | Path_normalization_error
  (** Path containment / canonicalisation rejected the entry. *)
  | Stat_error (** [stat] / [lstat] failed before file open. *)
  | Concurrent_removal
  (** Entry was present at directory enumeration but absent at load
          time (TOCTOU race between [list_dir] and a concurrent writer
          that uses delete-then-replace). Not a data loss; the entry was
          concurrently retired by another writer. *)
  | Transient_fd_pressure
  (** Underlying [open()] failed with [ENFILE]/[EMFILE]. Not data
          loss; retry-eligible. *)
  | Tail_partial_write
  (** The last line of an append-only file was still being written when
          a tail reader reached it, so it parses as truncated JSON. Not
          data loss: the reader skips to the previous complete line and the
          next read sees the row whole. Belongs with [Concurrent_removal]
          and [Transient_fd_pressure] on the not-a-loss side. *)
  | Other of string
  (** Escape hatch for one-off surfaces. A PR introducing a new
          [Other] payload must justify why the value cannot be
          promoted to a constructor. Nothing enforces this yet; a
          value that appears at a second site belongs in a
          constructor. *)

(** Stable wire format. Before #29664, the strings produced here
    were byte-for-byte compatible with the string constants that
    [Core.Safe_ops] used ([persistence_read_drop_reason_list_dir_error],
    [persistence_read_drop_reason_entry_load_error],
    [persistence_read_drop_reason_invalid_payload]), so swapping callers
    to [t] does not change the Otel_metric_store label cardinality.

    Wire mapping:
    - [List_dir_error] → ["list_dir_error"]
    - [Entry_load_error] → ["entry_load_error"]
    - [Invalid_payload] → ["invalid_payload"]
    - [Json_syntax_error] → ["json_syntax_error"]
    - [Lock_contention] → ["lock_contention"]
    - [Schema_version_mismatch] → ["schema_version_mismatch"]
    - [Decompression_error] → ["decompression_error"]
    - [Path_normalization_error] → ["path_normalization_error"]
    - [Stat_error] → ["stat_error"]
    - [Concurrent_removal] → ["concurrent_removal"]
    - [Transient_fd_pressure] → ["transient_fd_pressure"]
    - [Tail_partial_write] → ["tail_partial_write"]
    - [Other s] → [s] (verbatim) *)
val to_wire : t -> string

(** Best-effort reverse of [to_wire]. Returns the canonical constructor
    for its wire string and [Other s] for any other input (so callers can
    round-trip). *)
val of_wire : string -> t

(** Equality (structural). *)
val equal : t -> t -> bool

(** Pretty-printer for debug output. Emits [to_wire t]. *)
val pp : Format.formatter -> t -> unit
