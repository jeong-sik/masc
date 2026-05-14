(** Closed sum type for the [reason] label of
    [Prometheus.metric_persistence_read_drops]. See RFC-0044
    (`docs/rfc/RFC-0044-persistence-read-drop-typed.md`) for the full
    motivation.

    This module is introduced in PR-1 of the RFC-0044 migration and is
    intentionally inert: no caller in the tree references it yet.
    PR-2 changes [Core.Safe_ops.report_persistence_read_drop] to
    accept [t] instead of [string]; existing constants in
    [safe_ops.ml] become wire-compatible aliases. PR-3 (optional)
    introduces a [read_outcome] Result-style helper for opt-in
    caller migration.

    Adding a new variant here is, by construction, a compile
    obligation for every callsite once PR-2 lands.

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
  | Other of string
  (** Escape hatch for one-off surfaces. PR introducing a new
          [Other] payload must justify why the value cannot be
          promoted to a constructor. The lint
          [scripts/lint/no-free-string-read-drop-reason.sh] (PR-2)
          flags PRs that add [Other] for a value already used at
          another site. *)

(** Stable wire format. The strings produced here are byte-for-byte
    compatible with the existing string constants in
    [Core.Safe_ops] ([persistence_read_drop_reason_list_dir_error],
    [_entry_load_error], [_invalid_payload]) so swapping callers in
    PR-2 does not change the Prometheus label cardinality.

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
    - [Other s] → [s] (verbatim) *)
val to_wire : t -> string

(** Best-effort reverse of [to_wire]. Returns [Some] for canonical
    constructors, [Some (Other s)] for any other input (so callers can
    round-trip). PR-2 may narrow this once the lint blocks free
    strings. *)
val of_wire : string -> t

(** Equality (structural). *)
val equal : t -> t -> bool

(** Pretty-printer for debug output. Emits [to_wire t]. *)
val pp : Format.formatter -> t -> unit
